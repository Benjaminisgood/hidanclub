import Foundation
import SwiftUI

/// Only this object publishes frame updates. Parent library/editor views observe
/// CapturedMotionStore, which deliberately does not forward these notifications.
@MainActor final class CapturedMotionPlayback: ObservableObject {
    @Published private(set) var frameIndex = 0
    @Published private(set) var segmentIndex = 0
    @Published private(set) var repetitionIndex = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isCompleted = false
    @Published private(set) var hasSkippedSegments = false
    @Published private(set) var elapsed: Double = 0
    @Published var loop = false
    @Published var mirrored = false
    @Published var speed: Double = 1 {
        didSet {
            let valid = speed.isFinite ? min(1, max(0.25, speed)) : 1
            if speed != valid { speed = valid }
            let previousSpeed = max(0.25, oldValue.isFinite ? oldValue : 1)
            if isPlaying {
                let remaining = max(0, fireDate?.timeIntervalSinceNow ?? 0) * previousSpeed / speed
                schedule(after: remaining)
            } else if let remaining = pausedRemaining {
                pausedRemaining = remaining * previousSpeed / speed
            }
            updateElapsed()
        }
    }
    private(set) var model: CapturedMotion?
    private var playable = false
    private var timer: Timer?
    private var fireDate: Date?
    private var pausedRemaining: Double?
    private var sourceElapsed: Double = 0
    var currentFrame: PoseFrame? { guard let model, model.report.frames.indices.contains(frameIndex) else { return nil }; return model.report.frames[frameIndex] }
    var imageAspectRatio: Double { model?.imageAspectRatio ?? 1 }
    var hasPlayableMotion: Bool { playable }
    var frameCount: Int { model?.frameCount ?? 0 }
    var planDuration: Double { guard let model else { return 0 }; return model.segments.reduce(0) { $0 + model.duration(of: $1) * Double($1.repeats) } / speed }
    var currentSegment: CapturedMotionSegment? { guard let model, model.segments.indices.contains(segmentIndex) else { return nil }; return model.segments[segmentIndex] }

    func prepare(_ model: CapturedMotion) {
        pause(); self.model = model; playable = model.hasPlayableMotion
        segmentIndex = 0; repetitionIndex = 0; frameIndex = model.segments.first?.startFrame ?? 0
        sourceElapsed = 0; elapsed = 0; isCompleted = false; hasSkippedSegments = false; pausedRemaining = nil
        objectWillChange.send()
    }
    func start() {
        guard hasPlayableMotion, let model else { return }
        if isCompleted { prepare(model) }
        guard let segment = currentSegment else { return }
        if frameIndex < segment.startFrame || frameIndex > segment.endFrame { frameIndex = currentSegment?.startFrame ?? 0; recalculateSourceElapsed() }
        guard !isPlaying else { return }
        isPlaying = true
        schedule(after: pausedRemaining ?? model.frameDuration(at: frameIndex) / speed)
        pausedRemaining = nil
    }
    func play() { start() }
    func toggle() { isPlaying ? pause() : start() }
    func pause() {
        if isPlaying { pausedRemaining = max(0, fireDate?.timeIntervalSinceNow ?? 0) }
        timer?.invalidate(); timer = nil; fireDate = nil; isPlaying = false
    }
    func stop() {
        pause(); segmentIndex = 0; repetitionIndex = 0; frameIndex = model?.segments.first?.startFrame ?? 0
        sourceElapsed = 0; elapsed = 0; pausedRemaining = nil; isCompleted = false; hasSkippedSegments = false
    }
    func seek(_ frame: Int) {
        pause(); frameIndex = min(max(0, frame), max(0, frameCount - 1)); pausedRemaining = nil; isCompleted = false
        if let index = model?.segments.firstIndex(where: { ($0.startFrame...$0.endFrame).contains(frameIndex) }) { segmentIndex = index; repetitionIndex = 0 }
        recalculateSourceElapsed()
    }
    func step(_ delta: Int) {
        let (value, overflow) = frameIndex.addingReportingOverflow(delta)
        seek(overflow ? (delta > 0 ? Int.max : 0) : value)
    }
    func nextSegment() {
        guard model != nil else { return }
        hasSkippedSegments = true
        let wasPlaying = isPlaying; pause(); pausedRemaining = nil
        guard let model else { return }
        if segmentIndex + 1 < model.segments.count { segmentIndex += 1; repetitionIndex = 0; frameIndex = model.segments[segmentIndex].startFrame; recalculateSourceElapsed(); if wasPlaying { start() } }
        else if loop { stop(); if wasPlaying { start() } }
        else { finish() }
    }
    func advance() { nextSegment() }
    private func schedule(after seconds: Double) {
        timer?.invalidate()
        let delay = max(0.000001, seconds)
        fireDate = Date().addingTimeInterval(delay)
        let next = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceOneFrame() }
        }
        timer = next; RunLoop.main.add(next, forMode: .common)
    }
    /// One callback consumes exactly one original frame. Delays never trigger a
    /// wall-time catch-up skip. Missing and duplicate-PTS frames stay in order.
    func advanceOneFrame() {
        guard isPlaying, let model, let segment = currentSegment else { return }
        sourceElapsed += model.frameDuration(at: frameIndex)
        if frameIndex < segment.endFrame { frameIndex += 1 }
        else if repetitionIndex + 1 < segment.repeats { repetitionIndex += 1; frameIndex = segment.startFrame }
        else if segmentIndex + 1 < model.segments.count { segmentIndex += 1; repetitionIndex = 0; frameIndex = model.segments[segmentIndex].startFrame }
        else if loop { segmentIndex = 0; repetitionIndex = 0; frameIndex = model.segments[0].startFrame; sourceElapsed = 0 }
        else { finish(); return }
        updateElapsed(); schedule(after: model.frameDuration(at: frameIndex) / speed)
    }
    private func finish() { pause(); pausedRemaining = nil; isCompleted = true; sourceElapsed = planDuration * speed; updateElapsed() }
    private func updateElapsed() { elapsed = min(planDuration, max(0, sourceElapsed / speed)) }
    private func recalculateSourceElapsed() {
        guard let model, let segment = currentSegment else { sourceElapsed = 0; updateElapsed(); return }
        sourceElapsed = model.segments.prefix(segmentIndex).reduce(0) { $0 + model.duration(of: $1) * Double($1.repeats) }
        sourceElapsed += model.duration(of: segment) * Double(repetitionIndex)
        sourceElapsed += max(0, model.report.frames[frameIndex].timestamp - model.report.frames[segment.startFrame].timestamp)
        updateElapsed()
    }
}
