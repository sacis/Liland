import AppKit
import Observation
import os

/// DJ mode: the normal Spotify plays on the left; a second copy of it, offline, on the right, so one account
/// can play two songs. Each goes through its own `DeckProcessor` (which parts, tempo, key) and `DJAudioEngine`
/// mixes them. The faster song is slowed to the other's tempo and held so the beats land together.
@Observable
final class DJController {
    enum Side: Int, CaseIterable {
        case left, right

        var other: Side { self == .left ? .right : .left }
    }

    enum Role: CaseIterable {
        case vocals, instrumental, everything

        var parts: StemSplitter.Parts {
            switch self {
            case .vocals: .vocals
            case .instrumental: .instrumental
            case .everything: .everything
            }
        }
    }

    enum Step: Equatable {
        case off
        case needsAudioAccess
        case starting
        case ready
        /// That deck's Spotify window is open for the user to play a song in it.
        case choosing(Side)
        /// Downloading the right deck's song, so it can play offline next to the left one.
        case preparing(Side)
    }

    enum Sync: Equatable {
        case idle, listening, locked
    }

    enum Notice: Equatable {
        /// Picking songs drives the Spotify windows, which takes accessibility access.
        case needsAccessibility
        case downloadFailed, startFailed
    }

    struct Deck {
        var role: Role
        var track: SpotifyInstance.Track?
        var isPlaying = false
        var artwork: NSImage?
        var bpm: Double?
        var key: String?
        /// Semitones this deck is moved to suit the other's key.
        var shift = 0
    }

    static let profile = "liland-dj"
    private static let rightTrackKey = "djRightTrack"
    /// Seconds a freshly started copy stays online before it can play its downloads offline.
    private static let onlineBeforeOffline: TimeInterval = 6
    static let log = Logger(subsystem: "com.flaviasilva.Liland", category: "DJ")
    /// dB over the instrumental, so the voice sits on top as in a finished song.
    static let vocalBoost: Float = 2

    static var isSupported: Bool {
        if #available(macOS 14.4, *) { DemucsSplitter.isSupported } else { false }
    }

    private(set) var step: Step = .off
    private(set) var decks = DJController.freshDecks
    private(set) var sync: Sync = .idle
    private(set) var notice: Notice?
    private(set) var follower: Side?

    var isActive: Bool { step != .off }
    var isPlaying: Bool { decks.contains(where: \.isPlaying) }
    var isBusy: Bool {
        switch step {
        case .choosing, .preparing, .starting: true
        default: false
        }
    }

    /// The tempo both decks play at once in sync: the slower song's.
    var tempo: Double? {
        follower.flatMap { decks[$0.other.rawValue].bpm }
    }

    private static var freshDecks: [Deck] { [Deck(role: .vocals), Deck(role: .instrumental)] }

    // MARK: - Private state

    private struct Resume {
        let track: String
        let position: TimeInterval
        let date: Date
        let isPlaying: Bool
    }

    private struct Choosing {
        let side: Side
        let startTrack: String?
        /// What the account was playing when the right deck's window opened: a change means the user picked.
        var session: String?
        var resume: Resume?
    }

    /// One deck's beats, counted continuously though each estimate starts from a different recent beat.
    /// It follows the estimates gently; one that lands off the grid is only believed if the next ones agree.
    private struct BeatClock {
        private(set) var origin: Double
        private(set) var index: Double = 0
        private(set) var period: Double
        private var recent: [Double]
        private var misses = 0

        init(_ beats: BeatAnalyzer.Beats) {
            origin = beats.origin
            period = beats.period
            recent = [beats.period]
        }

        /// Once the last few tempo readings agree within 1%.
        var isSettled: Bool {
            guard recent.count >= 4, let low = recent.min(), let high = recent.max() else { return false }
            return (high - low) / low < 0.01
        }

        func beats(at position: Double) -> Double {
            index + (position - origin) / period
        }

        mutating func update(with beats: BeatAnalyzer.Beats) {
            recent = Array((recent + [beats.period]).suffix(5))
            let steps = (beats.origin - origin) / period
            let nearest = steps.rounded()
            let deviation = steps - nearest
            // Re-anchored on the newest beat each time, so small tempo errors don't add up.
            origin += nearest * period
            index += nearest
            if abs(deviation) < 0.2 && abs(beats.period - period) < 0.04 * period {
                origin += 0.3 * deviation * period
                period += 0.3 * (beats.period - period)
                misses = 0
            } else {
                misses += 1
                if misses >= 4 {
                    origin = beats.origin
                    period = beats.period
                    misses = 0
                }
            }
        }
    }

