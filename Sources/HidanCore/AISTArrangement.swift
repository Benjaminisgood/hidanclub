import Foundation

/// Ordered, complete references to source ranges; no pose interpolation or beat
/// alignment is implied by saving an arrangement.
public struct AISTArrangement: Codable, Equatable, Identifiable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public var updatedAt: Date
    public var references: [AISTPracticeReference]

    public var sourceDuration: Double { references.reduce(0) { $0 + $1.sourceDuration } }
    public var duration: Double { references.reduce(0) { $0 + $1.duration } }

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), updatedAt: Date = Date(), references: [AISTPracticeReference]) throws {
        schemaVersion = 1; self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.references = references
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == 1, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !references.isEmpty, createdAt.timeIntervalSinceReferenceDate.isFinite,
              updatedAt.timeIntervalSinceReferenceDate.isFinite else { throw AISTArrangementError.invalidArrangement }
        for reference in references { try reference.validate() }
        guard sourceDuration.isFinite, duration.isFinite else { throw AISTArrangementError.invalidArrangement }
    }
}

public enum AISTArrangementError: LocalizedError {
    case invalidArrangement, invalidIndex, corruptedFile
    public var errorDescription: String? {
        switch self {
        case .invalidArrangement: return "请为编排命名，并至少加入一个有效动作片段。"
        case .invalidIndex: return "找不到要调整的编排片段。"
        case .corruptedFile: return "已有编排文件无法完整读取，原文件已保留，已停止覆盖保存。"
        }
    }
}
