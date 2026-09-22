import Foundation

struct PoseArrangementProposal: Sendable {
    let segments: [CapturedMotionSegment]
    let targetSeconds: Double
    let method: String
    let notice: String
}

enum PoseArrangementError: LocalizedError {
    case invalidTarget, insufficientSkeleton, insufficientTiming
    var errorDescription: String? {
        switch self {
        case .invalidTarget: return "目标片段时长请设为 2 至 30 秒。"
        case .insufficientSkeleton: return "可靠单人骨架覆盖不足 60%，无法依据动作变化分段。请使用全身清晰、少遮挡的单人视频；仍可手动设置 A–B。"
        case .insufficientTiming: return "没有足够的连续身体观测和有效时间间隔，无法依据动作变化分段。原始帧已保留，可手动设置 A–B。"
        }
    }
}

/// A deterministic editor assistant built on Vision's 2D observations. It finds
/// quiet motion boundaries, not named steps, dance quality, or newly generated dance.
/// Every source frame is inspected and retained, including VFR and duplicate PTS.
enum PoseArrangementPlanner {
    static let targetRange = 2.0...30.0
    private static let bodyJoints = ["neck", "root", "leftShoulder", "rightShoulder", "leftElbow", "rightElbow", "leftWrist", "rightWrist", "leftHip", "rightHip", "leftKnee", "rightKnee", "leftAnkle", "rightAnkle"]

