import AppKit
import CryptoKit

/// Reads and controls the system's Now Playing through the bundled NowPlayingHelper,
/// run with /usr/bin/perl: since macOS 15.4 only Apple's own programs may use MediaRemote.
///
/// Apple can close this way in any macOS update. The stream then stays empty, or keeps
/// failing and is given up on; Spotify and Apple Music don't depend on it.
final class MediaRemoteBridge {
    /// What the system reports as playing (empty when nothing plays or the helper stopped),
    /// and the artwork. Called on the main queue.
    var onUpdate: ((_ state: [String: Any], _ artwork: Data?) -> Void)?
    /// The helper answered for the first time since `start`.
    var onReady: (() -> Void)?
    /// The helper didn't answer within the patience given to `start`, and was stopped.
    var onStuck: (() -> Void)?

    private static let perl = URL(fileURLWithPath: "/usr/bin/perl")
    /// A stream that lasts this long counts as healthy and resets the failure count.
    private static let healthyRun: TimeInterval = 60
    private static let maxFailures = 5

    private let script: URL
    private let framework: URL
    private let commandQueue = DispatchQueue(label: "com.flaviasilva.Liland.MediaRemoteBridge.commands")

    private var process: Process?
    private var hasOutput = false
    private var patience: TimeInterval = 10
    private var startDate = Date.distantPast
    private var failures = 0
    private var isStopping = false
    private var terminateObserver: NSObjectProtocol?

    /// nil when a piece is missing, for example if a future macOS no longer ships Perl.
    init?(bundle: Bundle = .main) {
        let fileManager = FileManager.default
        guard let script = bundle.url(forResource: "now-playing", withExtension: "pl"),
              let framework = bundle.privateFrameworksURL?.appendingPathComponent("NowPlayingHelper.framework"),
              fileManager.fileExists(atPath: framework.path),
              fileManager.isExecutableFile(atPath: Self.perl.path)
        else {
            NSLog("Liland: system Now Playing unavailable, the helper or Perl is missing")
            return nil
        }
        self.script = script
        self.framework = framework
    }

    deinit {
        stop()
    }

    /// True in a copy downloaded from the internet. Liland isn't notarized, so the first time
    /// Perl loads the helper macOS holds it until the user clicks Open Anyway in Privacy &
    /// Security, like for Liland itself. The flag stays after that, so it doesn't tell whether
    /// the user already did.
    var isQuarantined: Bool {
        let binary = framework.appendingPathComponent("NowPlayingHelper")
        return getxattr(binary.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }

    /// Identifies this build of the helper, which macOS approves on its own.
    var helperIdentity: String {
        let binary = framework.appendingPathComponent("NowPlayingHelper")
        guard let data = try? Data(contentsOf: binary) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Streaming

    /// `patience`: how long to wait for the helper's first answer, which it prints right
    /// away unless macOS is holding it for approval.
    func start(patience: TimeInterval = 10) {
        guard process == nil else { return }
        isStopping = false
        failures = 0
        self.patience = patience
        if terminateObserver == nil {
            terminateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.stop() }
        }
        launchStream()
    }

    func stop() {
        isStopping = true
        process?.terminate()
        process = nil
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
            self.terminateObserver = nil
        }
    }

    private func launchStream() {
        let process = makeProcess(["stream"])
        let output = Pipe()
        process.standardOutput = output
        let errors = Pipe()
        process.standardError = errors

        process.terminationHandler = { [weak self] ended in
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async { self?.streamEnded(ended, message: message) }
        }

        do {
            try process.run()
        } catch {
            NSLog("Liland: could not start the Now Playing helper: \(error)")
            scheduleRestart()
            return
        }
        self.process = process
        hasOutput = false
        startDate = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + patience) { [weak self] in
            guard let self, self.process === process, !self.hasOutput else { return }
            NSLog("Liland: the Now Playing helper didn't answer, stopping it")
            self.stop()
            self.onStuck?()
        }

        let reader = output.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            var artwork: Data?
            Self.readLines(from: reader) { line in
                guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      let state = message["state"] as? [String: Any]
                else { return }
                // "artwork" is only sent when it changed; null means there is none.
                if let value = message["artwork"] {
                    artwork = (value as? String).flatMap { Data(base64Encoded: $0) }
                }
                let currentArtwork = artwork
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.process === process else { return }
                    if !self.hasOutput {
                        self.hasOutput = true
                        self.onReady?()
                    }
                    self.onUpdate?(state, currentArtwork)
                }
            }
        }
    }

    private func streamEnded(_ ended: Process, message: String) {
        guard ended === process || process == nil else { return }
        process = nil
        onUpdate?([:], nil)
        guard !isStopping else { return }

        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog("Liland: Now Playing helper exited with status \(ended.terminationStatus)\(trimmed.isEmpty ? "" : ": \(trimmed)")")
        // Ending before its first answer isn't a hiccup worth retrying, e.g. macOS refused it.
        guard hasOutput else {
            stop()
            onStuck?()
            return
        }
        if Date().timeIntervalSince(startDate) > Self.healthyRun {
            failures = 0
        }
        scheduleRestart()
    }

    private func scheduleRestart() {
        failures += 1
        guard failures <= Self.maxFailures else {
            NSLog("Liland: giving up on the Now Playing helper after \(Self.maxFailures) failures")
            return
        }
        let delay = min(pow(2, Double(failures)), 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isStopping, self.process == nil else { return }
            self.launchStream()
        }
    }

    /// Calls `onLine` with each newline-terminated line until the pipe closes.
    private static func readLines(from handle: FileHandle, onLine: (Data) -> Void) {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if !line.isEmpty { onLine(Data(line)) }
            }
        }
    }

    // MARK: - Commands

    enum Command {
        case togglePlayPause
        case nextTrack
        case previousTrack
        case seek(TimeInterval)
        case shuffle(Bool)
        case repeatMode(RepeatMode)

        var arguments: [String] {
            switch self {
            case .togglePlayPause: ["togglePlayPause"]
            case .nextTrack: ["nextTrack"]
            case .previousTrack: ["previousTrack"]
            case .seek(let seconds): ["seek", String(max(seconds, 0))]
            // MediaRemote's shuffle modes: 1 off, 2 albums, 3 songs.
            case .shuffle(let isOn): ["shuffle", isOn ? "3" : "1"]
            case .repeatMode(let mode): ["repeat", String(mode.mediaRemoteValue)]
            }
        }
    }

    /// Each command is a short run of the helper; a stuck one is stopped after a few seconds.
    func send(_ command: Command) {
        let process = makeProcess(["command"] + command.arguments)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        commandQueue.async {
            do {
                try process.run()
            } catch {
                NSLog("Liland: could not send \(command) to the Now Playing helper: \(error)")
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if process.isRunning { process.terminate() }
            }
        }
    }

    private func makeProcess(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = Self.perl
        process.arguments = [script.path, framework.path] + arguments
        return process
    }
}

extension RepeatMode {
    /// MediaRemote's repeat modes: 1 off, 2 the song, 3 the whole list.
    init?(mediaRemoteValue: Int) {
        switch mediaRemoteValue {
        case 1: self = .off
        case 2: self = .one
        case 3: self = .all
        default: return nil
        }
    }

    var mediaRemoteValue: Int {
        switch self {
        case .off: 1
        case .one: 2
        case .all: 3
        }
    }
}
