import Foundation

/// Pure lifecycle state for one pending browser-call evaluation per browser.
///
/// Window-title reads are asynchronous. A token ties their result to the exact
/// microphone session that started them, so an old read cannot notify after the
/// mic stopped or after a newer session replaced it.
struct BrowserCallCandidateTracker {
    struct Token: Equatable, Hashable {
        let id: String
        let generation: UInt64
    }

    enum Resolution: Equatable {
        case service(source: CallSource, name: String)
        case generic(source: CallSource)
    }

    private struct Entry {
        let source: CallSource
        let token: Token
        var fallbackMatured = false
    }

    private var nextGeneration: UInt64 = 0
    private var entries: [String: Entry] = [:]

    var isEmpty: Bool { entries.isEmpty }
    var ids: [String] { entries.keys.sorted() }

    /// Starts a new microphone session, invalidating any older token for `id`.
    mutating func begin(_ source: CallSource) -> Token {
        nextGeneration &+= 1
        let token = Token(id: source.id, generation: nextGeneration)
        entries[source.id] = Entry(source: source, token: token)
        return token
    }

    func token(for id: String) -> Token? {
        entries[id]?.token
    }

    func isCurrent(_ token: Token) -> Bool {
        entries[token.id]?.token == token
    }

    /// Ends the current microphone session. Late results holding its token are
    /// rejected by `resolveTitle`.
    mutating func end(_ id: String) {
        entries[id] = nil
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    /// Marks the audio fallback ready, but does not claim the candidate. The
    /// caller must perform one final title read and pass it to `resolveTitle`.
    @discardableResult
    mutating func markFallbackMatured(_ id: String) -> Token? {
        guard var entry = entries[id] else { return nil }
        entry.fallbackMatured = true
        entries[id] = entry
        return entry.token
    }

    /// Disabling the generic fallback never ends exact title recognition.
    mutating func clearGenericFallback() {
        for id in Array(entries.keys) {
            entries[id]?.fallbackMatured = false
        }
    }

    /// Applies a title result and atomically claims the candidate if it now
    /// warrants a notification. A claimed token can never resolve twice.
    mutating func resolveTitle(
        _ token: Token,
        service: String?,
        fallbackEnabled: Bool
    ) -> Resolution? {
        guard var entry = entries[token.id], entry.token == token else { return nil }

        if let service {
            entries[token.id] = nil
            return .service(source: entry.source, name: service)
        }

        guard fallbackEnabled else {
            // Turning the setting off cancels a matured generic candidate while
            // leaving this microphone session eligible for later exact matches.
            entry.fallbackMatured = false
            entries[token.id] = entry
            return nil
        }

        guard entry.fallbackMatured else { return nil }
        entries[token.id] = nil
        return .generic(source: entry.source)
    }
}