    private struct Lock {
        let follower: Side
        /// Multiplies the follower's beat period to count it at the leader's tempo: 2 when read at double.
        let octave: Double
        var isAligned = false
        var error: Double = 0
        var shift: Int?
    }

    @ObservationIgnored private let audioLevels: AudioLevelMonitor
    @ObservationIgnored private var instances: [SpotifyInstance?] = [nil, nil]
    @ObservationIgnored private let queue = DispatchQueue(label: "com.flaviasilva.Liland.DJ", qos: .userInitiated)
    @ObservationIgnored private let analysisQueue = DispatchQueue(label: "com.flaviasilva.Liland.DJ.analysis", qos: .utility)
    @ObservationIgnored private let engineQueue = DispatchQueue(label: "com.flaviasilva.Liland.DJ.engine", qos: .userInitiated)
    @ObservationIgnored private var engine: AnyObject?
    @ObservationIgnored private var isStartingEngine = false
    @ObservationIgnored private var hasRequestedAudio = false
    @ObservationIgnored private var processors: [DeckProcessor] = []
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var syncTimer: Timer?
    @ObservationIgnored private var analysisTimer: DispatchSourceTimer?
    @ObservationIgnored private var isPolling = false
    @ObservationIgnored private var states: [SpotifyInstance.State?] = [nil, nil]
    @ObservationIgnored private var choosing: Choosing?
    @ObservationIgnored private var clocks: [BeatClock?] = [nil, nil]
    @ObservationIgnored private var serials = [0, 0]
    @ObservationIgnored private var silentPolls = 0
    @ObservationIgnored private var nextPlayHere = Date.distantPast
    @ObservationIgnored private var lock: Lock?
    @ObservationIgnored private var lastLog = Date.distantPast
    @ObservationIgnored private var debugObserver: NSObjectProtocol?

    init(audioLevels: AudioLevelMonitor) {
        self.audioLevels = audioLevels
        #if DEBUG
        listenForDebugCommands()
        #endif
    }

    /// A copy left running by a Liland that didn't quit cleanly would answer AppleScript in place of the real one.
    func closeLeftoverCopy() {
        guard !isActive else { return }
        for instance in SpotifyInstance.running() where instance.profile == Self.profile {
            NSRunningApplication(processIdentifier: instance.pid)?.terminate()
        }
    }

    // MARK: - Entering and leaving

    func enter() {
        guard !isActive, Self.isSupported else { return }
        notice = nil
        step = .starting
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        proceed()
    }

    func exit() {
        guard isActive else { return }
        step = .off
        choosing = nil
        pollTimer?.invalidate()
        pollTimer = nil
        stopEngine()
        audioLevels.isSuspended = false
        let right = instances[Side.right.rawValue]
        instances = [nil, nil]
        states = [nil, nil]
        decks = Self.freshDecks
        queue.async {
            guard let right else { return }
            right.pause()
            NSRunningApplication(processIdentifier: right.pid)?.terminate()
        }
    }

    /// Re-run on every poll while something is missing (a permission, a Spotify).
    private func proceed() {
        guard isActive else { return }
        if AudioCapturePermission.status == .denied {
            step = .needsAudioAccess
            return
        }
        guard step == .starting || step == .needsAudioAccess else { return }
        step = .starting
        audioLevels.isSuspended = true
        startInstances()
    }

