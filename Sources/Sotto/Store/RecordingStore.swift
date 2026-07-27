import Foundation
import SwiftUI

enum RecordingStatus: String, Codable {
    case recorded      // audio saved, not transcribed (no model yet)
    case transcribing
    case done
    case failed
}

struct Recording: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    let date: Date
    var duration: TimeInterval
    var status: RecordingStatus
    var transcript: [TranscriptSegment]?
    var audioFileName: String
    // Optional with a default so pre-warning index.json files keep decoding.
    var warning: String? = nil

    static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return "Call — \(formatter.string(from: date))"
    }
}

enum Paths {
    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Sotto", isDirectory: true)
    }
    static var models: URL { appSupport.appendingPathComponent("Models", isDirectory: true) }
    static var recordings: URL { appSupport.appendingPathComponent("Recordings", isDirectory: true) }
    static var index: URL { appSupport.appendingPathComponent("index.json") }
}

@MainActor
final class RecordingStore: ObservableObject {
    @Published private(set) var recordings: [Recording] = []

    init() {
        try? FileManager.default.createDirectory(at: Paths.recordings, withIntermediateDirectories: true)
        load()
    }

    // MARK: - CRUD

    func add(_ recording: Recording) {
        recordings.insert(recording, at: 0)
        persist()
    }

    func update(_ recording: Recording) {
        guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        recordings[index] = recording
        persist()
    }

    func delete(_ recording: Recording) {
        recordings.removeAll { $0.id == recording.id }
        try? FileManager.default.removeItem(at: directory(for: recording))
        persist()
    }

    // MARK: - Files

    func directory(for recording: Recording) -> URL {
        let dir = Paths.recordings.appendingPathComponent(recording.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func audioURL(for recording: Recording) -> URL {
        directory(for: recording).appendingPathComponent(recording.audioFileName)
    }

    // MARK: - Export

    func markdown(for recording: Recording) -> String {
        var lines: [String] = []
        lines.append("# \(recording.title)")
        lines.append("")
        lines.append("- Date: \(recording.date.formatted(date: .long, time: .shortened))")
        lines.append("- Duration: \(Self.formatDuration(recording.duration))")
        lines.append("")
        if let transcript = recording.transcript {
            for segment in transcript {
                let speaker = segment.speaker.map { " \($0.displayName):" } ?? ""
                lines.append("**[\(Self.formatTimestamp(segment.start))]\(speaker)** \(segment.text)")
                lines.append("")
            }
        } else {
            lines.append("_Not transcribed yet._")
        }
        return lines.joined(separator: "\n")
    }

    static func formatDuration(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Paths.index),
              let decoded = try? JSONDecoder().decode([Recording].self, from: data) else { return }
        recordings = Self.repairingStaleStatus(decoded)
    }

    /// A stale "transcribing" status means the app quit mid-transcription.
    /// An interrupted *re*-run still holds its previous transcript, so it goes
    /// back to done rather than claiming to be audio-only.
    static func repairingStaleStatus(_ decoded: [Recording]) -> [Recording] {
        decoded.map { recording in
            guard recording.status == .transcribing else { return recording }
            var repaired = recording
            repaired.status = (recording.transcript?.isEmpty == false) ? .done : .recorded
            return repaired
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(recordings) else { return }
        try? data.write(to: Paths.index, options: .atomic)
    }
}
