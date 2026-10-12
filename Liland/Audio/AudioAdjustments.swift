import Foundation

/// How the user wants the music to sound in Advanced mode.
struct AudioAdjustments: Equatable, Codable {
    /// A part of the music that can be kept on its own. Without stems this is an estimate, not a clean separation.
    enum Part: String, CaseIterable, Codable {
        case vocals, bass, drums
    }

    /// The equalizer's bands, from bass to treble. The first and last are shelves.
    static let bands: [(frequency: Float, label: String)] = [
        (80, "80"), (250, "250"), (1_000, "1k"), (4_000, "4k"), (10_000, "10k"),
    ]
    static let gainRange: ClosedRange<Float> = -12...12
    static let pitchRange: ClosedRange<Int> = -6...6

    /// The parts to keep; empty plays the whole song.
    var isolated: Set<Part> = []
    /// Decibels for each of `bands`.
    var gains = [Float](repeating: 0, count: AudioAdjustments.bands.count)
    /// Semitones up or down.
    var pitch = 0

    static let neutral = AudioAdjustments()

    /// Adds the part, or takes it out if it's already kept. Taking out the last one plays the whole song again.
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

    /// Anything missing or unknown (like settings from an older version) falls back to neutral.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isolated = (try? container.decodeIfPresent(Set<Part>.self, forKey: .isolated)) ?? []
        gains = (try? container.decodeIfPresent([Float].self, forKey: .gains)) ?? Self.neutral.gains
        pitch = (try? container.decodeIfPresent(Int.self, forKey: .pitch)) ?? 0
    }
}
