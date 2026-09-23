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

enum MusicLibraryError: LocalizedError, Equatable {
    case invalidMetadata
    case missingAudio
    case corruptedExistingFile
    case unreadableAudio(String)
    case invalidBPM

    var errorDescription: String? {
        switch self {
        case .invalidMetadata: return "音乐库记录无效，原文件已保留。"
        case .missingAudio: return "音乐原文件缺失或不可读取，记录已保留。"
        case .corruptedExistingFile: return "已有音乐库文件无法完整读取，已保留原文件并停止覆盖保存。"
        case .unreadableAudio(let detail): return "无法读取音频：\(detail)"
        case .invalidBPM: return "BPM 请填写 \(Int(MotionTempo.trackBPMRange.lowerBound)) 到 \(Int(MotionTempo.trackBPMRange.upperBound)) 之间的数字。"
        }
    }
}
