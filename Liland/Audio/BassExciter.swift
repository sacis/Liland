import Foundation

/// Recreates the harmonics above ~300 Hz that isolation drops, by gently saturating the isolated bass.
struct BassExciter {
    private static let amount: Float = 2
    /// Hz. Below this the bass still has its harmonics; above `ceiling`, a bass's fade out.
    private static let floor: Float = 280
    private static let ceiling: Float = 3_000
    private static let drive: Float = 2

    private let smoothing: Float
    private var power: Float = 0
    private var highPass: (Biquad, Biquad)
    private var lowPass: Biquad

    init(sampleRate: Double) {
        // ~30 ms, a little longer than the lowest notes' cycle.
        smoothing = 1 - exp(-1 / (0.03 * Float(sampleRate)))
        highPass = (.highPass(Self.floor, sampleRate: sampleRate), .highPass(Self.floor, sampleRate: sampleRate))
        lowPass = .lowPass(Self.ceiling, sampleRate: sampleRate)
    }

    mutating func process(_ bass: Float) -> Float {
        power += (bass * bass - power) * smoothing
        let level = power.squareRoot()
        // Saturate at a steady level so all notes get the same harmonics; rectifying adds the even ones.
        var harmonics: Float = 0
        if level > 1e-6 {
            let saturated = tanh(Self.drive * bass / level)
            harmonics = (saturated + 0.5 * abs(saturated)) * level
        }
        let kept = lowPass.process(highPass.1.process(highPass.0.process(harmonics)))
        return kept * Self.amount
    }
}
