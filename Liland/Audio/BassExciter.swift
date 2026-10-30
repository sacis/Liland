import Foundation

/// Brings back the brightness of an isolated bass, like the bass enhancers used in mixing.
///
/// A bass's clarity is in its harmonics above about 300 Hz, but there they're much quieter than
/// the voices and instruments around them and can't be told apart, so isolating the bass drops
/// them and it sounds muffled. This recreates them from the isolated bass itself: a gentle
/// saturation of a note makes harmonics at exact multiples of that note, and only those above
/// the bass's own range are kept. Since they're made from the bass alone, nothing else comes back.
struct BassExciter {
    /// How loud the recreated harmonics are next to the bass.
    private static let amount: Float = 2
    /// Below this the bass already has its harmonics; above `ceiling`, a bass's fade out.
    private static let floor: Float = 280
    private static let ceiling: Float = 3_000
    /// How hard the bass is pushed into the saturation: higher makes more and brighter harmonics.
    private static let drive: Float = 2

    private let smoothing: Float
    private var power: Float = 0
    private var highPass: (Biquad, Biquad)
    private var lowPass: Biquad

    init(sampleRate: Double) {
        // Follows the bass's level over about 30 ms, a little longer than its lowest notes' cycle.
        smoothing = 1 - exp(-1 / (0.03 * Float(sampleRate)))
        highPass = (.highPass(Self.floor, sampleRate: sampleRate), .highPass(Self.floor, sampleRate: sampleRate))
        lowPass = .lowPass(Self.ceiling, sampleRate: sampleRate)
    }

    /// The harmonics to add for the next sample of the isolated bass.
    mutating func process(_ bass: Float) -> Float {
        power += (bass * bass - power) * smoothing
        let level = power.squareRoot()
        // Saturate the bass at a steady level, so quiet and loud notes get the same harmonics,
        // then bring it back to its level. The rectified half adds the even harmonics.
        var harmonics: Float = 0
        if level > 1e-6 {
            let saturated = tanh(Self.drive * bass / level)
            harmonics = (saturated + 0.5 * abs(saturated)) * level
        }
        let kept = lowPass.process(highPass.1.process(highPass.0.process(harmonics)))
        return kept * Self.amount
    }
}
