import Foundation

struct AudioAdjustments: Equatable, Codable {
    enum Part: String, CaseIterable, Codable {
        case vocals, guitar, bass, drums
    }

    static let bands: [(frequency: Float, label: String)] = [
        (80, "80"), (250, "250"), (1_000, "1k"), (4_000, "4k"), (10_000, "10k"),
    ]
    static let gainRange: ClosedRange<Float> = -12...12
    static let pitchRange: ClosedRange<Int> = -6...6
    static let volumeRange: ClosedRange<Float> = 0...2

    var isolated: Set<Part> = []
    var gains = [Float](repeating: 0, count: AudioAdjustments.bands.count)
    var pitch = 0
    var volumes: [Part: Float] = [:]
    var othersVolume: Float = 1

    static let neutral = AudioAdjustments()

    mutating func toggle(_ part: Part) {
        if isolated.remove(part) == nil {
            isolated.insert(part)
        }
    }

    func gain(_ band: Int) -> Float {
        gains.indices.contains(band) ? gains[band] : 0
    }

    mutating func setGain(_ gain: Float, for band: Int) {
        while gains.count < Self.bands.count { gains.append(0) }
        gains[band] = min(max(gain, Self.gainRange.lowerBound), Self.gainRange.upperBound)
    }

    func volume(_ part: Part) -> Float {
        volumes[part] ?? 1
    }

    mutating func setVolume(_ volume: Float, for part: Part) {
        let volume = Self.clampVolume(volume)
        volumes[part] = volume == 1 ? nil : volume
    }

    mutating func setOthersVolume(_ volume: Float) {
        othersVolume = Self.clampVolume(volume)
    }

    private static func clampVolume(_ volume: Float) -> Float {
        min(max(volume, volumeRange.lowerBound), volumeRange.upperBound)
    }
}

extension AudioAdjustments {
    private enum CodingKeys: String, CodingKey {
        case isolated, gains, pitch, volumes, othersVolume
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isolated = (try? container.decodeIfPresent(Set<Part>.self, forKey: .isolated)) ?? []
        gains = (try? container.decodeIfPresent([Float].self, forKey: .gains)) ?? Self.neutral.gains
        pitch = (try? container.decodeIfPresent(Int.self, forKey: .pitch)) ?? 0
        volumes = ((try? container.decodeIfPresent([Part: Float].self, forKey: .volumes)) ?? [:]).filter { $0.value != 1 }
        othersVolume = (try? container.decodeIfPresent(Float.self, forKey: .othersVolume)) ?? 1
    }
}
