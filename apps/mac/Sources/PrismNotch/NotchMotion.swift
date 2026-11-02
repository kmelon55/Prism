import Foundation

/// A damped spring for the silhouette only. Window and content frames never follow these samples.
struct NotchMotion {
    struct Sample {
        var size: CGSize
        var velocity: CGSize
    }
    let from: CGSize
    let to: CGSize
    var velocity = CGSize.zero
    let began: TimeInterval
    static let duration: TimeInterval = 0.56

    func sample(at time: TimeInterval) -> Sample {
        let t = max(0, time - began)
        guard t < Self.duration else { return Sample(size: to, velocity: .zero) }
        func axis(_ start: CGFloat, _ end: CGFloat, _ speed: CGFloat) -> (CGFloat, CGFloat) {
            let decay = 19.0, frequency = 10.0
            let a = Double(start - end), b = (Double(speed) + decay * a) / frequency
            let wave = a * cos(frequency * t) + b * sin(frequency * t)
            let derivative = -a * frequency * sin(frequency * t) + b * frequency * cos(frequency * t)
            return (CGFloat(Double(end) + exp(-decay * t) * wave), CGFloat(exp(-decay * t) * (derivative - decay * wave)))
        }
        let w = axis(from.width, to.width, velocity.width), h = axis(from.height, to.height, velocity.height)
        return Sample(size: CGSize(width: max(1, w.0), height: max(1, h.0)), velocity: CGSize(width: w.1, height: h.1))
    }
}