    static func propose(for model: CapturedMotion, targetSeconds: Double) throws -> PoseArrangementProposal {
        guard targetSeconds.isFinite, targetRange.contains(targetSeconds) else { throw PoseArrangementError.invalidTarget }
        try model.validate()
        let frames = model.report.frames
        let count = frames.count
        let method = "vision-2d-low-motion-v1;target-seconds=\(targetSeconds);joint-confidence=0.5"
        let reliable = frames.map { frame in
            frame.bodyCount == 1 && !frame.ambiguous && bodyJoints.filter { (frame.joints[$0]?.confidence ?? 0) >= 0.5 }.count >= 6
        }
        var reliableDuration = 0.0
        var totalDuration = 0.0
        for index in frames.indices {
            let duration = model.frameDuration(at: index)
            totalDuration += duration
            if reliable[index] { reliableDuration += duration }
        }
        guard Double(reliable.filter { $0 }.count) / Double(count) >= 0.6,
              totalDuration > 0, reliableDuration / totalDuration >= 0.6 else { throw PoseArrangementError.insufficientSkeleton }
        let warning = reliable.contains(false)
            ? "缺失、低置信或多人帧已保留，未用于判断分界；请检查这些位置。" : ""
        func result(_ segments: [CapturedMotionSegment], _ notice: String) -> PoseArrangementProposal {
            PoseArrangementProposal(segments: segments, targetSeconds: targetSeconds, method: method, notice: notice + warning)
        }
        let full = CapturedMotionSegment(name: "完整片段", startFrame: 0, endFrame: count - 1)
        guard count > 1 else { return result([full], "只有一个原始帧，保留完整片段。") }
        guard totalDuration > targetSeconds * 1.25 else {
            return result([full], "视频较短，保留完整片段；可继续手动调整。")
        }

        // Transition i spans [PTS(i-1), PTS(i)). The dt weighting makes the
        // score a time-domain mean, including every positive VFR interval.
        var speeds = [Double?](repeating: nil, count: count)
        var weightedMotion = [Double](repeating: 0, count: count)
        var validTime = [Double](repeating: 0, count: count)
        for index in 1..<count {
            if index % 512 == 0 { try Task.checkCancellation() }
            weightedMotion[index] = weightedMotion[index - 1]
            validTime[index] = validTime[index - 1]
            let dt = frames[index].timestamp - frames[index - 1].timestamp
            guard dt > 0, reliable[index - 1], reliable[index] else { continue }
            var speedSum = 0.0
            var confidenceSum = 0.0
            var common = 0
            for name in bodyJoints {
                guard let before = frames[index - 1].joints[name], let after = frames[index].joints[name],
                      before.confidence >= 0.5, after.confidence >= 0.5 else { continue }
                let confidence = min(before.confidence, after.confidence)
                speedSum += hypot(after.x - before.x, after.y - before.y) / dt * confidence
                confidenceSum += confidence
                common += 1
            }
            guard common >= 6, confidenceSum > 0 else { continue }
            let speed = speedSum / confidenceSum
            guard speed.isFinite else { continue }
            speeds[index] = speed
            weightedMotion[index] += speed * dt
            validTime[index] += dt
        }
        guard validTime[count - 1] / totalDuration >= 0.5 else { throw PoseArrangementError.insufficientTiming }

        // Score an approximately 0.4 s neighborhood. Two monotone pointers visit
        // every timestamp. Missing observations are never zero-filled/interpolated.
        var scores = [Double?](repeating: nil, count: count)
        var left = 0
        var right = 0
        for index in 1..<count {
            let time = frames[index].timestamp
            while left + 1 < index, frames[left + 1].timestamp < time - 0.2 { left += 1 }
            right = max(right, index)
            while right + 1 < count, frames[right].timestamp < time + 0.2 { right += 1 }
            let span = frames[right].timestamp - frames[left].timestamp
            let observed = validTime[right] - validTime[left]
            guard speeds[index] != nil, span > 0, observed / span >= 0.75 else { continue }
            scores[index] = (weightedMotion[right] - weightedMotion[left]) / observed
        }

        var segments: [CapturedMotionSegment] = []
        var start = 0
        var searchTime = frames[0].timestamp + targetSeconds
        let endTime = frames[count - 1].timestamp + model.frameDuration(at: count - 1)
        var searchIndex = 1
        var skippedWindows = 0
        while searchTime + targetSeconds * 0.5 < endTime {
            try Task.checkCancellation()
            let lower = max(frames[start].timestamp + targetSeconds * 0.5, searchTime - targetSeconds * 0.25)
            let upper = min(searchTime + targetSeconds * 0.25, endTime - targetSeconds * 0.5)
            while searchIndex < count, frames[searchIndex].timestamp < lower { searchIndex += 1 }
            var candidates: [(index: Int, score: Double)] = []
            var candidate = searchIndex
            while candidate < count, frames[candidate].timestamp <= upper {
                if candidate > start, let score = scores[candidate] { candidates.append((candidate, score)) }
                candidate += 1
            }
            // Flat movement (or a completely static pose) supplies no evidence for
            // a boundary. Keep it intact and search the next target neighborhood.
            guard let minimum = candidates.map(\.score).min(), let maximum = candidates.map(\.score).max(),
                  maximum - minimum > 0.0001, minimum <= maximum * 0.85 else {
                skippedWindows += 1; searchTime += targetSeconds; continue
            }
            let quiet = candidates.filter { $0.score <= minimum + (maximum - minimum) * 0.1 }
            let chosen = quiet.min {
                abs(frames[$0.index].timestamp - searchTime) < abs(frames[$1.index].timestamp - searchTime)
            }!.index
            segments.append(CapturedMotionSegment(name: "片段 \(segments.count + 1)", startFrame: start, endFrame: chosen - 1))
            start = chosen
            searchTime = frames[start].timestamp + targetSeconds
        }
        segments.append(CapturedMotionSegment(name: "片段 \(segments.count + 1)", startFrame: start, endFrame: count - 1))
        if segments.count == 1 { return result([full], "目标附近没有明显的低运动分界，保留完整片段。可改变目标时长或手动设置 A–B。") }
        let notice = "已根据身体动作变化生成 \(segments.count) 个连续片段，按原顺序覆盖整段视频。"
            + (skippedWindows > 0 ? "部分位置没有可靠分界，对应片段会更长。" : "")
        return result(segments, notice)
    }
}
