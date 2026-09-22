import Foundation

struct CapturedMotionSegment: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let startFrame: Int
    let endFrame: Int
    var repeats: Int

    init(id: UUID = UUID(), name: String, startFrame: Int, endFrame: Int, repeats: Int = 1) {
        self.id = id; self.name = name; self.startFrame = startFrame; self.endFrame = endFrame; self.repeats = repeats
    }
}

/// Offline 2D model with the complete original Vision observations and PTS.
/// Segments reference continuous ranges; they never replace or reduce source frames.
struct CapturedMotion: Codable, Identifiable, Sendable {
    let schemaVersion: Int
    let id: UUID
    var name: String
    let createdAt: Date
    let imageAspectRatio: Double
    let report: PoseReport
    var segments: [CapturedMotionSegment]
    var arrangementMethod: String? = nil
    var sourceModelID: UUID? = nil

    /// A library entry is an independent snapshot; the complete source observations stay intact.
    func libraryCopy(segments: [CapturedMotionSegment]? = nil) -> CapturedMotion {
        CapturedMotion(schemaVersion: schemaVersion, id: UUID(), name: name, createdAt: Date(),
                       imageAspectRatio: imageAspectRatio, report: report, segments: segments ?? self.segments,
                       arrangementMethod: arrangementMethod, sourceModelID: id)
    }

    var hasContinuousArrangement: Bool {
        guard segments.first?.startFrame == 0, segments.last?.endFrame == frameCount - 1 else { return false }
        return zip(segments, segments.dropFirst()).allSatisfy { $0.endFrame + 1 == $1.startFrame }
    }

    var frameCount: Int { report.frames.count }
    var usableFrameCount: Int { report.frames.filter(Self.isUsable).count }
    var usableCoverage: Double { Double(usableFrameCount) / Double(max(1, frameCount)) }
    var hasPlayableMotion: Bool { !segments.isEmpty && segments.allSatisfy { usableFrames(in: $0) > 0 } }
    func usableFrames(in segment: CapturedMotionSegment) -> Int {
        guard segment.startFrame >= 0, segment.endFrame >= segment.startFrame, segment.endFrame < frameCount else { return 0 }
        return report.frames[segment.startFrame...segment.endFrame].filter(Self.isUsable).count
    }
    func coverage(in segment: CapturedMotionSegment) -> Double { Double(usableFrames(in: segment)) / Double(segment.endFrame - segment.startFrame + 1) }
    var qualityNotice: String {
        if usableFrameCount == 0 { return "未捕捉到可用身体骨架。原始帧已保留，请换用全身清晰、单人且少遮挡的视频。" }
        if !hasPlayableMotion { return "编排中有片段完全没有可用身体骨架。请重新选择范围；这些源帧仍完整保留。" }
        if usableCoverage < 0.5 { return "可用骨架覆盖较低，缺失帧仍完整保留。请先逐段检查，再决定是否跟练。" }
        return "已生成二维动作模型。先检查遮挡和误检；此模型不包含真实深度、舞步命名或动作评分。"
    }

    static func isUsable(_ frame: PoseFrame) -> Bool {
        let body = Set(["neck", "root", "leftShoulder", "rightShoulder", "leftElbow", "rightElbow", "leftWrist", "rightWrist", "leftHip", "rightHip", "leftKnee", "rightKnee", "leftAnkle", "rightAnkle"])
        return frame.bodyCount == 1 && !frame.ambiguous && frame.joints.filter { body.contains($0.key) && $0.value.confidence >= 0.2 }.count >= 6
    }

    func frameDuration(at index: Int) -> Double {
        guard report.frames.indices.contains(index) else { return 0 }
        if index + 1 < frameCount { return max(0, report.frames[index + 1].timestamp - report.frames[index].timestamp) }
        let remaining = report.duration - report.frames[index].timestamp
        if remaining > 0 { return remaining }
        if index > 0 { return max(0, report.frames[index].timestamp - report.frames[index - 1].timestamp) }
        return report.duration
    }

    func duration(of segment: CapturedMotionSegment) -> Double {
        report.frames[segment.endFrame].timestamp - report.frames[segment.startFrame].timestamp + frameDuration(at: segment.endFrame)
    }

    func validate() throws {
        guard schemaVersion == 1, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              imageAspectRatio.isFinite, imageAspectRatio > 0,
              report.duration.isFinite, report.duration > 0,
              frameCount > 0, report.decodedFrameCount == frameCount,
              report.detectedFrameCount == report.frames.filter(\.hasDetectedBody).count,
              report.coverage.isFinite,
              abs(report.coverage - Double(report.detectedFrameCount) / Double(frameCount)) < 0.0000001 else { throw CapturedMotionError.invalidModel }
        var previous = -Double.infinity
        for frame in report.frames {
            guard frame.timestamp.isFinite, frame.timestamp >= previous, frame.timestampTimescale > 0,
                  abs(Double(frame.timestampValue) / Double(frame.timestampTimescale) - frame.timestamp) < 0.0000001,
                  frame.bodyCount >= 0, frame.ambiguous == (frame.bodyCount > 1),
                  frame.joints.values.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.confidence.isFinite && (0...1).contains($0.confidence) }) else { throw CapturedMotionError.invalidModel }
            previous = frame.timestamp
        }
        guard !segments.isEmpty, Set(segments.map(\.id)).count == segments.count,
              segments.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.startFrame >= 0 && $0.endFrame >= $0.startFrame && $0.endFrame < frameCount && (1...20).contains($0.repeats) }) else { throw CapturedMotionError.invalidRange }
    }
}

enum CapturedMotionError: LocalizedError {
    case invalidModel, invalidRange, noSelection, corruptedExistingFile, notPlayable, invalidBoundary
    var errorDescription: String? {
        switch self {
        case .invalidModel: return "动作模型不完整或原始时间戳无效，原文件已保留。"
        case .invalidRange: return "请选择有效的连续 A–B 帧范围，片段重复次数为 1 至 20。"
        case .noSelection: return "请先完成视频捕捉或选择已保存的模型。"
        case .corruptedExistingFile: return "已有模型文件无法完整读取，已保留原文件并停止覆盖保存。"
        case .notPlayable: return "没有可用于跟练的身体骨架，请先检查捕捉覆盖情况。"
        case .invalidBoundary: return "分界必须位于相邻两个片段之间，且每段至少保留一帧。"
        }
    }
}