    private func startInstances() {
        let rightFrame = Self.half(.right)
        queue.async { [weak self] in
            let started = Date()
            func mark(_ step: String) {
                let seconds = Date().timeIntervalSince(started)
                Self.log.notice("starting: \(step, privacy: .public) after \(seconds, format: .fixed(precision: 1), privacy: .public) s")
            }
            let left = Self.waitForInstance(profile: nil) {
                guard let url = SpotifyInstance.appURL else { return }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            }
            mark("left Spotify answers")
            let right = Self.waitForInstance(profile: Self.profile) {
                SpotifyInstance.launch(profile: Self.profile, frame: rightFrame) { _ in }
            }
            mark("right Spotify answers")
            // Offline whenever it isn't being given a song: online, its play would stop the left one. But
            // just started, it only finds its downloads after a few seconds online.
            if let right, Accessibility.isTrusted {
                right.pause()
                mark("online: \(right.setOffline(false))")
                Thread.sleep(forTimeInterval: Self.onlineBeforeOffline)
                // Online it picked up whatever the account plays, which it may not have downloaded.
                let offline = right.setOffline(true)
                mark("offline: \(offline)")
                if offline, let last = UserDefaults.standard.string(forKey: Self.rightTrackKey) {
                    right.play(track: last)
                    Thread.sleep(forTimeInterval: 1)
                    right.pause()
                }
            }
            DispatchQueue.main.async {
                guard let self, self.step == .starting else { return }
                self.instances = [left, right]
                if left == nil || right == nil { self.notice = .startFailed }
                self.step = .ready
                self.startEngine()
            }
        }
    }

    /// Starts one if needed, then waits until it answers. Off main.
    private static func waitForInstance(profile: String?, start: () -> Void) -> SpotifyInstance? {
        func find() -> SpotifyInstance? {
            SpotifyInstance.running().first { $0.profile == profile && $0.state() != nil }
        }
        if let instance = find() { return instance }
        start()
        for _ in 0..<60 {
            Thread.sleep(forTimeInterval: 0.5)
            if let instance = find() { return instance }
        }
        return nil
    }

    // MARK: - Choosing songs

    /// Opens that deck's Spotify on its half of the screen; the song played there goes on the deck.
    func choose(_ side: Side) {
        guard step == .ready, let instance = instances[side.rawValue] else { return }
        guard Accessibility.isTrusted else {
            Accessibility.request()
            notice = .needsAccessibility
            return
        }
        notice = nil
        let frame = Self.half(side)
        var choosing = Choosing(side: side, startTrack: decks[side.rawValue].track?.id)
        if side == .right {
            choosing.session = states[Side.left.rawValue]?.track?.id
            choosing.resume = resume(from: states[Side.left.rawValue])
        }
        self.choosing = choosing
        step = .choosing(side)
        queue.async {
            if side == .right {
                instance.pause()
                instance.setOffline(false)
            }
            instance.show()
            Thread.sleep(forTimeInterval: 0.6)
            instance.moveWindow(to: frame)
        }
    }

    func cancelChoosing() {
        guard case .choosing(let side) = step, let instance = instances[side.rawValue] else { return }
        choosing = nil
        step = .ready
        queue.async {
            if side == .right { instance.setOffline(true) }
            instance.hide()
        }
    }

    private func resume(from state: SpotifyInstance.State?) -> Resume? {
        guard let state, let track = state.track else { return nil }
        return Resume(track: track.id, position: state.position, date: Date(), isPlaying: state.isPlaying)
    }

