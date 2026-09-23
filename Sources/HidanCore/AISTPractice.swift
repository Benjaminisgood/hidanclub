import Foundation

public enum AISTPracticeError: Error, LocalizedError, Equatable {
    case invalidSequence
    case invalidRange
    case invalidSpeed
    case missingName
    case invalidRounds
    case trainingInProgress

    public var errorDescription: String? {
        switch self {
        case .invalidSequence: return "动作序列的帧数或帧率无效。"
        case .invalidRange: return "请选择动作序列中的连续帧范围，起始帧不能晚于结束帧。"
        case .invalidSpeed: return "跟练速度请选择 0.25 至 2 倍速。"
        case .missingName: return "请为这段跟练动作填写名称。"
        case .invalidRounds: return "跟练组数请选择 2、4 或 6 组。"
        case .trainingInProgress: return "当前练习尚未结束。请先结束练习，再安排新的动作片段。"
        }
    }
}

/// A contiguous, inclusive source-frame range. Playback speed changes time only;
/// the source arrays and every frame in the range remain unchanged.
public struct AISTPracticeReference: Codable, Equatable, Sendable {
    public let sequence: AISTSequence
    public let name: String
    public let startFrame: Int
    public let endFrame: Int
    public let optimized: Bool
    public let speed: Double

    public var frameCount: Int { endFrame - startFrame + 1 }
    public var sourceDuration: Double { Double(frameCount) / sequence.fps }
    public var duration: Double { sourceDuration / speed }
    public var frameRange: ClosedRange<Int> { startFrame...endFrame }
    public var sourceLabel: String { "\(sequence.id) · 帧 \(startFrame + 1)–\(endFrame + 1)" }
    public var speedLabel: String { String(format: "%.2g×", speed) }
    public var layerLabel: String { optimized ? "官方优化骨架" : "原始重建骨架" }

    public init(sequence: AISTSequence, name: String, startFrame: Int, endFrame: Int,
                optimized: Bool, speed: Double) throws {
        self.sequence = sequence
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.optimized = optimized
        self.speed = speed
        try validate()
    }

    public func validate() throws {
        guard sequence.frameCount > 0, sequence.fps.isFinite, sequence.fps > 0 else {
            throw AISTPracticeError.invalidSequence
        }
        guard startFrame >= 0, endFrame >= startFrame, endFrame < sequence.frameCount else {
            throw AISTPracticeError.invalidRange
        }
        guard speed.isFinite, MotionTempo.speedRange.contains(speed) else { throw AISTPracticeError.invalidSpeed }
        guard !name.isEmpty else { throw AISTPracticeError.missingName }
        guard duration.isFinite else { throw AISTPracticeError.invalidSequence }
    }

    private enum CodingKeys: String, CodingKey {
        case sequence, name, startFrame, endFrame, optimized, speed
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(sequence: values.decode(AISTSequence.self, forKey: .sequence),
                      name: values.decode(String.self, forKey: .name),
                      startFrame: values.decode(Int.self, forKey: .startFrame),
                      endFrame: values.decode(Int.self, forKey: .endFrame),
                      optimized: values.decode(Bool.self, forKey: .optimized),
                      speed: values.decode(Double.self, forKey: .speed))
    }
}

public enum AISTPracticePlanBuilder {
    public static func make(reference: AISTPracticeReference, rounds: Int) throws -> TrainingPlan {
        try reference.validate()
        guard [2, 4, 6].contains(rounds) else { throw AISTPracticeError.invalidRounds }
        let id = "aist-\(reference.sequence.id)-\(reference.startFrame)-\(reference.endFrame)-\(reference.optimized)-\(reference.speed)-\(rounds)"
        let title = "\(reference.sequence.genreName) · \(reference.name) · \(rounds) 组 · \(reference.sourceLabel) · \(reference.speedLabel)"
        var blocks = [TrainingBlock(
            id: "\(id)-warmup", title: "先热身，找到舒适幅度", kind: .warmup, durationSeconds: 60,
            cue: "轻松原地走动，小幅活动肩、髋和踝，保持呼吸。随后打开所选 3D 片段，先观察重心与方向。")]
        for round in 1...rounds {
            blocks.append(TrainingBlock(
                id: "\(id)-practice-\(round)", title: "\(reference.name) · 第 \(round)/\(rounds) 组",
                kind: .drill, durationSeconds: 60,
                cue: "打开 3D 片段，以 \(reference.speedLabel) 查看并循环跟练：\(reference.sourceLabel)。先看清再模仿，按自己的节奏缩小幅度；片段与计时独立控制。"))
            if round < rounds {
                blocks.append(TrainingBlock(
                    id: "\(id)-rest-\(round)", title: "放松与回看", kind: .rest, durationSeconds: 20,
                    cue: "停止跟跳，放松肩膀并恢复舒适呼吸。可暂停片段，回看刚才不清楚的转向；需要时延长休息。"))
            }
        }
        blocks.append(TrainingBlock(
            id: "\(id)-cooldown", title: "慢慢回到平静", kind: .cooldown, durationSeconds: 30,
            cue: "暂停动作片段，逐渐放慢走动，让呼吸平稳。记录实际用力感；不强迫拉伸或追加高难度动作。"))
        return TrainingPlan(id: id, title: title, blocks: blocks)
    }
}
