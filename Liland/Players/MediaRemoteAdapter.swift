import AppKit

/// Reads and controls the system's Now Playing through the bundled mediaremote-adapter,
/// run with /usr/bin/perl: since macOS 15.4 only Apple's own programs may use MediaRemote.
///
/// Apple can close this way in any macOS update. The stream then stays empty, or keeps
/// failing and is given up on; Spotify and Apple Music don't depend on it.
final class MediaRemoteAdapter {
    /// What the system reports as playing, with `artworkData` already decoded.
    /// Empty when nothing is playing or the adapter stopped. Called on the main queue.
    var onUpdate: (([String: Any]) -> Void)?

    private static let perl = URL(fileURLWithPath: "/usr/bin/perl")
    /// Merges bursts of small updates, e.g. title and artwork arriving separately.
    private static let streamOptions = ["--micros", "--debounce=150"]
    /// A stream that lasts this long counts as healthy and resets the failure count.
    private static let healthyRun: TimeInterval = 60
    private static let maxFailures = 5

    private let script: URL
    private let framework: URL
    private let readQueue = DispatchQueue(label: "com.flaviasilva.Liland.MediaRemoteAdapter.read")
    private let commandQueue = DispatchQueue(label: "com.flaviasilva.Liland.MediaRemoteAdapter.commands")

    private var process: Process?
    private var startDate = Date.distantPast
    private var failures = 0
    private var isStopping = false
    private var terminateObserver: NSObjectProtocol?

    /// nil when a piece is missing, for example if a future macOS no longer ships Perl.
    init?(bundle: Bundle = .main) {
        let fileManager = FileManager.default
        guard let script = bundle.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let framework = bundle.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework"),
              fileManager.fileExists(atPath: framework.path),
              fileManager.isExecutableFile(atPath: Self.perl.path)
        else {
            NSLog("Liland: system Now Playing unavailable, the adapter or Perl is missing")
            return nil
        }
        self.script = script
        self.framework = framework
    }

    deinit {
        stop()
    }

    // MARK: - Streaming

    func start() {
        guard process == nil else { return }
        isStopping = false
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
        let process = makeProcess(["stream"] + Self.streamOptions)
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
            NSLog("Liland: could not start the Now Playing adapter: \(error)")
            scheduleRestart()
            return
        }
        self.process = process
        startDate = Date()

        let reader = output.fileHandleForReading
        readQueue.async { [weak self] in
            Self.readLines(from: reader) { line in
                guard let state = self?.merge(line) else { return }
                DispatchQueue.main.async {
                    guard let self, self.process === process else { return }
                    self.onUpdate?(state)
                }
            }
        }
    }

    private func streamEnded(_ ended: Process, message: String) {
        guard ended === process || process == nil else { return }
        process = nil
        onUpdate?([:])
        guard !isStopping else { return }

        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog("Liland: Now Playing adapter exited with status \(ended.terminationStatus)\(trimmed.isEmpty ? "" : ": \(trimmed)")")
        if Date().timeIntervalSince(startDate) > Self.healthyRun {
            failures = 0
        }
        scheduleRestart()
    }

    private func scheduleRestart() {
        failures += 1
        guard failures <= Self.maxFailures else {
            NSLog("Liland: giving up on the Now Playing adapter after \(Self.maxFailures) failures")
            return
        }
        let delay = min(pow(2, Double(failures)), 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isStopping, self.process == nil else { return }
            self.launchStream()
        }
    }

    // MARK: - Parsing (on readQueue)

    /// The state built from the stream so far. Only touched on `readQueue`.
    private var state: [String: Any] = [:]

    /// Applies one line of the stream and returns the new state, or nil if the line was unusable.
    private func merge(_ line: Data) -> [String: Any]? {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let payload = message["payload"] as? [String: Any]
        else { return nil }

        // Without "diff", the payload is the whole state; with it, only what changed (null = removed).
        if message["diff"] as? Bool != true {
            state = [:]
        }
        for (key, value) in payload {
            if value is NSNull {
                state[key] = nil
            } else if key == "artworkData", let base64 = value as? String {
                state[key] = Data(base64Encoded: base64)
            } else {
                state[key] = value
            }
        }
        return state
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

    enum Command: Int {
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    func send(_ command: Command) {
        runCommand(["send", String(command.rawValue)])
    }

    func seek(to seconds: TimeInterval) {
        runCommand(["seek", String(Int(max(seconds, 0) * 1_000_000))])
    }

    /// Commands are short-lived runs of the script; a stuck one is killed after a few seconds.
    private func runCommand(_ arguments: [String]) {
        let process = makeProcess(arguments)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        commandQueue.async {
            do {
                try process.run()
            } catch {
                NSLog("Liland: could not send \(arguments) to the Now Playing adapter: \(error)")
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
