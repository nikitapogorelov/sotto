import Foundation

/// Bundle-ID family matching.
///
/// The audio process list never shows a Chromium or Electron app's main bundle
/// ID — capture and playback run in helper processes (`com.google.Chrome.helper`,
/// `company.thebrowser.browser.helper`). So attribution has to match a family
/// root, not compare for equality.
enum BundleFamily {
    /// True when `bundleID` is `root` or a descendant of it.
    ///
    /// Matching is on component boundaries, not a raw prefix: `com.google.Chrome`
    /// owns `com.google.Chrome.helper` and `com.google.Chrome.app.<hash>`
    /// (installed PWAs) but must not swallow `com.google.chromeremotedesktop`.
    /// Case is ignored because Arc ships the app as `company.thebrowser.Browser`
    /// and its helper as `company.thebrowser.browser.helper`.
    static func contains(_ bundleID: String, root: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        let id = bundleID.lowercased()
        let root = root.lowercased()
        return id == root || id.hasPrefix(root + ".")
    }
}

/// Native apps whose microphone use means "a call probably started".
enum CallApps {
    static let known: [(bundleID: String, name: String)] = [
        ("us.zoom.xos", "Zoom"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.microsoft.teams2", "Microsoft Teams"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.hnc.Discord", "Discord"),
        ("Cisco-Systems.Spark", "Webex"),
    ]

    /// The entry owning `bundleID`, helper processes included.
    static func entry(forBundleID bundleID: String) -> (bundleID: String, name: String)? {
        known.first { BundleFamily.contains(bundleID, root: $0.bundleID) }
    }
}

/// Browsers a call can happen inside. Mic use here means nothing on its own —
/// it takes a window-title rule or sustained duplex audio to become a call
/// (see `BrowserCallRules` and `DuplexSustainTracker`).
///
/// Safari is absent and cannot be added: WebKit routes audio through
/// `com.apple.WebKit.GPU`, a process shared with Mail, Notes and every
/// WKWebView host, so it can't be attributed to a browser by bundle ID.
///
/// Firefox is absent pending verification — its process model isn't Chromium's
/// and its media process may report an empty bundle ID, which would make an
/// entry here a row that never fires. Check the live process list with Firefox
/// in a call before adding it.
enum Browsers {
    static let known: [(bundleID: String, name: String)] = [
        ("com.google.Chrome", "Chrome"),
        ("com.microsoft.edgemac", "Edge"),
        ("com.brave.Browser", "Brave"),
        ("company.thebrowser.Browser", "Arc"),
        ("com.vivaldi.Vivaldi", "Vivaldi"),
        ("com.operasoftware.Opera", "Opera"),
    ]

    static func entry(forBundleID bundleID: String) -> (bundleID: String, name: String)? {
        known.first { BundleFamily.contains(bundleID, root: $0.bundleID) }
    }
}

/// One app or browser, collapsed from however many audio processes it runs.
struct CallSource: Equatable, Identifiable {
    enum Kind: Equatable {
        case app
        case browser
    }

    /// The family root, e.g. `com.google.Chrome` — stable across helper churn.
    let id: String
    let kind: Kind
    let name: String
    var inputRunning: Bool
    var outputRunning: Bool

    /// Mic and speakers at once: you're talking and hearing someone.
    var duplex: Bool { inputRunning && outputRunning }
}

/// Folds the raw CoreAudio process list into `CallSource`s.
enum CallSourceAggregator {
    /// One entry per process object, as read from the CoreAudio process list.
    struct RawProcess: Equatable {
        let pid: pid_t
        let bundleID: String
        let inputRunning: Bool
        let outputRunning: Bool
    }

    /// Family root, kind and display name for a process's bundle ID, or nil
    /// when the process belongs to nothing we care about.
    static func family(for bundleID: String) -> (root: String, kind: CallSource.Kind, name: String)? {
        // Several live processes report an empty bundle ID; they're unattributable.
        guard !bundleID.isEmpty else { return nil }
        if let app = CallApps.entry(forBundleID: bundleID) {
            return (app.bundleID, .app, app.name)
        }
        if let browser = Browsers.entry(forBundleID: bundleID) {
            return (browser.bundleID, .browser, browser.name)
        }
        return nil
    }

    /// Collapse processes into one source per family, sorted by id so callers
    /// (and tests) see a stable order.
    ///
    /// Input and output are OR-ed across the family: Chromium splits capture
    /// and playback across *different* helpers, so a call shows up as input on
    /// one process and output on another and only reads as duplex once merged.
    static func sources(from processes: [RawProcess]) -> [CallSource] {
        var byRoot: [String: CallSource] = [:]
        for process in processes {
            guard let family = family(for: process.bundleID) else { continue }
            if var existing = byRoot[family.root] {
                existing.inputRunning = existing.inputRunning || process.inputRunning
                existing.outputRunning = existing.outputRunning || process.outputRunning
                byRoot[family.root] = existing
            } else {
                byRoot[family.root] = CallSource(
                    id: family.root,
                    kind: family.kind,
                    name: family.name,
                    inputRunning: process.inputRunning,
                    outputRunning: process.outputRunning
                )
            }
        }
        return byRoot.values.sorted { $0.id < $1.id }
    }
}