    /// The right copy has to be online to find a song, and playing it there takes the account's playback away
    /// from the left one. So: pause it, give the left its song back, download, go offline, play.
    private func prepareRight(track: String) {
        guard let right = instances[Side.right.rawValue] else { return }
        let left = instances[Side.left.rawValue]
        let resume = choosing?.resume
        choosing = nil
        step = .preparing(.right)
        queue.async { [weak self] in
            right.pause()
            right.setOffline(false)
            if let left, let resume {
                // Commands to the left copy go to the account's current device, which may be the right copy or
                // another device altogether: if it isn't heard here, bring the playback to it and say it again.
                left.play(track: resume.track)
                Thread.sleep(forTimeInterval: 1.5)
                if #available(macOS 14.4, *), !ProcessAudioTap.isPlayingAudio(pid: left.pid) {
                    left.playHere()
                    Thread.sleep(forTimeInterval: 1)
                    left.play(track: resume.track)
                }
                left.seek(to: resume.position + (resume.isPlaying ? Date().timeIntervalSince(resume.date) : 0))
                if !resume.isPlaying { left.pause() }
            }
            let result = right.download(albumOf: track)
            // Online, playing here would take the account's playback from the left: only once offline.
            if right.setOffline(true) {
                if result == .downloaded { UserDefaults.standard.set(track, forKey: Self.rightTrackKey) }
                Thread.sleep(forTimeInterval: 1)
                right.play(track: track)
                Thread.sleep(forTimeInterval: 0.5)
                if left?.state()?.isPlaying == true { right.play() }
            }
            right.hide()
            DispatchQueue.main.async {
                guard let self, self.step == .preparing(.right) else { return }
                self.step = .ready
                if result != .downloaded { self.notice = .downloadFailed }
            }
        }
    }

    // MARK: - Playing

    func playPause() {
        guard step == .ready else { return }
        let instances = instances.compactMap { $0 }
        let shouldPlay = !isPlaying
        for index in decks.indices { decks[index].isPlaying = shouldPlay }
        let right = self.instances[Side.right.rawValue]
        queue.async {
            for instance in instances {
                if !shouldPlay {
                    instance.pause()
                } else if instance !== right || instance.isOffline == true {
                    // Online, the right copy would take the account's playback from the left one, and a play
                    // it can't do yet is kept and carried out when it goes online.
                    instance.play()
                }
            }
        }
    }

    func setRole(_ role: Role, for side: Side) {
        decks[side.rawValue].role = role
        applyRoles()
    }

    /// The voice of one with the instrumental of the other, and back.
    func swap() {
        let left = decks[Side.left.rawValue].role
        decks[Side.left.rawValue].role = decks[Side.right.rawValue].role
        decks[Side.right.rawValue].role = left
        applyRoles()
    }

    /// Moves the slowed song a whole beat later (positive) or earlier, to line up bars instead of beats.
    func nudge(_ beats: Int) {
        guard let lock, processors.indices.contains(lock.follower.rawValue),
              let period = clocks[lock.follower.rawValue]?.period
        else { return }
        let samples = Int(period * lock.octave)
        processors[lock.follower.rawValue].adjust(beats > 0 ? .delay(samples * beats) : .skip(samples * -beats))
    }

    private func applyRoles() {
        for side in Side.allCases where processors.indices.contains(side.rawValue) {
            let role = decks[side.rawValue].role
            let gain = role == .vocals ? pow(10, Self.vocalBoost / 20) : 1
            processors[side.rawValue].set(parts: role.parts, gain: gain)
        }
    }

    // MARK: - Watching both Spotifys

    private func poll() {
        guard isActive else { return }
        if notice == .needsAccessibility && Accessibility.isTrusted { notice = nil }
        switch step {
        case .needsAudioAccess:
            proceed()
            return
        case .off, .starting:
            return
        default:
            break
        }
        if engine == nil { startEngine() }
        restartEngineIfOutputChanged()

        guard !isPolling else { return }
        isPolling = true
        let instances = instances
        queue.async { [weak self] in
            let states = instances.map { $0?.state() }
            var audible = [false, false]
            if #available(macOS 14.4, *) {
                audible = instances.map { $0.map { ProcessAudioTap.isPlayingAudio(pid: $0.pid) } ?? false }
            }
            DispatchQueue.main.async {
                self?.isPolling = false
                self?.apply(states, audible: audible)
            }
        }
    }

    /// `audible`: whether each copy is sending sound out on this Mac (it may be only showing another device's).
    private func apply(_ newStates: [SpotifyInstance.State?], audible: [Bool]) {
        guard isActive else { return }
        let left = Side.left.rawValue, right = Side.right.rawValue
        // Online to choose, the right copy is a remote for the account's current device (usually the left
        // copy): a song picked there plays over there. Both decks hold still until it's sorted out.
        let isHandlingRight = step == .choosing(.right) || step == .preparing(.right)
        if !isHandlingRight {
            for side in Side.allCases {
                guard let state = newStates[side.rawValue] else { continue }
                states[side.rawValue] = state
                var deck = decks[side.rawValue]
                if state.track?.id != deck.track?.id {
                    deck.track = state.track
                    deck.artwork = nil
                    deck.bpm = nil
                    deck.key = nil
                    deck.shift = 0
                    newTrack(on: side)
                    loadArtwork(for: side, url: state.track?.artworkURL)
                }
                deck.isPlaying = state.isPlaying
                decks[side.rawValue] = deck
            }
        }

        switch step {
        case .choosing(.left):
            if let track = decks[left].track?.id, track != choosing?.startTrack {
                choosing = nil
                step = .ready
                let instance = instances[left]
                queue.async { instance?.hide() }
            }
        case .choosing(.right):
            let session = newStates[left]?.track?.id
            if audible[right], let track = newStates[right]?.track?.id {
                // Played on the right copy itself.
                prepareRight(track: track)
            } else if let session, session != choosing?.session {
                // Played through it, on the account's current device.
                prepareRight(track: session)
            } else if let resume = resume(from: newStates[left]) {
                choosing?.resume = resume
            }
        case .ready:
            keepLeftPlayingHere(isPlaying: newStates[left]?.isPlaying == true, audible: audible[left])
        default:
            break
        }
    }

    /// The account can be playing on another device (a phone, another computer) with the left copy only
    /// showing it: nothing would reach the mix. Moves it back to this Mac.
    private func keepLeftPlayingHere(isPlaying: Bool, audible: Bool) {
        guard isPlaying, !audible else {
            silentPolls = 0
            return
        }
        silentPolls += 1
        guard silentPolls >= 4, Date() > nextPlayHere, Accessibility.isTrusted,
              let instance = instances[Side.left.rawValue]
        else { return }
        nextPlayHere = Date().addingTimeInterval(20)
        Self.log.notice("the left Spotify plays on another device: moving it here")
        queue.async { instance.playHere() }
    }

    private func newTrack(on side: Side) {
        guard processors.indices.contains(side.rawValue) else { return }
        processors[side.rawValue].analyzer.reset()
        clocks[side.rawValue] = nil
        serials[side.rawValue] = 0
        // What the slowed deck still holds is the old song.
        if lock?.follower == side { processors[side.rawValue].adjust(.flush) }
        lock = nil
        for index in processors.indices { processors[index].set(rate: 1, pitch: 0) }
    }

    private func loadArtwork(for side: Side, url: URL?) {
        guard let url else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let image = data.flatMap(NSImage.init(data:))
            DispatchQueue.main.async {
                guard let self, self.decks[side.rawValue].track?.artworkURL == url else { return }
                self.decks[side.rawValue].artwork = image
            }
        }.resume()
    }

    // MARK: - Audio

    private func startEngine() {
        guard #available(macOS 14.4, *), engine == nil, !isStartingEngine, isActive,
              let left = instances[Side.left.rawValue], let right = instances[Side.right.rawValue]
        else { return }
        switch AudioCapturePermission.status {
        case .denied:
            step = .needsAudioAccess
            return
        case .unknown where !hasRequestedAudio:
            // Asked by Liland itself: a tap made first leaves Core Audio waiting on a prompt that never shows.
            hasRequestedAudio = true
            isStartingEngine = true
            AudioCapturePermission.request { [weak self] _ in
                self?.isStartingEngine = false
                self?.startEngine()
            }
            return
        case .unknown, .authorized:
            break
        }
        // Each process appears once it has opened its audio.
        guard let leftProcess = ProcessAudioTap.process(pid: left.pid),
              let rightProcess = ProcessAudioTap.process(pid: right.pid),
              let output = ProcessAudioTap.defaultOutputDeviceUID,
              let sampleRate = ProcessAudioTap.defaultOutputSampleRate
        else { return }

        // Core Audio can take a while (or wait on the system) setting this up: never on main.
        isStartingEngine = true
        engineQueue.async { [weak self] in
            let processors = Side.allCases.compactMap { _ in DeckProcessor(sampleRate: sampleRate) }
            let engine = processors.count == 2
                ? DJAudioEngine(processes: [leftProcess, rightProcess], decks: processors, outputDeviceUID: output)
                : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.isStartingEngine = false
                guard let engine, self.isActive, self.engine == nil else { return }
                Self.log.notice("playing on \(output, privacy: .public) at \(sampleRate, privacy: .public) Hz")
                self.processors = processors
                self.engine = engine
                self.clocks = [nil, nil]
                self.lock = nil
                self.applyRoles()

                let timer = DispatchSource.makeTimerSource(queue: self.analysisQueue)
                timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
                timer.setEventHandler { processors.forEach { $0.analyzer.analyze() } }
                timer.resume()
                self.analysisTimer = timer
                self.syncTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    self?.updateSync()
                }
            }
        }
    }

    private func stopEngine() {
        syncTimer?.invalidate()
        syncTimer = nil
        analysisTimer?.cancel()
        analysisTimer = nil
        engine = nil
        processors = []
        clocks = [nil, nil]
        lock = nil
        follower = nil
        sync = .idle
    }

    private func restartEngineIfOutputChanged() {
        guard #available(macOS 14.4, *), let engine = engine as? DJAudioEngine,
              let output = ProcessAudioTap.defaultOutputDeviceUID, output != engine.outputDeviceUID
        else { return }
        stopEngine()
        startEngine()
    }

    // MARK: - Keeping the beats together

    /// Gain on the phase error, in rate per beat of error: corrects within a couple of beats.
    private static let correction = 0.5
    private static let slowest = 0.08 // the most it slows down to catch up
    private static let fastest = 0.03 // the most it speeds up, while there's music waiting

    private func updateSync() {
        guard #available(macOS 14.4, *), let engine = engine as? DJAudioEngine, processors.count == 2 else { return }
        let timings = engine.deckTimings
        let estimates = processors.map(\.analyzer.estimate)
        let sampleRate = processors[0].sampleRate

        for side in Side.allCases {
            let estimate = estimates[side.rawValue]
            if estimate.serial != serials[side.rawValue] {
                serials[side.rawValue] = estimate.serial
                if let beats = estimate.beats, beats.confidence > 0.05 {
                    if clocks[side.rawValue] == nil {
                        clocks[side.rawValue] = BeatClock(beats)
                    } else {
                        clocks[side.rawValue]?.update(with: beats)
                    }
                }
            }
            if let clock = clocks[side.rawValue], clock.isSettled {
                let bpm = (60 * sampleRate / clock.period * 10).rounded() / 10
                if decks[side.rawValue].bpm != bpm { decks[side.rawValue].bpm = bpm }
            }
            if estimate.heard > 8 {
                let key = MusicalKey.name(of: estimate.chroma)
                if decks[side.rawValue].key != key { decks[side.rawValue].key = key }
            }
        }

        let bothPlaying = decks.allSatisfy(\.isPlaying) && step == .ready
        guard bothPlaying, let left = clocks[Side.left.rawValue], let right = clocks[Side.right.rawValue],
              left.isSettled, right.isSettled
        else {
            if !bothPlaying, lock != nil { lock = nil }
            setSync(bothPlaying ? .listening : .idle)
            return
        }

        // The faster song follows: it can only be slowed, the music it would need hasn't arrived yet.
        // Tempos read an octave apart count as the same.
        var octave = 1.0
        while right.period * octave / left.period < 0.7 { octave *= 2 }
        while right.period * octave / left.period >= 1.4 { octave /= 2 }
        let relative = right.period * octave / left.period
        let faster: Side = relative <= 1 ? .right : .left
        if let current = lock?.follower, current != faster, abs(relative - 1) > 0.01 {
            lock = nil // the estimates changed their mind: start over
        }
        if lock == nil {
            lock = Lock(follower: faster, octave: faster == .right ? octave : 1 / octave)
            follower = faster
        }
        guard var lock else { return }
        let leader = lock.follower.other
        let followerClock = lock.follower == .right ? right : left
        let leaderClock = lock.follower == .right ? left : right
        let followerTiming = timings[lock.follower.rawValue], leaderTiming = timings[leader.rawValue]
        guard !followerTiming.isAdjusting else { return }

        let followerPeriod = followerClock.period * lock.octave
        let ratio = followerPeriod / leaderClock.period
        let difference = followerClock.beats(at: Double(followerTiming.playing)) / lock.octave
            - leaderClock.beats(at: Double(leaderTiming.playing))

        if !lock.isAligned {
            // Hold the follower back to the leader's next beat, or skip ahead if enough is waiting.
            let ahead = difference - difference.rounded(.down) // 0..<1 beats
            let behind = 1 - ahead
            if Double(followerTiming.backlog) > (behind + 0.1) * followerPeriod {
                processors[lock.follower.rawValue].adjust(.skip(Int(behind * followerPeriod)))
            } else if ahead > 0.02 {
                processors[lock.follower.rawValue].adjust(.delay(Int(ahead * followerPeriod)))
            }
            lock.isAligned = true
            self.lock = lock
            applyTempo(lock, ratio: ratio)
            setSync(.listening)
            return
        }

        let error = difference - difference.rounded() // -0.5…0.5 beats, positive when the follower is ahead
        lock.error += (error - lock.error) * 0.3
        var change = min(max(Self.correction * lock.error, -Self.fastest), Self.slowest)
        if Double(followerTiming.backlog) < 0.05 * followerPeriod { change = max(change, 0) }

        // Key: once both have played long enough to tell.
        if lock.shift == nil, estimates[lock.follower.rawValue].heard > 15, estimates[leader.rawValue].heard > 15 {
            let shift = MusicalKey.shift(estimates[lock.follower.rawValue].chroma, toSuit: estimates[leader.rawValue].chroma)
            lock.shift = shift
            decks[lock.follower.rawValue].shift = shift
        }
        self.lock = lock
        applyTempo(lock, ratio: ratio, change: change)
        setSync(abs(lock.error) < 0.05 ? .locked : .listening)

        if Date().timeIntervalSince(lastLog) > 2 {
            lastLog = Date()
            let line = String(
                format: "%@ follows at %.4f× (ratio %.4f), error %+.3f beats, %.2f s waiting, %.1f / %.1f BPM, shift %d",
                lock.follower == .left ? "left" : "right", ratio * (1 - change), ratio, lock.error,
                Double(followerTiming.backlog) / sampleRate,
                decks[0].bpm ?? 0, decks[1].bpm ?? 0, lock.shift ?? 0
            )
            Self.log.notice("\(line, privacy: .public)")
        }
    }

    private func applyTempo(_ lock: Lock, ratio: Double, change: Double = 0) {
        processors[lock.follower.rawValue].set(rate: ratio * (1 - change), pitch: Double(lock.shift ?? 0))
        processors[lock.follower.other.rawValue].set(rate: 1, pitch: 0)
    }

    private func setSync(_ value: Sync) {
        if sync != value { sync = value }
    }

    // MARK: - Screen

    /// Half of the screen with the notch, under the menu bar.
    static func half(_ side: Side) -> CGRect {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 875)
        let width = (visible.width / 2).rounded(.down)
        return CGRect(x: visible.minX + (side == .left ? 0 : width), y: visible.minY, width: width, height: visible.height)
    }

    // MARK: - Testing

    #if DEBUG
    /// `distnoted` commands for trying it without the mouse, e.g. "pick-right:spotify:track:…".
    private func listenForDebugCommands() {
        debugObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.flaviasilva.Liland.debug"), object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let command = note.object as? String else { return }
            Self.log.notice("debug command \(command, privacy: .public)")
            switch command {
            case "enter": self.enter()
            case "exit": self.exit()
            case "choose-left": self.choose(.left)
            case "choose-right": self.choose(.right)
            case "cancel": self.cancelChoosing()
            case "swap": self.swap()
            case "play": self.playPause()
            case "nudge+": self.nudge(1)
            case "nudge-": self.nudge(-1)
            case "state":
                let left = self.decks[0], right = self.decks[1]
                let line = "step \(self.step), sync \(self.sync), engine \(self.engine != nil), accessibility \(Accessibility.isTrusted), "
                    + "left \(left.track?.title ?? "-") \(left.role) \(left.isPlaying ? "playing" : "paused"), "
                    + "right \(right.track?.title ?? "-") \(right.role) \(right.isPlaying ? "playing" : "paused"), "
                    + "notice \(String(describing: self.notice)), "
                    + "keys \(left.key ?? "-") / \(right.key ?? "-"), shifts \(left.shift) / \(right.shift), bpm \(left.bpm ?? 0) / \(right.bpm ?? 0)"
                Self.log.notice("state: \(line, privacy: .public)")
            default:
                if command.hasPrefix("pick-right:") {
                    guard self.step == .ready else { return }
                    self.choosing = Choosing(side: .right, startTrack: nil, resume: self.resume(from: self.states[0]))
                    self.prepareRight(track: String(command.dropFirst("pick-right:".count)))
                } else if command.hasPrefix("pick-left:"), let left = self.instances[0] {
                    let track = String(command.dropFirst("pick-left:".count))
                    self.queue.async { left.play(track: track) }
                }
            }
        }
    }
    #endif
}
