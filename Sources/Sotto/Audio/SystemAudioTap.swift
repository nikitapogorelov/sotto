import Foundation
import ScreenCaptureKit
import AVFoundation

/// Captures system audio output (the remote side of a call) natively via
/// ScreenCaptureKit — no virtual audio driver (BlackHole/Loopback) required.
/// Requires the Screen Recording permission (TCC prompts on first start).
final class SystemAudioTap: NSObject, SCStreamOutput, SCStreamDelegate {
    enum TapError: LocalizedError {
        case noDisplay
        case screenRecordingDenied

        var errorDescription: String? {
            switch self {
            case .noDisplay:
                return "No display available for audio capture."
            case .screenRecordingDenied:
                return "Screen Recording permission is required to capture system audio."
            }
        }
    }

    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private let sampleQueue = DispatchQueue(label: "dev.sotto.system-audio")

    /// Called on `sampleQueue` with 16 kHz mono Float32 chunks and the chunk's
    /// host-clock time in seconds (SCK stamps PTS against the host clock).
    var onSamples: (([Float], Double?) -> Void)?
    var onError: ((Error) -> Void)?

    /// True when the error is ScreenCaptureKit telling us the Screen Recording
    /// permission is missing (SCShareableContent and startCapture both throw it).
    private static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        // SCStreamErrorUserDeclined == -3801
        return nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain"
            && nsError.code == -3801
    }

    func start() async throws {
        let content: SCShareableContent
        do {
            // Throws when the Screen Recording permission is missing.
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            throw Self.isPermissionError(error) ? TapError.screenRecordingDenied : error
        }
        guard let display = content.displays.first else { throw TapError.noDisplay }

        // We must attach to *something* visual to get the audio stream;
        // capture the whole display but shrink video work to near-zero.
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(AudioUtil.whisperSampleRate) // SCK supports 16000 directly
        config.channelCount = 1
        // Minimize the (unused) video leg of the stream.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        do {
            try await stream.startCapture()
        } catch {
            throw Self.isPermissionError(error) ? TapError.screenRecordingDenied : error
        }
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
        converter = nil
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio,
              sampleBuffer.isValid,
              let pcm = AudioUtil.pcmBuffer(from: sampleBuffer) else { return }

        if converter == nil {
            converter = AudioUtil.makeConverter(from: pcm.format)
        }
        guard let converter else { return }

        let samples = AudioUtil.convert(pcm, using: converter)
        if !samples.isEmpty {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            onSamples?(samples, pts.isValid ? CMTimeGetSeconds(pts) : nil)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }
}
