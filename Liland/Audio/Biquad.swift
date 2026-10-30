import Foundation

/// A two-pole filter from the Audio EQ Cookbook, run one sample at a time. Safe on the audio thread.
struct Biquad {
    /// The Q of the flattest response, without a bump at the corner.
    static let flat = Float(0.5).squareRoot()

    private let b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    private var z1: Float = 0, z2: Float = 0

    private init(b0: Float, b1: Float, b2: Float, a0: Float, a1: Float, a2: Float) {
        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }

    static func highPass(_ frequency: Float, q: Float = Biquad.flat, sampleRate: Double) -> Biquad {
        let (cosine, alpha) = shape(frequency, q: q, sampleRate: sampleRate)
        return Biquad(b0: (1 + cosine) / 2, b1: -(1 + cosine), b2: (1 + cosine) / 2, a0: 1 + alpha, a1: -2 * cosine, a2: 1 - alpha)
    }

    static func lowPass(_ frequency: Float, q: Float = Biquad.flat, sampleRate: Double) -> Biquad {
        let (cosine, alpha) = shape(frequency, q: q, sampleRate: sampleRate)
        return Biquad(b0: (1 - cosine) / 2, b1: 1 - cosine, b2: (1 - cosine) / 2, a0: 1 + alpha, a1: -2 * cosine, a2: 1 - alpha)
    }

    static func highShelf(_ frequency: Float, gain decibels: Float, q: Float = Biquad.flat, sampleRate: Double) -> Biquad {
        let (cosine, alpha) = shape(frequency, q: q, sampleRate: sampleRate)
        let gain = pow(10, decibels / 40)
        let root = 2 * gain.squareRoot() * alpha
        return Biquad(
            b0: gain * ((gain + 1) + (gain - 1) * cosine + root),
            b1: -2 * gain * ((gain - 1) + (gain + 1) * cosine),
            b2: gain * ((gain + 1) + (gain - 1) * cosine - root),
            a0: (gain + 1) - (gain - 1) * cosine + root,
            a1: 2 * ((gain - 1) - (gain + 1) * cosine),
            a2: (gain + 1) - (gain - 1) * cosine - root
        )
    }

    private static func shape(_ frequency: Float, q: Float, sampleRate: Double) -> (cosine: Float, alpha: Float) {
        let omega = 2 * Float.pi * frequency / Float(sampleRate)
        return (cos(omega), sin(omega) / (2 * q))
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}
