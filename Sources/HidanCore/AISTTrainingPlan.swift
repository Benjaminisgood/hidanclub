import Foundation

/// An app-curated observation prompt linked to one verified dataset sequence.
/// `style` is the app's navigation category; it is not an AIST difficulty label.
public struct AISTTrainingMove: Equatable, Sendable, Identifiable {
    public let id: String
    public let style: DanceStyle
    public let reference: AISTPracticeReference
    public let observationCue: String

    public init(id: String, style: DanceStyle, reference: AISTPracticeReference, observationCue: String) {
        self.id = id
        self.style = style
        self.reference = reference
        self.observationCue = observationCue
    }
}

public struct AISTTrainingPlanResult: Equatable, Sendable {
    public let plan: TrainingPlan
    public let referencesByBlockID: [String: AISTPracticeReference]

    public init(plan: TrainingPlan, referencesByBlockID: [String: AISTPracticeReference]) {
        self.plan = plan
        self.referencesByBlockID = referencesByBlockID
    }
}

public enum AISTTrainingPlanError: Error, LocalizedError, Equatable {
    case invalidDemonstration(String)
    case duplicateMoveID(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDemonstration(let id): return "动作示范 \(id) 的来源、舞种或观察提示不完整。"
        case .duplicateMoveID(let id): return "动作示范目录含有重复编号：\(id)。"
        }
    }
}

public enum AISTTrainingPlanBuilder {
    /// Every drill has a source reference. Level controls only playback speed;
    /// AIST has no validated teaching-difficulty labels for these movements.
    public static func make(durationMinutes: Int, style: DanceStyle, level: Int = 1,
                            moves: [AISTTrainingMove]) throws -> AISTTrainingPlanResult {
        guard (10...45).contains(durationMinutes) else { throw TrainingPlanError.durationOutOfRange }
        guard (1...2).contains(level) else { throw TrainingPlanError.levelOutOfRange }
        let available = moves.filter { $0.style == style }
        guard !available.isEmpty else { throw TrainingPlanError.noAvailableMoves }
        var seen: Set<String> = []
        for move in available {
            guard seen.insert(move.id).inserted else { throw AISTTrainingPlanError.duplicateMoveID(move.id) }
            try move.reference.validate()
            guard !move.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !move.observationCue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !move.reference.sequence.ignored,
                  genreCodes(for: style).contains(move.reference.sequence.genreCode) else {
                throw AISTTrainingPlanError.invalidDemonstration(move.id)
            }
        }

        let total = durationMinutes * 60
        let warmup = min(300, max(90, total / 6))
        let cooldown = min(180, max(60, total / 10))
        let practiceBudget = total - warmup - cooldown
        let rounds = max(2, practiceBudget / 120)
        let baseRoundSeconds = practiceBudget / rounds
        let extraSeconds = practiceBudget % rounds
        let speed = level == 1 ? 0.5 : 0.75
        // A new plan is a new selection event, even if duration/style are equal.
        let planID = "aist-training-\(UUID().uuidString)"
        var references: [String: AISTPracticeReference] = [:]
        var blocks = [TrainingBlock(
            id: "\(planID)-warmup", title: "让身体进入节奏", kind: .warmup,
            durationSeconds: warmup,
            cue: "先轻松原地走动，再小幅活动肩、踝与髋。保持舒适呼吸，准备观察接下来的真实动作示范。")]
        for round in 0..<rounds {
            let roundSeconds = baseRoundSeconds + (round < extraSeconds ? 1 : 0)
            let rest = min(30, max(20, roundSeconds / 5))
            let move = available[round % available.count]
            let source = move.reference
            let reference = try AISTPracticeReference(
                sequence: source.sequence, name: source.name,
                startFrame: source.startFrame, endFrame: source.endFrame,
                optimized: source.optimized, speed: speed)
            let blockID = "\(planID)-drill-\(round)"
            blocks.append(TrainingBlock(
                id: blockID, title: reference.name, moveID: move.id, kind: .drill,
                durationSeconds: roundSeconds - rest, cue: move.observationCue))
            references[blockID] = reference
            blocks.append(TrainingBlock(
                id: "\(planID)-rest-\(round)", title: "休息与回看", kind: .rest,
                durationSeconds: rest,
                cue: "停止跟跳，放松肩膀，恢复舒适呼吸。可回看刚才的示范，需要时暂停并延长休息。"))
        }
        blocks.append(TrainingBlock(
            id: "\(planID)-cooldown", title: "慢慢回到平静", kind: .cooldown,
            durationSeconds: cooldown,
            cue: "逐渐放慢走动，让呼吸平稳。记录真实用力感；只做舒适范围的小幅活动，不强迫拉伸。"))
        let plan = TrainingPlan(id: planID, title: "\(style.displayName) · \(durationMinutes) 分钟 · AIST++ 动作示范", blocks: blocks)
        return AISTTrainingPlanResult(plan: plan, referencesByBlockID: references)
    }

    private static func genreCodes(for style: DanceStyle) -> Set<String> {
        switch style {
        case .hipHop: return ["gMH", "gLH"]
        case .popping: return ["gPO"]
        case .locking: return ["gLO"]
        case .house: return ["gHO"]
        }
    }
}
