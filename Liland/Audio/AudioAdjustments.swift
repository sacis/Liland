import Foundation

struct AudioAdjustments: Equatable, Codable {
    /// Case order is the button order. Without stems it's an estimate, not a clean separation.
    enum Part: String, CaseIterable, Codable {
        case vocals, guitar, bass, drums
    }

    static let bands: [(frequency: Float, label: String)] = [
        (80, "80"), (250, "250"), (1_000, "1k"), (4_000, "4k"), (10_000, "10k"),
    ]
    static let gainRange: ClosedRange<Float> = -12...12
    static let pitchRange: ClosedRange<Int> = -6...6

    var isolated: Set<Part> = []
    var gains = [Float](repeating: 0, count: AudioAdjustments.bands.count) // dB
    var pitch = 0 // semitones

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
        // Settings saved by a version with fewer bands are filled in flat.
        while gains.count < Self.bands.count { gains.append(0) }
        gains[band] = min(max(gain, Self.gainRange.lowerBound), Self.gainRange.upperBound)
    }
}

extension AudioAdjustments {
    private enum CodingKeys: String, CodingKey {
        case isolated, gains, pitch
    }

    /// Missing or unknown values (like settings from an older version) fall back to neutral.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isolated = (try? container.decodeIfPresent(Set<Part>.self, forKey: .isolated)) ?? []
        gains = (try? container.decodeIfPresent([Float].self, forKey: .gains)) ?? Self.neutral.gains
        pitch = (try? container.decodeIfPresent(Int.self, forKey: .pitch)) ?? 0
    }
}
