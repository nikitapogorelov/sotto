/// Canonicalizes CoreAudio process snapshots and reports only real changes.
///
/// CoreAudio doesn't promise a stable order for
/// `kAudioHardwarePropertyProcessObjectList`, so comparing the raw arrays
/// directly would turn harmless reordering into a detection event.
struct AudioProcessSnapshotTracker {
    typealias RawProcess = CallSourceAggregator.RawProcess

    private var previous: [RawProcess]?

    mutating func seed(_ processes: [RawProcess]) {
        previous = Self.canonical(processes)
    }

    /// Returns a canonical snapshot when its contents changed, including an
    /// empty array when all processes disappeared. Returns nil for a duplicate.
    mutating func consume(_ processes: [RawProcess]) -> [RawProcess]? {
        let current = Self.canonical(processes)
        guard current != previous else { return nil }
        previous = current
        return current
    }

    mutating func reset() {
        previous = nil
    }

    private static func canonical(_ processes: [RawProcess]) -> [RawProcess] {
        processes.sorted { lhs, rhs in
            if lhs.pid != rhs.pid {
                return lhs.pid < rhs.pid
            }
            if lhs.bundleID != rhs.bundleID {
                return lhs.bundleID < rhs.bundleID
            }
            if lhs.inputRunning != rhs.inputRunning {
                return !lhs.inputRunning
            }
            if lhs.outputRunning != rhs.outputRunning {
                return !lhs.outputRunning
            }
            return false
        }
    }
}
