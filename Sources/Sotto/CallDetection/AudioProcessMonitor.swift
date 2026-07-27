import Foundation
import CoreAudio
import os

/// Watches every process connected to the CoreAudio HAL and reports which ones
/// are running microphone input or speaker output.
///
/// This is what makes attribution honest. The device-level
/// `kAudioDevicePropertyDeviceIsRunningSomewhere` only says the mic is busy;
/// pairing that with "Zoom is in the Dock" fires on dictation. The per-process
/// objects (macOS 14.2+) say *who*, with no permission of any kind — verified
/// from an unsigned, non-sandboxed binary.
///
/// CoreAudio listeners provide the fast path: one on the process list, plus two
/// per process on the IO flags. A lightweight polling fallback covers systems
/// where the HAL accepts those listeners but doesn't deliver IO flag changes.
@MainActor
final class AudioProcessMonitor {
    private static let logger = Logger(subsystem: "dev.sotto", category: "audio-processes")
    private static let pollInterval: TimeInterval = 1

    /// Fired on the main actor with a fresh full snapshot whenever anything moves.
    var onChange: (([CallSourceAggregator.RawProcess]) -> Void)?

    private var listListener: AudioObjectPropertyListenerBlock?
    private var processListeners: [AudioObjectID: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)]] = [:]
    private var snapshotTracker = AudioProcessSnapshotTracker()
    private var pollTimer: Timer?

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private static let ioSelectors: [AudioObjectPropertySelector] = [
        kAudioProcessPropertyIsRunningInput,
        kAudioProcessPropertyIsRunningOutput,
    ]

    // MARK: - Lifecycle

    /// Attaches the listeners. Returns false when the per-process API isn't
    /// there — the caller should then leave call detection off rather than
    /// silently reporting nothing.
    func start() -> Bool {
        guard listListener == nil else { return true }
        guard Self.processObjects() != nil else {
            Self.logger.error("Per-process audio objects unavailable — call detection off")
            return false
        }

        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.processListChanged() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            Self.systemObject, &address, .main, listener
        )
        guard status == noErr else {
            Self.logger.error("Could not observe the audio process list: \(status)")
            return false
        }
        listListener = listener

        reconcileProcessListeners()
        snapshotTracker.seed(snapshot())
        startPolling()
        return true
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        snapshotTracker.reset()

        // Snapshot the keys — `detach` mutates the dictionary we're walking.
        for object in Array(processListeners.keys) {
            detach(object)
        }
        if let listListener {
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(
                Self.systemObject, &address, .main, listListener
            )
            self.listListener = nil
        }
    }

    /// Every process the HAL knows about, with its current IO state.
    func snapshot() -> [CallSourceAggregator.RawProcess] {
        guard let objects = Self.processObjects() else { return [] }
        return objects.map { object in
            CallSourceAggregator.RawProcess(
                pid: Self.readPID(object),
                bundleID: Self.readBundleID(object),
                inputRunning: Self.readFlag(object, kAudioProcessPropertyIsRunningInput),
                outputRunning: Self.readFlag(object, kAudioProcessPropertyIsRunningOutput)
            )
        }
    }

    // MARK: - Listener plumbing

    private func processListChanged() {
        reconcileProcessListeners()
        publishIfChanged()
    }

    /// Reconciles against the *whole* current set rather than applying deltas:
    /// if a list event is ever dropped, the next one still converges.
    private func reconcileProcessListeners() {
        guard let objects = Self.processObjects() else { return }
        let live = Set(objects)

        for object in Array(processListeners.keys) where !live.contains(object) {
            detach(object)
        }
        for object in live where processListeners[object] == nil {
            attach(object)
        }
    }

    private func attach(_ object: AudioObjectID) {
        var attached: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
        for selector in Self.ioSelectors {
            var address = Self.address(selector)
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.publishIfChanged()
                }
            }
            let status = AudioObjectAddPropertyListenerBlock(object, &address, .main, listener)
            guard status == noErr else {
                Self.logger.error(
                    "Could not observe process \(object) selector \(selector): \(status)"
                )
                continue
            }
            attached.append((selector, listener))
        }
        processListeners[object] = attached
    }

    private func detach(_ object: AudioObjectID) {
        for (selector, listener) in processListeners[object] ?? [] {
            var address = Self.address(selector)
            // A non-noErr result here is the normal case for a process that has
            // already quit — its object is gone along with its listeners.
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, listener)
        }
        processListeners[object] = nil
    }

    // MARK: - Change delivery

    private func startPolling() {
        guard pollTimer == nil else { return }

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // The process-list listener can be affected by the same HAL
                // notification gap as the IO flags, so polling also reconciles
                // listener attachments for newly created process objects.
                self.reconcileProcessListeners()
                self.publishIfChanged()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        Self.logger.info("CoreAudio polling fallback active every \(Self.pollInterval)s")
    }

    private func publishIfChanged() {
        guard let changed = snapshotTracker.consume(snapshot()) else { return }
        onChange?(changed)
    }

    // MARK: - CoreAudio reads

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Nil means the API itself is missing (pre-14.2); an empty array means
    /// there genuinely are no processes.
    private static func processObjects() -> [AudioObjectID]? {
        var address = self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr
        else { return nil }
        guard size > 0 else { return [] }

        var objects = [AudioObjectID](
            repeating: AudioObjectID(kAudioObjectUnknown),
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &objects) == noErr
        else { return nil }
        return objects
    }

    private static func readPID(_ object: AudioObjectID) -> pid_t {
        var address = self.address(kAudioProcessPropertyPID)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr
        else { return -1 }
        return pid
    }

    /// Empty string when the process has no bundle ID — plenty don't, and
    /// they're unattributable anyway.
    private static func readBundleID(_ object: AudioObjectID) -> String {
        var address = self.address(kAudioProcessPropertyBundleID)
        // Unmanaged so the reference never passes through an unsafe raw
        // pointer; CoreAudio hands this one over +1.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let value else { return "" }
        return value.takeRetainedValue() as String
    }

    private static func readFlag(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> Bool {
        var address = self.address(selector)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &running) == noErr
        else { return false }
        return running != 0
    }
}
