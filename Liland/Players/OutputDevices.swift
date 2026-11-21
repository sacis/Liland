import AppKit
import CoreAudio
import Observation

struct OutputDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let symbol: String
    var isActive: Bool
    var isEnabled = true
}

@Observable
final class OutputDevices {
    enum Source {
        case spotify
        case appleMusic
        case system
    }

    enum State: Equatable {
        case loading
        case ready
        case signedOut
        case signingIn
        case failed(title: String, subtitle: String)
    }

    private(set) var source = Source.system
    private(set) var devices: [OutputDevice] = []
    private(set) var state = State.loading
    private(set) var switchingID: String?

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let queue = DispatchQueue(label: "com.flaviasilva.Liland.OutputDevices")

    var rows: Int { state == .ready ? max(devices.count, 1) : 1 }

    func load(for player: (any MusicPlayer)?) {
        source = switch player?.id {
        case PlayerDefinition.spotify.bundleIdentifier: .spotify
        case PlayerDefinition.appleMusic.bundleIdentifier: .appleMusic
        default: .system
        }
        devices = []
        switchingID = nil
        reload()
    }

    func reload() {
        generation += 1
        let current = generation
        switch source {
        case .spotify:
            let spotify = SpotifyConnect.shared
            if spotify.isSigningIn { return state = .signingIn }
            guard spotify.isSignedIn else { return state = .signedOut }
            if devices.isEmpty { state = .loading }
            spotify.devices { [weak self] result in
                guard let self, self.generation == current else { return }
                switch result {
                case .success(let list):
                    self.devices = list.map(Self.device(from:))
                    self.state = .ready
                case .failure(let failure):
                    self.fail(failure)
                }
            }
        case .appleMusic:
            if devices.isEmpty { state = .loading }
            queue.async {
                let list = AppleMusicAirPlay.devices()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == current else { return }
                    guard let list else { return self.fail(.unreachable) }
                    self.devices = list
                    self.state = .ready
                }
            }
        case .system:
            devices = SystemOutputs.devices()
            state = .ready
        }
    }

    func select(_ device: OutputDevice) {
        guard !device.isActive, device.isEnabled, switchingID == nil else { return }
        switchingID = device.id
        switch source {
        case .spotify:
            SpotifyConnect.shared.transfer(to: device.id) { [weak self] result in
                guard let self else { return }
                self.switchingID = nil
                switch result {
                case .success:
                    self.markActive(device.id)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.reload() }
                case .failure(let failure):
                    self.fail(failure)
                }
            }
        case .appleMusic:
            queue.async {
                AppleMusicAirPlay.select(device.name)
                DispatchQueue.main.async { [weak self] in
                    self?.switchingID = nil
                    self?.reload()
                }
            }
        case .system:
            SystemOutputs.select(device.id)
            switchingID = nil
            reload()
        }
    }

    func signIn() {
        state = .signingIn
        SpotifyConnect.shared.signIn { [weak self] success in
            guard let self, self.source == .spotify else { return }
            if success { self.reload() } else { self.state = .signedOut }
        }
    }

    private func markActive(_ id: String) {
        for index in devices.indices {
            devices[index].isActive = devices[index].id == id
        }
    }

    private func fail(_ failure: SpotifyConnect.Failure) {
        let title = String(localized: "Couldn't connect")
        state = switch failure {
        case .signedOut: .signedOut
        case .notAllowed: .failed(title: title, subtitle: String(localized: "Spotify only allows accounts added to Liland"))
        case .rejected: .failed(title: title, subtitle: String(localized: "Spotify didn't accept the change"))
        case .unreachable: .failed(title: title, subtitle: String(localized: "Check your internet and try again"))
        }
    }

    private static func device(from device: SpotifyConnect.Device) -> OutputDevice {
        let symbol = switch device.type.lowercased() {
        case "computer": "laptopcomputer"
        case "smartphone": "iphone"
        case "tablet": "ipad"
        case "tv", "castvideo", "stb": "tv"
        case "avr": "hifireceiver"
        case "gameconsole": "gamecontroller"
        case "automobile": "car"
        case "speaker", "castaudio", "audiodongle": "hifispeaker"
        default: "speaker.wave.2"
        }
        return OutputDevice(id: device.id, name: device.name, symbol: symbol, isActive: device.isActive, isEnabled: !device.isRestricted)
    }
}

private enum AppleMusicAirPlay {
    private static let app = "application id \"\(PlayerDefinition.appleMusic.bundleIdentifier)\""

    static func devices() -> [OutputDevice]? {
        let script = """
        if \(app) is not running then return {}
        tell \(app)
            set out to {}
            repeat with d in (every AirPlay device whose available is true)
                set k to ""
                try
                    set k to (kind of d) as string
                end try
                set end of out to {name of d, k, selected of d}
            end repeat
            return out
        end tell
        """
        guard case .success(let list) = AppleScript.run(script) else { return nil }
        return (0..<list.numberOfItems).compactMap { index in
            guard let item = list.atIndex(index + 1), let name = item.atIndex(1)?.stringValue else { return nil }
            return OutputDevice(
                id: name,
                name: name,
                symbol: symbol(for: item.atIndex(2)?.stringValue ?? ""),
                isActive: item.atIndex(3)?.booleanValue ?? false
            )
        }
    }

    static func select(_ name: String) {
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        _ = AppleScript.run("tell \(app) to set current AirPlay devices to (every AirPlay device whose name is \"\(escaped)\")")
    }

    private static func symbol(for kind: String) -> String {
        switch kind.lowercased() {
        case "computer": "laptopcomputer"
        case "apple tv": "appletv"
        case "homepod": "homepod"
        case "bluetooth device": "headphones"
        case "tv": "tv"
        default: "hifispeaker"
        }
    }
}

private enum SystemOutputs {
    static func devices() -> [OutputDevice] {
        var current = AudioObjectID(kAudioObjectUnknown)
        _ = AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, into: &current)
        return AudioObjectID.system.objects(kAudioHardwarePropertyDevices).compactMap { device in
            guard !device.objects(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput).isEmpty else { return nil }
            var transport: UInt32 = 0
            var hidden: UInt32 = 0
            _ = device.read(kAudioDevicePropertyTransportType, into: &transport)
            _ = device.read(kAudioDevicePropertyIsHidden, into: &hidden)
            guard transport != kAudioDeviceTransportTypeAggregate, hidden == 0,
                  let uid = device.string(kAudioDevicePropertyDeviceUID),
                  let name = device.string(kAudioObjectPropertyName)
            else { return nil }
            return OutputDevice(id: uid, name: name, symbol: symbol(for: transport), isActive: device == current)
        }
    }

    static func select(_ uid: String) {
        guard var device = AudioObjectID.system.objects(kAudioHardwarePropertyDevices)
            .first(where: { $0.string(kAudioDevicePropertyDeviceUID) == uid })
        else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(AudioObjectID.system, &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &device)
    }

    private static func symbol(for transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "headphones"
        case kAudioDeviceTransportTypeAirPlay: "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: "tv"
        case kAudioDeviceTransportTypeVirtual: "waveform"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt: "hifispeaker"
        default: "speaker.wave.2"
        }
    }
}
