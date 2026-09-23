import Foundation
import HidanCore

/// A music-library entry owns an unmodified local copy of the imported audio file.
/// User-facing names never participate in filesystem path construction.
struct LibraryTrack: Codable, Identifiable, Sendable, Equatable {
    /// Result of the local tempo analysis of the stored copy.
    struct Tempo: Codable, Sendable, Equatable {
        let bpm: Double
        /// Normalized onset autocorrelation at the chosen period, 0…1. Periodicity, not correctness.
        let confidence: Double
        /// Seconds of audio from the start of the file that fed the estimate.
        let analyzedSeconds: Double
        let method: String
        let analyzedAt: Date

        var level: TempoConfidence { TempoConfidence(confidence) }
    }

    let schemaVersion: Int
    let id: UUID
    var name: String
    let originalFilename: String
    let storedFilename: String
    let importedAt: Date
    let duration: Double
    let sampleRate: Double
    let channelCount: Int
    /// Automatic estimate; nil until analysis has run or when it found no beat.
    var tempo: Tempo?
    /// Set by hand when the estimate is missing or off by an octave. Wins over `tempo`.
    var manualBPM: Double?
    /// Why the last analysis produced no tempo; nil while an analysis is still owed.
    var analysisFailure: String?

    /// BPM the motion follows: the manual value first, then the estimate.
    var effectiveBPM: Double? { manualBPM ?? tempo?.bpm }
    var needsAnalysis: Bool { tempo == nil && analysisFailure == nil }

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
              sampleRate.isFinite, sampleRate > 0,
              channelCount >= 1 else { throw MusicLibraryError.invalidMetadata }
        if let tempo {
            guard MotionTempo.isValidTrackBPM(tempo.bpm), tempo.confidence.isFinite, (0...1).contains(tempo.confidence),
                  tempo.analyzedSeconds.isFinite, tempo.analyzedSeconds > 0, !tempo.method.isEmpty else { throw MusicLibraryError.invalidMetadata }
        }
        if let manualBPM { guard MotionTempo.isValidTrackBPM(manualBPM) else { throw MusicLibraryError.invalidMetadata } }
    }
}

/// A saved original beat: the same eight-count pattern, with its own name and tempo.
struct BeatPreset: Codable, Identifiable, Sendable, Equatable {
    let schemaVersion: Int
    let id: UUID
    var name: String
    var bpm: Double
    let createdAt: Date

    func validate() throws {
        guard schemaVersion == 1,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              bpm.isFinite, MotionTempo.beatRange.contains(bpm) else { throw MusicLibraryError.invalidMetadata }
    }
}

enum BeatPresetLibrary {
    /// Stable ids so the first launch and every later launch agree on the starters.
    static let starters: [BeatPreset] = [
        preset("4C6E8A10-2B3D-4F51-9A6E-100000000080", "慢速八拍", 80),
        preset("4C6E8A10-2B3D-4F51-9A6E-100000000096", "练习八拍", 96),
        preset("4C6E8A10-2B3D-4F51-9A6E-100000000110", "俱乐部", 110),
        preset("4C6E8A10-2B3D-4F51-9A6E-100000000128", "快节奏", 128)
    ]

    private static func preset(_ id: String, _ name: String, _ bpm: Double) -> BeatPreset {
        BeatPreset(schemaVersion: 1, id: UUID(uuidString: id)!, name: name, bpm: bpm, createdAt: Date(timeIntervalSince1970: 0))
    }
}

enum MusicLibraryError: LocalizedError, Equatable {
    case invalidMetadata
    case missingAudio
    case corruptedExistingFile
    case unreadableAudio(String)
    case invalidBPM
    case emptyName

    var errorDescription: String? {
        switch self {
        case .invalidMetadata: return "音乐库记录无效，原文件已保留。"
        case .missingAudio: return "音乐原文件缺失或不可读取，记录已保留。"
        case .corruptedExistingFile: return "已有音乐库文件无法完整读取，已保留原文件并停止覆盖保存。"
        case .unreadableAudio(let detail): return "无法读取音频：\(detail)"
        case .invalidBPM: return "BPM 请填写 \(Int(MotionTempo.trackBPMRange.lowerBound)) 到 \(Int(MotionTempo.trackBPMRange.upperBound)) 之间的数字。"
        case .emptyName: return "请给这套节拍起个名字。"
        }
    }
}
