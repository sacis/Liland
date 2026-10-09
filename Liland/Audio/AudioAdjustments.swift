import Foundation

/// How the user wants the music to sound in Advanced mode.
struct AudioAdjustments: Equatable, Codable {
    /// The part of the music to keep. Without stems this is an estimate, not a clean separation.
    enum Isolation: String, CaseIterable, Codable {
        case none, vocals, bass, drums
    }

    /// The equalizer's bands, from bass to treble. The first and last are shelves.
    static let bands: [(frequency: Float, label: String)] = [
        (80, "80"), (250, "250"), (1_000, "1k"), (4_000, "4k"), (10_000, "10k"),
    ]
    static let gainRange: ClosedRange<Float> = -12...12
    static let pitchRange: ClosedRange<Int> = -6...6

    var isolation = Isolation.none
    /// Decibels for each of `bands`.
    var gains = [Float](repeating: 0, count: AudioAdjustments.bands.count)
    /// Semitones up or down.
    var pitch = 0

    static let neutral = AudioAdjustments()

    func gain(_ band: Int) -> Float {
        gains.indices.contains(band) ? gains[band] : 0
    }

    mutating func setGain(_ gain: Float, for band: Int) {
        // Settings saved by a version with fewer bands are filled in flat.
        while gains.count < Self.bands.count { gains.append(0) }
        gains[band] = min(max(gain, Self.gainRange.lowerBound), Self.gainRange.upperBound)
    }
}
