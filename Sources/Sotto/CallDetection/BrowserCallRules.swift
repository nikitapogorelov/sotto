import Foundation

/// Recognizes a conferencing service from a browser window's title.
///
/// This is what separates "Chrome is using the microphone" from "you are in a
/// Google Meet". Titles are the only cheap window into what a tab is doing —
/// reading the URL would need the Accessibility permission, which Sotto
/// deliberately doesn't ask for.
enum BrowserCallRules {
    struct Rule {
        let service: String
        let patterns: [NSRegularExpression]
    }

    /// Add a service by adding a row. Patterns are alternatives — any one hit
    /// names the service.
    static let rules: [Rule] = [
        Rule(
            service: "Google Meet",
            patterns: [
                // The meeting code, e.g. "abc-defg-hij". Distinctive enough to
                // stand alone, so it works whatever the window title's shape.
                //
                // Plain \b won't do: in "my-abc-defg-hij-notes" a hyphen counts
                // as a word boundary, so \b would happily match the middle of a
                // filename. The lookarounds reject a neighbouring letter,
                // digit or hyphen instead. Deliberately case-sensitive —
                // Meet codes are always lowercase, and allowing uppercase
                // would start matching ordinary hyphenated prose.
                pattern("(?<![a-z0-9-])[a-z]{3}-[a-z]{4}-[a-z]{3}(?![a-z0-9-])"),
                // Some Meet windows report the bare product name. Match that
                // exact title only: `^Meet\b` also accepts unrelated pages such
                // as "Meet the Team" and "Meet-cute". Calls whose title includes
                // a code are already covered by the stronger rule above.
                pattern("^Meet$"),
            ]
        ),
    ]

    /// The service this window title belongs to, or nil if it names none.
    static func service(forTitle title: String) -> String? {
        let range = NSRange(title.startIndex..., in: title)
        return rules.first { rule in
            rule.patterns.contains { $0.firstMatch(in: title, range: range) != nil }
        }?.service
    }

    /// The first service recognized across a browser's window titles.
    static func service(inTitles titles: [String]) -> String? {
        for title in titles {
            if let service = service(forTitle: title) { return service }
        }
        return nil
    }

    /// Patterns are compile-time constants — a bad one is a programming error,
    /// not a runtime condition to handle.
    private static func pattern(_ source: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: source)
    }
}
