import Foundation

public struct SequenceSlot: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let index: Int
    public let moveID: String
    public let moveName: String
    public let beats: Int
    public let cue: String
    public var beatRange: ClosedRange<Int> { (index * 8 + 1)...(index * 8 + beats) }

    public init(id: String, index: Int, moveID: String, moveName: String, beats: Int = 8, cue: String) {
        self.id = id
        self.index = index
        self.moveID = moveID
        self.moveName = moveName
        self.beats = beats
        self.cue = cue
    }
}

public struct DanceSequence: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let bpm: Double
    public let slots: [SequenceSlot]
    public let warnings: [String]
    public var totalBeats: Int { slots.reduce(0) { $0 + $1.beats } }
    public var durationSeconds: Double { Double(totalBeats) * 60 / bpm }
    public static let generationNotice = "这是按规则组织的 4 × 8 拍动作清单，不是 AI 生成的身体运动，也未验证动作间的运动学衔接。先无音乐慢练，再用舒适速度连接。"
}

public enum SequenceError: Error, LocalizedError, Equatable {
    case invalidBPM
    case noMoves
    case unknownMove(String)
    case noEligibleMoves

    public var errorDescription: String? {
        switch self {
        case .invalidBPM: return "节拍速度需为 40 至 200 BPM 的有限数值。"
        case .noMoves: return "请先选择至少一个基础动作。"
        case .unknownMove(let id): return "动作目录中找不到：\(id)"
        case .noEligibleMoves: return "所选动作中没有适合此站立基础组合的低冲击动作。"
        }
    }
}

public enum SequenceBuilder {
    public static func make(moveIDs: [String], catalog: [DanceMove] = DanceCatalog.moves,
                            bpm: Double, seed: Int = 0) throws -> DanceSequence {
        guard bpm.isFinite && (40...200).contains(bpm) else { throw SequenceError.invalidBPM }
        guard !moveIDs.isEmpty else { throw SequenceError.noMoves }
        var selected: [DanceMove] = []
        for id in moveIDs {
            guard let move = catalog.first(where: { $0.id == id }) else { throw SequenceError.unknownMove(id) }
            if !selected.contains(where: { $0.id == id }) { selected.append(move) }
        }
        let eligible = selected.filter { $0.suitableForStandingPractice && $0.impact == .low && $0.level <= 2 }
        guard !eligible.isEmpty else { throw SequenceError.noEligibleMoves }
        var warnings: [String] = []
        let excluded = selected.filter { move in !eligible.contains(where: { $0.id == move.id }) }
        if !excluded.isEmpty {
            warnings.append("本次组合跳过非低冲击站立动作：\(excluded.map(\.name).joined(separator: "、"))。")
        }
        if Set(eligible.map(\.style)).count > 1 {
            warnings.append("所选动作来自多个风格；这里只做组合草稿，不代表这些舞种共享同一律动。")
        }
        let outsideTempo = eligible.filter { bpm < Double($0.bpmMin) || bpm > Double($0.bpmMax) }
        if !outsideTempo.isEmpty {
            warnings.append("当前 BPM 超出以下动作的建议练习起点：\(outsideTempo.map(\.name).joined(separator: "、"))。可降低速度或按半速练习。")
        }
        let selectedIDs = Set(eligible.map(\.id))
        let missingPrerequisiteIDs = Set(eligible.flatMap(\.prerequisites)).subtracting(selectedIDs).sorted()
        if !missingPrerequisiteIDs.isEmpty {
            let names = missingPrerequisiteIDs.map { id in catalog.first(where: { $0.id == id })?.name ?? id }
            warnings.append("建议先熟悉：\(names.joined(separator: "、"))。这些先修动作未包含在本次选择中。")
        }
        if eligible.contains(where: { !$0.prerequisites.isEmpty }) {
            warnings.append("选择先修动作不等于已经掌握；应用尚未评估你的动作熟练度。")
        }
        if eligible.count > 4 {
            warnings.append("本次仅有四个八拍槽位；再次换一个组合可轮换更多所选动作。")
        }
        var pool = eligible
        var rng = StableGenerator(seed: seed)
        if pool.count > 1 {
            for index in stride(from: pool.count - 1, through: 1, by: -1) {
                pool.swapAt(index, rng.nextIndex(upperBound: index + 1))
            }
        }
        let sequenceID = "sequence-\(seed)-\(bpm)-\(eligible.map(\.id).joined(separator: "+"))"
        let slots = (0..<4).map { index in
            let move = pool[index % pool.count]
            return SequenceSlot(id: "\(sequenceID)-\(index)", index: index, moveID: move.id,
                                moveName: move.name, cue: "保持八拍，结束时回到稳定站姿。\(move.cues.first ?? "")")
        }
        return DanceSequence(id: sequenceID, bpm: bpm, slots: slots, warnings: warnings)
    }
}
