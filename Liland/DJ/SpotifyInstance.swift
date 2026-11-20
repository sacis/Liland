import AppKit
import ApplicationServices

/// One running Spotify, reached by its PID, so that two copies (the second one started with `--mu`) can be
/// told apart: AppleScript by name always reaches the newest one. Every call blocks: use it off the main thread.
final class SpotifyInstance {
    static let bundleIdentifier = "com.spotify.client"

    struct Track: Equatable {
        let id: String // spotify:track:…
        let title: String
        let artist: String
        let artworkURL: URL?
        let duration: TimeInterval
    }

    struct State: Equatable {
        var isPlaying = false
        var track: Track?
        var position: TimeInterval = 0
    }

    let pid: pid_t
    /// The `--mu` name of a second copy; nil for the normal one.
    let profile: String?

    init(pid: pid_t, profile: String?) {
        self.pid = pid
        self.profile = profile
    }

    var isRunning: Bool {
        NSRunningApplication(processIdentifier: pid)?.isTerminated == false
    }

    // MARK: - Finding and starting copies

    static var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    static func running() -> [SpotifyInstance] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).compactMap { app in
            guard !app.isTerminated else { return nil }
            let pid = app.processIdentifier
            let profile = arguments(of: pid).lazy
                .first { $0.hasPrefix("--mu=") }
                .map { String($0.dropFirst("--mu=".count)) }
            return SpotifyInstance(pid: pid, profile: profile)
        }
    }

    /// Starts a separate copy with its own login and downloads, its window already at `frame`.
    static func launch(profile: String, frame: CGRect, completion: @escaping (SpotifyInstance?) -> Void) {
        guard let appURL else { return completion(nil) }
        savePosition(frame, profile: profile)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--mu=\(profile)"]
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
            if let error { NSLog("Liland: could not start a second Spotify: \(error)") }
            completion(app.map { SpotifyInstance(pid: $0.processIdentifier, profile: profile) })
        }
    }

    /// Spotify places its window from its prefs file when it starts, in top-left screen points.
    private static func savePosition(_ frame: CGRect, profile: String) {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let folder = support.appendingPathComponent("Spotify-\(profile)")
        let file = folder.appendingPathComponent("prefs")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let kept = ((try? String(contentsOf: file, encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .filter { !$0.hasPrefix("app.window.position.") }
        let top = topLeft(frame)
        let position = [
            "app.window.position.saved=true",
            "app.window.position.x=\(Int(top.minX))",
            "app.window.position.y=\(Int(top.minY))",
            "app.window.position.width=\(Int(top.width))",
            "app.window.position.height=\(Int(top.height))",
        ]
        try? (kept.map(String.init) + position).joined(separator: "\n").appending("\n")
            .write(to: file, atomically: true, encoding: .utf8)
    }

    /// Cocoa's bottom-left screen rect, flipped to the top-left points of Spotify and accessibility.
    static func topLeft(_ frame: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? frame.maxY
        return CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
    }

    private static func arguments(of pid: pid_t) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let count = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        // argc, the executable path, padding, then the arguments, each ending in a zero.
        var index = MemoryLayout<Int32>.size
        while index < size && buffer[index] != 0 { index += 1 }
        while index < size && buffer[index] == 0 { index += 1 }
        var result: [String] = []
        while result.count < count && index < size {
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            result.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }

    // MARK: - Apple Events

    func state() -> State? {
        guard let code = get(Self.property("pPlS"))?.enumCodeValue else { return nil }
        var state = State()
        state.isPlaying = code == Self.code("kPSP")
        state.position = get(Self.property("pPos"))?.doubleValue ?? 0
        let track = Self.property("pTrk")
        if code != Self.code("kPSS"), let id = get(Self.property("ID  ", of: track))?.stringValue, !id.isEmpty {
            // The dictionary says seconds but Spotify answers in milliseconds.
            let duration = get(Self.property("pDur", of: track))?.doubleValue ?? 0
            state.track = Track(
                id: id,
                title: get(Self.property("pnam", of: track))?.stringValue ?? "",
                artist: get(Self.property("pArt", of: track))?.stringValue ?? "",
                artworkURL: get(Self.property("aUrl", of: track))?.stringValue.flatMap(URL.init(string:)),
                duration: duration > 36_000 ? duration / 1000 : duration
            )
        }
        return state
    }

    func play() { send("spfy", "Play") }
    func pause() { send("spfy", "Paus") }

    /// Offline, this only loads the track: `play()` starts it.
    func play(track id: String) {
        send("spfy", "PCtx", direct: NSAppleEventDescriptor(string: id))
    }

    /// Spotify links (spotify:album:…, spotify:search:…) open inside this copy.
    func open(_ link: String) {
        send("GURL", "GURL", direct: NSAppleEventDescriptor(string: link))
    }

    func seek(to seconds: TimeInterval) {
        set(Self.property("pPos"), to: NSAppleEventDescriptor(double: seconds))
    }

    private func get(_ specifier: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        send("core", "getd", direct: specifier)
    }

    private func set(_ specifier: NSAppleEventDescriptor, to value: NSAppleEventDescriptor) {
        let event = makeEvent("core", "setd")
        event.setParam(specifier, forKeyword: keyDirectObject)
        event.setParam(value, forKeyword: Self.code("data"))
        _ = try? event.sendEvent(options: [.waitForReply], timeout: 5)
    }

    @discardableResult
    private func send(_ eventClass: String, _ eventID: String, direct: NSAppleEventDescriptor? = nil) -> NSAppleEventDescriptor? {
        let event = makeEvent(eventClass, eventID)
        if let direct { event.setParam(direct, forKeyword: keyDirectObject) }
        return (try? event.sendEvent(options: [.waitForReply], timeout: 5))?.paramDescriptor(forKeyword: keyDirectObject)
    }

    private func makeEvent(_ eventClass: String, _ eventID: String) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: Self.code(eventClass),
            eventID: Self.code(eventID),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }

    private static func property(_ name: String, of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        let specifier = NSAppleEventDescriptor.record().coerce(toDescriptorType: code("obj "))!
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: code("prop")), forKeyword: code("want"))
        specifier.setDescriptor(container, forKeyword: code("from"))
        specifier.setDescriptor(NSAppleEventDescriptor(enumCode: code("prop")), forKeyword: code("form"))
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: code(name)), forKeyword: code("seld"))
        return specifier
    }

    private static func code(_ text: String) -> FourCharCode {
        text.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    // MARK: - Window

    /// Brings this copy forward; macOS switches to the Space its window is on.
    func show() {
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    func hide() {
        NSRunningApplication(processIdentifier: pid)?.hide()
    }

    /// Needs accessibility access, and the window on the current Space: call after `show()`.
    func moveWindow(to frame: CGRect) {
        guard let window = (Accessibility.value(element, kAXWindowsAttribute) as? [AXUIElement])?.first else { return }
        let top = Self.topLeft(frame)
        var origin = top.origin, size = top.size
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
    }

    // MARK: - Offline mode

    var isOffline: Bool? {
        offlineItem().map { Accessibility.value($0, kAXMenuItemMarkCharAttribute) as? String != nil }
    }

    /// The item only shows up once Spotify has started and logged in, and is only enabled while Spotify is in
    /// front: waits for it, brings this copy forward for the moment it takes, then gives the focus back.
    @discardableResult
    func setOffline(_ offline: Bool, timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var previous: NSRunningApplication?
        defer {
            if let previous, previous.processIdentifier != pid { previous.activate() }
        }
        repeat {
            if let item = offlineItem() {
                let isOn = Accessibility.value(item, kAXMenuItemMarkCharAttribute) as? String != nil
                if isOn == offline { return true }
                if Accessibility.value(item, kAXEnabledAttribute) as? Bool == true {
                    AXUIElementPerformAction(item, kAXPressAction as CFString)
                    // A press right after Spotify starts can be ignored: look again before pressing twice.
                    Thread.sleep(forTimeInterval: 1.2)
                    continue
                } else if previous == nil {
                    previous = NSWorkspace.shared.frontmostApplication
                    show()
                }
            }
            Thread.sleep(forTimeInterval: 0.4)
        } while Date() < deadline
        return false
    }

    /// Found by its title in any of Spotify's languages, never by position: next to it is Log Out.
    private func offlineItem() -> AXUIElement? {
        guard let bar = Accessibility.value(element, kAXMenuBarAttribute),
              let appMenu = Accessibility.children(bar as! AXUIElement).dropFirst().first, // past the Apple menu
              let menu = Accessibility.children(appMenu).first
        else { return nil }
        let titles = SpotifyStrings.offlineMode
        return Accessibility.children(menu).first { titles.contains(Accessibility.title($0)) }
    }

    // MARK: - Downloading

    enum DownloadResult { case downloaded, failed, timedOut }

    /// Downloads the album the track is on (Spotify downloads albums and playlists, not songs), which also
    /// saves it to the library. Must be online.
    func download(albumOf trackID: String, timeout: TimeInterval = 180) -> DownloadResult {
        guard let albumID = SpotifyWeb.albumID(ofTrack: trackID) else { return .failed }
        open("spotify:album:\(albumID)")
        let deadline = Date().addingTimeInterval(timeout)
        var pressed = false
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
            guard let (language, buttons) = pageButtons(), let strings = SpotifyStrings.load(language: language) else { continue }
            if buttons.contains(where: { strings.remove.contains($0.label) }) { return .downloaded }
            if !pressed, let button = buttons.first(where: { strings.download.contains($0.label) }) {
                AXUIElementPerformAction(button.element, kAXPressAction as CFString)
                pressed = true
            }
        }
        return .timedOut
    }

    /// The window's buttons (and toggles) and its language, read from Spotify's web view.
    private func pageButtons() -> (String, [(element: AXUIElement, label: String)])? {
        var language: String?
        var buttons: [(AXUIElement, String)] = []
        Accessibility.walk(element, limit: 40_000) { node, role in
            if language == nil, let value = Accessibility.value(node, "AXLanguage") as? String, !value.isEmpty {
                language = value
            }
            if role == kAXButtonRole as String || role == kAXCheckBoxRole as String {
                let label = [kAXDescriptionAttribute, kAXTitleAttribute]
                    .compactMap { Accessibility.value(node, $0) as? String }
                    .first { !$0.isEmpty } ?? ""
                if !label.isEmpty { buttons.append((node, label)) }
            }
        }
        return language.map { ($0, buttons) }
    }

    // MARK: - Playing on this Mac

    /// The account may be playing on another device, with this copy only showing it: moves the playback here
    /// through Spotify's own device picker. Needs the window, so it's brought forward for the moment it takes.
    @discardableResult
    func playHere(timeout: TimeInterval = 10) -> Bool {
        let app = NSRunningApplication(processIdentifier: pid)
        let previous = NSWorkspace.shared.frontmostApplication
        let wasHidden = app?.isHidden == true
        show()
        defer {
            if wasHidden { hide() }
            if let previous, previous.processIdentifier != pid { previous.activate() }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var opened = false
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.6)
            guard let (language, buttons) = pageButtons(), let strings = SpotifyStrings.load(language: language) else { continue }
            let picker = buttons.first { strings.connectPicker.contains($0.label) }
            if let here = buttons.first(where: { strings.thisComputer.contains($0.label) }) {
                AXUIElementPerformAction(here.element, kAXPressAction as CFString)
                Thread.sleep(forTimeInterval: 0.6)
                if let picker { AXUIElementPerformAction(picker.element, kAXPressAction as CFString) }
                return true
            }
            if !opened, let picker {
                AXUIElementPerformAction(picker.element, kAXPressAction as CFString)
                opened = true
            }
        }
        return false
    }

    // MARK: - Accessibility

    private lazy var element: AXUIElement = {
        let element = AXUIElementCreateApplication(pid)
        // Chromium builds its web content's tree only when asked.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return element
    }()
}

enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's prompt the first time.
    static func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func title(_ element: AXUIElement) -> String {
        value(element, kAXTitleAttribute) as? String ?? ""
    }

    static func walk(_ root: AXUIElement, limit: Int, visit: (AXUIElement, String) -> Void) {
        var queue = [root]
        var index = 0
        while index < queue.count && index < limit {
            let node = queue[index]
            index += 1
            visit(node, value(node, kAXRoleAttribute) as? String ?? "")
            queue.append(contentsOf: children(node))
        }
    }
}

/// Spotify's own wording for its buttons, from the translations it ships, so they're found in any language.
struct SpotifyStrings {
    let download: Set<String>
    let remove: Set<String>
    let connectPicker: Set<String>
    let thisComputer: Set<String>

    /// "Offline Mode" in every language Spotify ships, from the catalogs its native menus use.
    static let offlineMode: Set<String> = {
        var titles: Set<String> = ["Offline Mode"]
        guard let folder = SpotifyInstance.appURL?.appendingPathComponent("Contents/Resources/locales"),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return titles }
        for file in files where file.pathExtension == "mo" {
            if let data = try? Data(contentsOf: file), let title = translation(of: "Offline Mode", inCatalog: data) {
                titles.insert(title)
            }
        }
        return titles
    }()

    /// Looks one message up in a GNU gettext .mo file.
    private static func translation(of message: String, inCatalog data: Data) -> String? {
        func word(_ offset: Int) -> Int? {
            guard offset + 4 <= data.count else { return nil }
            return Int(data[data.startIndex + offset..<data.startIndex + offset + 4]
                .enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) })
        }
        func string(_ table: Int, _ index: Int) -> String? {
            guard let length = word(table + 8 * index), let offset = word(table + 8 * index + 4),
                  offset + length <= data.count
            else { return nil }
            return String(data: data[data.startIndex + offset..<data.startIndex + offset + length], encoding: .utf8)
        }
        guard word(0) == 0x950412de, let count = word(8), let originals = word(12), let translations = word(16) else { return nil }
        for index in 0..<count where string(originals, index) == message {
            return string(translations, index)
        }
        return nil
    }

    private static var cache: [String: SpotifyStrings] = [:]
    private static let lock = NSLock()

    static func load(language: String) -> SpotifyStrings? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[language] { return cached }
        // Always with English, which some labels stay in.
        let tables = [language, language.split(separator: "-").first.map(String.init) ?? language, "en"]
            .compactMap(table)
        guard !tables.isEmpty else { return nil }
        let strings = SpotifyStrings(
            download: Set(tables.compactMap { $0["download.download"] as? String }),
            remove: Set(tables.compactMap { $0["download.remove"] as? String }),
            connectPicker: Set(tables.compactMap { $0["playback-control.connect-picker"] as? String }),
            thisComputer: Set(tables.compactMap { $0["web-player.connect.device-picker.this-computer"] as? String })
        )
        cache[language] = strings
        return strings
    }

    private static func table(_ language: String) -> [String: Any]? {
        guard let archive = SpotifyInstance.appURL?.appendingPathComponent("Contents/Resources/Apps/xpui.spa") else { return nil }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-p", archive.path, "i18n/\(language).json"]
        let pipe = Pipe()
        unzip.standardOutput = pipe
        unzip.standardError = FileHandle.nullDevice
        do { try unzip.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        unzip.waitUntilExit()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Spotify's public pages: no login, no developer key.
enum SpotifyWeb {
    /// From the song page's `music:album` tag.
    static func albumID(ofTrack trackID: String) -> String? {
        let id = trackID.split(separator: ":").last.map(String.init) ?? trackID
        guard let url = URL(string: "https://open.spotify.com/track/\(id)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        let semaphore = DispatchSemaphore(value: 0)
        var page: String?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            page = data.flatMap { String(data: $0, encoding: .utf8) }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        guard let page,
              // In other languages the page and its links move under /intl-xx/.
              let tag = page.range(
                  of: #"music:album" content="https://open\.spotify\.com/(intl-[A-Za-z-]+/)?album/[A-Za-z0-9]+"#,
                  options: .regularExpression
              )
        else { return nil }
        return page[tag].split(separator: "/").last.map(String.init)
    }
}
