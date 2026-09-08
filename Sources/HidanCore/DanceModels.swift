import Foundation

public enum DanceStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case hipHop, popping, locking, house

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .hipHop: return "Hip-Hop"
        case .popping: return "Popping · 震感舞"
        case .locking: return "Locking · 锁舞"
        case .house: return "House"
        }
    }
    public var subtitle: String {
        switch self {
        case .hipHop: return "律动与基础步伐"
        case .popping: return "身体分离与控制"
        case .locking: return "停顿与指向"
        case .house: return "躯干律动与轻盈步伐"
        }
    }
}

public enum DanceImpact: String, Codable, Sendable {
    case low, moderate

    public var displayName: String { self == .low ? "低冲击" : "中等冲击" }
}

public struct DanceMove: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let englishName: String
    public let style: DanceStyle
    public let level: Int
    public let summary: String
    public let cues: [String]
    public let commonMistakes: [String]
    public let bpmMin: Int
    public let bpmMax: Int
    public let prerequisites: [String]
    public let durationSeconds: Int
    public let impact: DanceImpact
    public let learningSourceURL: URL?
    public let suitableForStandingPractice: Bool

    public var bpmRange: ClosedRange<Int> { bpmMin...bpmMax }
    public var levelName: String { level == 1 ? "入门" : "基础进阶" }
    public var bpmLabel: String { "\(bpmMin)–\(bpmMax) BPM" }

    public init(id: String, name: String, englishName: String, style: DanceStyle,
                level: Int = 1, summary: String, cues: [String], commonMistakes: [String],
                bpmMin: Int, bpmMax: Int, prerequisites: [String] = [], durationSeconds: Int = 90,
                impact: DanceImpact = .low, learningSourceURL: URL? = nil,
                suitableForStandingPractice: Bool = true) {
        self.id = id
        self.name = name
        self.englishName = englishName
        self.style = style
        self.level = max(1, level)
        self.summary = summary
        self.cues = cues
        self.commonMistakes = commonMistakes
        self.bpmMin = max(1, min(bpmMin, bpmMax))
        self.bpmMax = max(self.bpmMin, max(bpmMin, bpmMax))
        self.prerequisites = prerequisites
        self.durationSeconds = max(1, durationSeconds)
        self.impact = impact
        self.learningSourceURL = learningSourceURL
        self.suitableForStandingPractice = suitableForStandingPractice
    }
}

public enum TrainingBlockKind: String, Codable, Sendable {
    case warmup, drill, rest, freestyle, cooldown

    public var displayName: String {
        switch self {
        case .warmup: return "热身"
        case .drill: return "动作练习"
        case .rest: return "休息"
        case .freestyle: return "自由组合"
        case .cooldown: return "放松"
        }
    }
}

public struct TrainingBlock: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let moveID: String?
    public let kind: TrainingBlockKind
    public let durationSeconds: Int
    public let cue: String

    public init(id: String = UUID().uuidString, title: String, moveID: String? = nil,
                kind: TrainingBlockKind, durationSeconds: Int, cue: String) {
        self.id = id
        self.title = title
        self.moveID = moveID
        self.kind = kind
        self.durationSeconds = max(1, durationSeconds)
        self.cue = cue
    }
}

public struct TrainingPlan: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let blocks: [TrainingBlock]
    public var totalSeconds: Int { blocks.reduce(0) { $0 + $1.durationSeconds } }

    public init(id: String = UUID().uuidString, title: String, blocks: [TrainingBlock]) {
        self.id = id
        self.title = title
        self.blocks = blocks
    }
}

public struct FinishedSession: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let date: Date
    public let planTitle: String
    public let activeSeconds: TimeInterval
    public let completedBlocks: Int
    public let totalBlocks: Int
    public let perceivedEffort: Int?

    public init(id: UUID = UUID(), date: Date = Date(), planTitle: String,
                activeSeconds: TimeInterval, completedBlocks: Int, totalBlocks: Int,
                perceivedEffort: Int? = nil) {
        self.id = id
        self.date = date
        self.planTitle = planTitle
        self.activeSeconds = max(0, activeSeconds)
        self.totalBlocks = max(0, totalBlocks)
        self.completedBlocks = min(max(0, completedBlocks), self.totalBlocks)
        self.perceivedEffort = perceivedEffort.flatMap { (1...10).contains($0) ? $0 : nil }
    }
}
