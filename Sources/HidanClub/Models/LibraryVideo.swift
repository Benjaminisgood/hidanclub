import Foundation

/// A library entry owns an unmodified local copy of the source video.
/// User-facing names never participate in filesystem path construction.
struct LibraryVideo: Codable, Identifiable, Sendable {
    enum Source: String, Codable, Sendable {
        case imported
        case trainingRecording

        var title: String { self == .trainingRecording ? "训练录制" : "导入视频" }
    }

    let schemaVersion: Int
    let id: UUID
    var name: String
    let originalFilename: String
    let storedFilename: String
    let source: Source
    /// Only training recordings use this for safe retry/recovery deduplication.
    let recordingSourcePath: String?
    let importedAt: Date
    let duration: Double
    let displayWidth: Double
    let displayHeight: Double
    /// EXIF orientation, validated against the original track transform.
    let orientation: UInt32
    var modelID: UUID?

    var aspectRatio: Double { displayWidth / displayHeight }

    func validate() throws {
        let filename = URL(fileURLWithPath: storedFilename)
        let suffix = filename.pathExtension
        guard schemaVersion == 1,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !originalFilename.isEmpty,
              storedFilename == filename.lastPathComponent,
              filename.deletingPathExtension().lastPathComponent.lowercased() == id.uuidString.lowercased(),
              !suffix.isEmpty, suffix.count <= 16,
              suffix.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII }),
              duration.isFinite, duration > 0,
              displayWidth.isFinite, displayWidth > 0,
              displayHeight.isFinite, displayHeight > 0,
              aspectRatio.isFinite, aspectRatio > 0,
              (1...8).contains(orientation) else { throw VideoLibraryError.invalidMetadata }
    }
}

enum VideoLibraryError: LocalizedError {
    case invalidMetadata
    case missingVideo
    case corruptedExistingFile

    var errorDescription: String? {
        switch self {
        case .invalidMetadata: return "视频库记录无效，原文件已保留。"
        case .missingVideo: return "视频原文件缺失或不可读取，记录已保留。"
        case .corruptedExistingFile: return "已有视频库文件无法完整读取，已保留原文件并停止覆盖保存。"
        }
    }
}
