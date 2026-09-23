import Foundation

public enum TempoEstimationError: Error, LocalizedError, Equatable {
    case invalidInput
    case tooShort
    case noPeriodicity

    public var errorDescription: String? {
        switch self {
        case .invalidInput: return "节拍分析的输入无效。"
        case .tooShort: return "音频太短，至少需要约 \(Int(TempoEstimator.minimumSeconds)) 秒才能估计节拍。"
        case .noPeriodicity: return "没有找到稳定的节拍周期。可以手动填写 BPM。"
        }
    }
}

/// How much periodic structure backed an estimate. Thresholds are on the
/// normalized onset autocorrelation and describe periodicity, not correctness.
public enum TempoConfidence: String, Codable, Sendable {
    case high, medium, low

    public init(_ value: Double) {
        if value >= 0.3 { self = .high } else if value >= 0.12 { self = .medium } else { self = .low }
    }

    public var label: String {
        switch self {
        case .high: return "高"
        case .medium: return "中"
        case .low: return "低"
        }
    }
}

public struct TempoEstimate: Codable, Equatable, Sendable {
    public let bpm: Double
    /// Normalized autocorrelation of the onset envelope at the chosen beat period, 0…1.
    public let confidence: Double

    public var level: TempoConfidence { TempoConfidence(confidence) }
    public var beatSeconds: Double { 60 / bpm }

    public init(bpm: Double, confidence: Double) {
        self.bpm = bpm
        self.confidence = confidence
    }
}

/// Estimates one overall tempo from an onset-strength envelope: local-mean removal,
/// half-wave rectification and square-root compression, then the autocorrelation
/// scored with a log-normal tempo prior and its 2× and 4× period harmonics. The
/// result is a BPM with a periodicity confidence. It does not find the first beat,
/// follow tempo changes, or decide between a tempo and its double on its own
/// beyond the prior; dancers correct that by ear with the ½× / 2× multipliers.
public enum TempoEstimator {
    public static let bpmRange: ClosedRange<Double> = 50...200
    public static let minimumSeconds = 8.0
    public static let minimumConfidence = 0.04
    /// Street-dance tracks cluster between hip-hop (~90) and house (~125).
    public static let priorBPM = 110.0
    public static let priorWidthOctaves = 1.0
    static let harmonicWeights: [(Int, Double)] = [(1, 1), (2, 0.5), (4, 0.5), (8, 0.25)]
    static let subharmonicWeight = 0.5

    public static func estimate(onsetEnvelope: [Double], framesPerSecond fps: Double) throws -> TempoEstimate {
        guard fps.isFinite, fps > 0, onsetEnvelope.allSatisfy(\.isFinite) else { throw TempoEstimationError.invalidInput }
        let n = onsetEnvelope.count
        let minLag = max(1, Int((60 / bpmRange.upperBound * fps).rounded(.down)))
        let maxLag = Int((60 / bpmRange.lowerBound * fps).rounded(.up))
        guard Double(n) / fps >= minimumSeconds, maxLag * 2 < n, minLag < maxLag else { throw TempoEstimationError.tooShort }

        let x = prepared(onsetEnvelope, meanWindow: max(1, Int(fps.rounded())))
        let lagLimit = min(n / 2, maxLag * 8)
        var r = autocorrelation(x, upTo: lagLimit)
        guard r[0] > 0 else { throw TempoEstimationError.noPeriodicity }
        let r0 = r[0]
        for lag in r.indices { r[lag] /= r0 }

        var scores = [Double](repeating: 0, count: maxLag + 1)
        var bestLag = minLag
        for lag in minLag...maxLag {
            let bpm = 60 * fps / Double(lag)
            let prior = exp(-0.5 * pow(log2(bpm / priorBPM) / priorWidthOctaves, 2))
            // Beat, half note, bar and two bars: a duple hierarchy outscores dotted
            // subdivisions whose multiples never line up with the bar.
            var harmonics = 0.0
            for (multiple, weight) in harmonicWeights where multiple * lag <= lagLimit {
                harmonics += weight * r[multiple * lag]
            }
            // The eighth note below the candidate: hi-hats live there under a real beat.
            let halfLag = Double(lag) / 2
            let lower = Int(halfLag), upper = lower + 1
            if lower >= 1, upper <= lagLimit {
                harmonics += subharmonicWeight * (r[lower] + (r[upper] - r[lower]) * (halfLag - Double(lower)))
            }
            scores[lag] = prior * harmonics
            if scores[lag] > scores[bestLag] { bestLag = lag }
        }
        let confidence = min(1, max(0, r[bestLag]))
        guard confidence >= minimumConfidence else { throw TempoEstimationError.noPeriodicity }

        // Sub-frame period from the parabola through the neighbouring scores.
        var lag = Double(bestLag)
        if bestLag > minLag, bestLag < maxLag {
            let a = scores[bestLag - 1], b = scores[bestLag], c = scores[bestLag + 1]
            let curvature = a - 2 * b + c
            if curvature < 0 { lag += min(0.5, max(-0.5, 0.5 * (a - c) / curvature)) }
        }
        return TempoEstimate(bpm: 60 * fps / lag, confidence: confidence)
    }

    /// Removes the local mean over `meanWindow` frames, keeps positive onsets and
    /// compresses them so a loud kick and a softer snare count nearly alike.
    static func prepared(_ envelope: [Double], meanWindow: Int) -> [Double] {
        let n = envelope.count
        let half = max(1, meanWindow / 2)
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + envelope[i] }
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let lower = max(0, i - half), upper = min(n, i + half + 1)
            let mean = (prefix[upper] - prefix[lower]) / Double(upper - lower)
            let value = envelope[i] - mean
            out[i] = value > 0 ? value.squareRoot() : 0
        }
        return out
    }

    /// Unbiased autocorrelation for lags 0…`limit`.
    static func autocorrelation(_ x: [Double], upTo limit: Int) -> [Double] {
        let n = x.count
        var r = [Double](repeating: 0, count: limit + 1)
        x.withUnsafeBufferPointer { p in
            for lag in 0...limit {
                var sum = 0.0
                var i = 0
                let end = n - lag
                while i < end { sum += p[i] * p[i + lag]; i += 1 }
                r[lag] = end > 0 ? sum / Double(end) : 0
            }
        }
        return r
    }
}
