import Foundation

public enum TrainingPlanError: Error, LocalizedError, Equatable {
    case durationOutOfRange
    case levelOutOfRange
    case noAvailableMoves

    public var errorDescription: String? {
        switch self {
        case .durationOutOfRange: return "练习时长请选择 10 至 45 分钟。"
        case .levelOutOfRange: return "练习等级请选择 1 或 2。"
        case .noAvailableMoves: return "当前风格和等级还没有可用动作。"
        }
    }
}

public enum PlanBuilder {
    public static let planningNotice = "训练时间由应用规则分配，用于安排练习与休息，并非个体化运动处方。可随时暂停、缩小幅度或结束。"

    public static func make(durationMinutes: Int, style: DanceStyle,
                            level: Int = 1, seed: Int = 0) throws -> TrainingPlan {
        guard (10...45).contains(durationMinutes) else { throw TrainingPlanError.durationOutOfRange }
        guard (1...2).contains(level) else { throw TrainingPlanError.levelOutOfRange }
        let available = DanceCatalog.moves(for: style, level: level)
        guard !available.isEmpty else { throw TrainingPlanError.noAvailableMoves }
        let total = durationMinutes * 60
        let warmup = min(300, max(90, total / 6))
        let cooldown = min(180, max(60, total / 10))
        let practiceBudget = total - warmup - cooldown
        let rounds = max(2, practiceBudget / 120)
        let baseRoundSeconds = practiceBudget / rounds
        let extraSeconds = practiceBudget % rounds
        let planID = "plan-\(style.rawValue)-\(durationMinutes)-\(level)-\(seed)"
        var blocks: [TrainingBlock] = [
            TrainingBlock(id: "\(planID)-warmup", title: "让身体进入节奏", kind: .warmup,
                          durationSeconds: warmup,
                          cue: "先轻松原地走动，再小幅活动肩、踝与髋。逐步进入舒适节奏；保持呼吸，不强拉关节。")
        ]
        // A seeded cyclic order varies later rounds while a prerequisite-aware first pass
        // ensures foundational moves occur before the moves that depend on them.
        var rng = StableGenerator(seed: seed)
        let offset = rng.nextIndex(upperBound: available.count)
        let rotated = Array(available[offset...] + available[..<offset])
        let ordered = prerequisiteOrder(rotated, available: available)
        for round in 0..<rounds {
            let roundSeconds = baseRoundSeconds + (round < extraSeconds ? 1 : 0)
            let rest = min(30, max(20, roundSeconds / 5))
            let move = ordered[round % ordered.count]
            let isFreestyle = round == rounds - 1 && rounds >= 4
            blocks.append(TrainingBlock(id: "\(planID)-practice-\(round)",
                                        title: isFreestyle ? "用熟悉动作自由连接" : move.name,
                                        moveID: isFreestyle ? nil : move.id,
                                        kind: isFreestyle ? .freestyle : .drill,
                                        durationSeconds: roundSeconds - rest,
                                        cue: isFreestyle
                                            ? "选择刚练过且已熟悉的动作，每个动作保持八拍。需要时回到原地律动；不加入新的高难度动作。"
                                            : (move.cues.first ?? move.summary)))
            blocks.append(TrainingBlock(id: "\(planID)-rest-\(round)", title: "休息与调整", kind: .rest,
                                        durationSeconds: rest,
                                        cue: "放松肩膀，按需要补水。若呼吸或身体尚未恢复舒适，可暂停并延长休息。"))
        }
        blocks.append(TrainingBlock(id: "\(planID)-cooldown", title: "慢慢回到平静", kind: .cooldown,
                                    durationSeconds: cooldown,
                                    cue: "逐渐减慢走动与律动，让呼吸平稳。只做舒适范围的小幅活动，不强迫拉伸。"))
        return TrainingPlan(id: planID, title: "\(style.displayName) · \(durationMinutes) 分钟", blocks: blocks)
    }

    private static func prerequisiteOrder(_ proposed: [DanceMove], available: [DanceMove]) -> [DanceMove] {
        var result: [DanceMove] = []
        var visited: Set<String> = []
        func append(_ move: DanceMove) {
            guard !visited.contains(move.id) else { return }
            visited.insert(move.id)
            for prerequisite in move.prerequisites {
                if let prior = available.first(where: { $0.id == prerequisite }) { append(prior) }
            }
            result.append(move)
        }
        proposed.forEach(append)
        return result
    }
}

struct StableGenerator {
    private var state: UInt64
    init(seed: Int) { state = UInt64(truncatingIfNeeded: seed) &+ 0x9E3779B97F4A7C15 }
    mutating func nextIndex(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 32) % UInt64(upperBound))
    }
}
