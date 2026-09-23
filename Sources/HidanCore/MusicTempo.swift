import Foundation

/// Which clock sets the tempo the reference motion follows.
public enum TempoMode: String, Codable, Sendable {
    /// The built-in eight-count beat; its BPM slider is the tempo control.
    case beat
    /// An imported track; its estimated or hand-entered BPM is the tempo and the
    /// motion follows it in multiples.
    case music
}

/// Motion beats per music beat while a track plays. Half time and double time are
/// how dancers fit a step to a track without changing the music itself.
public enum BeatMultiplier: Double, CaseIterable, Codable, Sendable, Identifiable {
    case quarter = 0.25
    case half = 0.5
    case single = 1
    case double = 2

    public var id: Double { rawValue }

    public var label: String {
        switch self {
        case .quarter: return "¼×"
        case .half: return "½×"
        case .single: return "1×"
        case .double: return "2×"
        }
    }

    /// How the motion count relates to the music count, in the bar's words.
    public var summary: String {
        switch self {
        case .quarter: return "四拍一动"
        case .half: return "两拍一动"
        case .single: return "一拍一动"
        case .double: return "一拍两动"
        }
    }
}

/// Tempo arithmetic shared by the beat, the music library and every motion player.
public enum MotionTempo {
    /// Playback speeds the motion players accept. 2× lets a reference clip recorded
    /// slower than a track still land one motion beat on each music beat.
    public static let speedRange: ClosedRange<Double> = 0.25...2
    public static let speedChoices: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2]
    /// BPM range of the built-in beat.
    public static let beatRange: ClosedRange<Double> = 40...180
    /// BPM values accepted for a track, whether estimated or typed in.
    public static let trackBPMRange: ClosedRange<Double> = 30...300

    public static func clampSpeed(_ speed: Double) -> Double {
        guard speed.isFinite else { return 1 }
        return min(max(speed, speedRange.lowerBound), speedRange.upperBound)
    }

    public static func clampBeat(_ bpm: Double) -> Double {
        guard bpm.isFinite else { return 90 }
        return min(max(bpm, beatRange.lowerBound), beatRange.upperBound)
    }

    public static func isValidTrackBPM(_ bpm: Double) -> Bool {
        bpm.isFinite && trackBPMRange.contains(bpm)
    }

    /// Playback speed that puts a motion recorded at `motionBPM` onto `targetBPM`,
    /// clamped to `speedRange`. `nil` when either tempo is unusable.
    public static func speed(motionBPM: Double, targetBPM: Double) -> Double? {
        guard motionBPM.isFinite, targetBPM.isFinite, motionBPM > 0, targetBPM > 0 else { return nil }
        return clampSpeed(targetBPM / motionBPM)
    }

    /// True when `speed(motionBPM:targetBPM:)` lands exactly on the target without clamping.
    public static func canReach(motionBPM: Double, targetBPM: Double) -> Bool {
        guard motionBPM.isFinite, targetBPM.isFinite, motionBPM > 0, targetBPM > 0 else { return false }
        return speedRange.contains(targetBPM / motionBPM)
    }

    /// Tempo the motion follows while a track plays: track BPM × playback rate × multiplier.
    public static func musicTarget(trackBPM: Double, rate: Double, multiplier: BeatMultiplier) -> Double? {
        guard trackBPM.isFinite, rate.isFinite, trackBPM > 0, rate > 0 else { return nil }
        return trackBPM * rate * multiplier.rawValue
    }
}
