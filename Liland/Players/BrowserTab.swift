import Foundation

/// Brings forward the browser tab a song plays in, so opening the player from the island
/// lands on Deezer or YouTube rather than on whatever tab was in front.
///
/// Works through AppleScript in Safari and Chromium browsers; others just come forward.
enum BrowserTab {
    private enum Dialect {
        case safari, chromium

        /// The tab property that holds the page title.
        var titleProperty: String {
            switch self {
            case .safari: "name"
            case .chromium: "title"
            }
        }

        var minimizedProperty: String {
            switch self {
            case .safari: "miniaturized"
            case .chromium: "minimized"
            }
        }

        func selectTab(_ tab: Int, ofWindow window: Int) -> String {
            switch self {
            case .safari: "set current tab of window \(window) to tab \(tab) of window \(window)"
            case .chromium: "set active tab index of window \(window) to \(tab)"
            }
        }
    }

    private static let dialects: [String: Dialect] = [
        "com.apple.Safari": .safari,
        "com.apple.SafariTechnologyPreview": .safari,
        "com.google.Chrome": .chromium,
        "com.brave.Browser": .chromium,
        "com.microsoft.edgemac": .chromium,
    ]

    /// Music services. Media from any other site (WhatsApp, Instagram, YouTube…) isn't music.
    private static let musicHosts = [
        "deezer.com", "open.spotify.com", "music.youtube.com", "soundcloud.com", "tidal.com",
        "music.apple.com", "music.amazon.", "bandcamp.com", "qobuz.com", "audiomack.com",
    ]

    private struct Tab {
        let window: Int
        let index: Int
        let title: String
        let host: String
    }

    /// Call it off the main thread. False when the browser can't be scripted, Liland isn't
    /// allowed to control it, or no tab looks like the song's.
    static func show(_ track: NowPlayingTrack, in bundleIdentifier: String) -> Bool {
        guard let dialect = dialects[bundleIdentifier],
              let tab = bestTab(for: track, among: tabs(in: bundleIdentifier, dialect) ?? [])
        else { return false }
        let script = """
            tell application id "\(bundleIdentifier)"
                \(dialect.selectTab(tab.index, ofWindow: tab.window))
                set \(dialect.minimizedProperty) of window \(tab.window) to false
                set index of window \(tab.window) to 1
                activate
            end tell
            """
        if case .success = AppleScript.run(script) { return true }
        return false
    }

    static func canInspect(_ bundleIdentifier: String) -> Bool {
        dialects[bundleIdentifier] != nil
    }

    /// Whether the song plays on a music service, judged by the tab whose title names it.
    /// A site can rename its tab a moment late, so without such a tab, media that names an
    /// artist counts while a music service is open. Call it off the main thread; nil when
    /// the browser can't be asked.
    static func isMusicSite(_ track: NowPlayingTrack, in bundleIdentifier: String) -> Bool? {
        guard let dialect = dialects[bundleIdentifier],
              let tabs = tabs(in: bundleIdentifier, dialect)
        else { return nil }
        let named = tabs.filter { $0.title.localizedCaseInsensitiveContains(track.title) }
        if let tab = bestTab(for: track, among: named) {
            return isMusicHost(tab.host)
        }
        return !track.artist.isEmpty && tabs.contains { isMusicHost($0.host) }
    }

    private static func isMusicHost(_ host: String) -> Bool {
        musicHosts.contains(where: host.contains)
    }

    /// The song's title in the tab's title counts most (sites put it there, and browsers
    /// report the page title as Now Playing when a site gives none), then the artist.
    private static func bestTab(for track: NowPlayingTrack, among tabs: [Tab]) -> Tab? {
        var best: (tab: Tab, score: Int)?
        for tab in tabs {
            var score = 0
            if !track.title.isEmpty, tab.title.localizedCaseInsensitiveContains(track.title) { score += 4 }
            if !track.artist.isEmpty, tab.title.localizedCaseInsensitiveContains(track.artist) { score += 2 }
            if isMusicHost(tab.host) { score += 1 }
            if score > (best?.score ?? 0) { best = (tab, score) }
        }
        return best?.tab
    }

    /// One line per tab: window, tab, title and URL, separated by tabs. nil when the browser
    /// can't be asked, e.g. Liland isn't allowed to control it.
    private static func tabs(in bundleIdentifier: String, _ dialect: Dialect) -> [Tab]? {
        let script = """
            tell application id "\(bundleIdentifier)"
                set output to ""
                set separator to character id 9
                repeat with w from 1 to count of windows
                    try
                        repeat with t from 1 to count of tabs of window w
                            try
                                set output to output & w & separator & t & separator & (\(dialect.titleProperty) of tab t of window w) & separator & (URL of tab t of window w) & linefeed
                            end try
                        end repeat
                    end try
                end repeat
                return output
            end tell
            """
        guard case .success(let result) = AppleScript.run(script) else { return nil }
        let output = result.stringValue ?? ""
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 4, let window = Int(fields[0]), let index = Int(fields[1]) else { return nil }
            let url = fields[fields.count - 1]
            return Tab(
                window: window,
                index: index,
                title: fields[2..<(fields.count - 1)].joined(separator: "\t"),
                host: URL(string: String(url))?.host ?? ""
            )
        }
    }
}
