import Foundation

@main struct PoseArrangementProbe {
    enum Failure: Error { case assertion(String) }
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure.assertion(message) }
    }
    @MainActor static func waitForArrangement(_ store: CapturedMotionStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !store.isAutoArranging {
            if Date() > deadline { throw Failure.assertion("Background arrangement did not start") }
            await Task.yield()
        }
    }

    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let source = fixture()
        let original = try encoded(source.report)
        let proposal = try PoseArrangementPlanner.propose(for: source, targetSeconds: 8)
        try coverage(proposal.segments, in: source)
        try require(proposal.segments.count == 3, "Two observable pauses should form three segments")
        let firstBoundary = source.report.frames[proposal.segments[1].startFrame].timestamp
        try require((6.7...7.6).contains(firstBoundary), "Boundary should follow the real pause, not an equal eight-second cut")
        let secondBoundary = source.report.frames[proposal.segments[2].startFrame].timestamp
        try require((15.1...16.0).contains(secondBoundary), "Second pause selected in original source order")
        try require(try encoded(source.report) == original, "Planner must not change full source report")

        let denseVFR = fixture(cadence: [7, 83, 11, 42, 17])
        let vfrProposal = try PoseArrangementPlanner.propose(for: denseVFR, targetSeconds: 8)
        try coverage(vfrProposal.segments, in: denseVFR)
        let vfrBoundary = denseVFR.report.frames[vfrProposal.segments[1].startFrame].timestamp
        try require(abs(firstBoundary - vfrBoundary) < 0.35, "Time-domain scores must remain stable under variable frame rate")
        try require(source.report.frames.contains { $0.timestampTimescale == 1_000 }, "Original rational PTS fixture")
        let duplicated = fixture(cadence: [30, 0, 50, 20])
        let duplicateProposal = try PoseArrangementPlanner.propose(for: duplicated, targetSeconds: 8)
        try coverage(duplicateProposal.segments, in: duplicated)
        let partial = fixture(missingEvery: 13)
        let partialProposal = try PoseArrangementPlanner.propose(for: partial, targetSeconds: 8)
        try coverage(partialProposal.segments, in: partial)
        try require(partialProposal.notice.contains("缺失"), "Partial observations must be disclosed")
        let ambiguous = fixture(ambiguousEvery: 13)
        let ambiguousProposal = try PoseArrangementPlanner.propose(for: ambiguous, targetSeconds: 8)
        try coverage(ambiguousProposal.segments, in: ambiguous)
        try require(ambiguousProposal.notice.contains("多人"), "Ambiguous observations must be disclosed")

        for unusable in [fixture(confidence: 0), fixture(confidence: 0.3), fixture(ambiguousEvery: 1)] {
            do {
                _ = try PoseArrangementPlanner.propose(for: unusable, targetSeconds: 8)
                throw Failure.assertion("No/low-confidence/multi-person input must be refused")
            } catch PoseArrangementError.insufficientSkeleton { }
        }
        for invalid in [Double.nan, .infinity, 1.9, 30.1] {
            do { _ = try PoseArrangementPlanner.propose(for: source, targetSeconds: invalid); throw Failure.assertion("Invalid explicit target accepted") }
            catch PoseArrangementError.invalidTarget { }
        }
        let short = fixture(duration: 1.0)
        let shortProposal = try PoseArrangementPlanner.propose(for: short, targetSeconds: 8)
        try require(shortProposal.segments.count == 1, "Short clip remains intact")
        try coverage(shortProposal.segments, in: short)
        let oneFrame = fixture(duration: 0.01, cadence: [30])
        let oneProposal = try PoseArrangementPlanner.propose(for: oneFrame, targetSeconds: 8)
        try coverage(oneProposal.segments, in: oneFrame)
        let constant = fixture(pauses: false)
        let constantProposal = try PoseArrangementPlanner.propose(for: constant, targetSeconds: 8)
        try require(constantProposal.segments.count == 1 && constantProposal.notice.contains("没有明显"), "Constant movement must not masquerade as inferred boundaries")

        var legacy = try JSONSerialization.jsonObject(with: encoded(source)) as! [String: Any]
        legacy.removeValue(forKey: "arrangementMethod"); legacy.removeValue(forKey: "sourceModelID")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let old = try JSONDecoder().decode(CapturedMotion.self, from: legacyData)
        try old.validate()
        try require(old.arrangementMethod == nil && old.sourceModelID == nil, "Existing JSON models must decode without new metadata")

        let store = CapturedMotionStore(directory: root.appendingPathComponent("models"))
        while store.isLoading { await Task.yield() }
        store.select(source)
        store.seek(12); store.start()
        let nameEditFrame = store.playback.frameIndex
        let nameEditElapsed = store.playback.elapsed
        let nameEditRevision = store.revision
        try require(store.playback.isPlaying, "Rename fixture must be actively playing")
        store.rename("Immediate external import name")
        try require(store.selected?.name == "Immediate external import name" && store.hasUnsavedChanges && store.revision == nameEditRevision + 1, "Typing a valid name must update external readers, dirty state, and revision immediately")
        try require(store.playback.frameIndex == nameEditFrame && store.playback.elapsed == nameEditElapsed && store.playback.isPlaying, "Renaming must preserve playback frame, elapsed time, and playing state")
        store.rename("")
        try require(store.selected?.name == "Immediate external import name", "Temporary empty text input keeps the last valid model name")
        store.rename("Replacement after clearing")
        try require(store.selected?.name == "Replacement after clearing" && store.playback.frameIndex == nameEditFrame && store.playback.isPlaying, "New input after clearing must immediately reach external readers without restarting playback")
        store.pause()
        let priorSegments = store.selected!.segments.map(\.id)
        await store.autoArrange(targetSeconds: 8)
        try require(store.errorMessage == nil && store.proposedArrangement != nil && !store.isAutoArranging, "Proposal generation completes")
        try require(store.selected!.segments.map(\.id) == priorSegments, "Suggestions cannot replace existing work before explicit Apply")
        try store.applyAutoArrangement()
        try require(store.proposedArrangement == nil && store.hasUnsavedChanges, "Apply creates an editable unsaved model")
        try require(store.selected!.arrangementMethod?.contains("low-motion-v1") == true, "Method provenance retained")
        try coverage(store.selected!.segments, in: source)
        let editedID = store.selected!.segments[0].id
        let adjustedBoundary = store.selected!.segments[0].endFrame + 2
        try store.setSegmentBoundary(after: editedID, endFrame: adjustedBoundary)
        try coverage(store.selected!.segments, in: source)
        try require(store.selected!.segments[1].startFrame == adjustedBoundary + 1, "Manual edits move the shared boundary without gaps")
        try require(store.selected!.arrangementMethod!.hasSuffix("manually-edited"), "Manual edits are marked in provenance")
        do { try store.setSegmentBoundary(after: editedID, endFrame: -1); throw Failure.assertion("Invalid manual boundary accepted") }
        catch CapturedMotionError.invalidBoundary { }
        await store.saveSelected()
        try require(store.errorMessage == nil, "Arranged model save succeeds")
        let loaded = CapturedMotionPersistence.load(from: store.directory)
        try require(loaded.errors.isEmpty && loaded.models.count == 1, "Saved model must load: \(loaded.errors)")
        let restored = loaded.models[0]
        try require(restored.arrangementMethod == store.selected!.arrangementMethod, "Arrangement method persistence")
        try require(try encoded(restored.report) == original, "Full original coordinates, frame order, timestamps and metadata survive save")
        let snapshot = restored.libraryCopy()
        try require(snapshot.id != restored.id && snapshot.sourceModelID == restored.id, "Independent library snapshot provenance")
        try require(try encoded(snapshot.report) == original && snapshot.arrangementMethod == restored.arrangementMethod, "Library copies preserve all observations and method")

        await store.autoArrange(targetSeconds: 8)
        store.rename("Edited after proposal")
        try require(store.proposedArrangement == nil, "Model edits invalidate a visible proposal")
        do { try store.applyAutoArrangement(); throw Failure.assertion("Stale proposal applied") }
        catch CapturedMotionError.noSelection { }

        let large = fixture(duration: 24, cadence: [1])
        store.select(large)
        let editingRun = Task { await store.autoArrange(targetSeconds: 8) }
        try await waitForArrangement(store)
        store.rename("Concurrent edit must survive")
        await editingRun.value
        try require(store.selected?.name == "Concurrent edit must survive" && store.proposedArrangement == nil, "Revision guard protects edits made during background computation")
        try require(store.errorMessage?.contains("发生变化") == true, "Stale calculation is explained")

        let switchingRun = Task { await store.autoArrange(targetSeconds: 8) }
        try await waitForArrangement(store)
        store.select(short)
        await switchingRun.value
        try require(store.selected?.id == short.id && store.proposedArrangement == nil, "Model ID guard protects switching videos")

        store.select(large)
        let rangeRun = Task { await store.autoArrange(targetSeconds: 8) }
        try await waitForArrangement(store)
        try store.setRange(start: 1, end: large.frameCount - 1)
        await rangeRun.value
        try require(store.proposedArrangement == nil && store.selectionA == 1, "A-B edits during computation invalidate suggestions")
        let firstRun = Task { await store.autoArrange(targetSeconds: 8) }
        try await waitForArrangement(store)
        await store.autoArrange(targetSeconds: 2)
        await firstRun.value
        try require(store.proposedArrangement?.targetSeconds == 8, "Reentrant generation must not replace the running request")
        let cancelled = Task { await store.autoArrange(targetSeconds: 8) }
        try await waitForArrangement(store)
        cancelled.cancel()
        await cancelled.value
        try require(!store.isAutoArranging && store.proposedArrangement == nil, "Cancelled background work must not publish a proposal or keep the UI busy")
        print("PASS: all-frame VFR boundaries, actual pauses, duplicate PTS, missing/multi-person/low-confidence policies, short clips, explicit target bounds, preview/apply, continuous manual boundaries, old JSON, full-report persistence, library provenance, concurrent edit/video/range guards, reentry, cancellation, and immediate rename without playback reset.")
    }

    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func coverage(_ segments: [CapturedMotionSegment], in model: CapturedMotion) throws {
        let covered = segments.flatMap { Array($0.startFrame...$0.endFrame) }
        try require(covered == Array(model.report.frames.indices), "Every original frame appears exactly once in order")
        try require(segments.allSatisfy { $0.startFrame <= $0.endFrame && $0.repeats == 1 }, "Nonempty unrepeated suggestions")
        let duration = segments.reduce(0) { $0 + model.duration(of: $1) }
        try require(abs(duration - model.report.duration) < 0.000001, "All source PTS durations must remain represented")
    }
    static func fixture(duration: Double = 24, cadence: [Int64] = [20, 50, 30, 40], confidence: Double = 0.95, missingEvery: Int = 0, ambiguousEvery: Int = 0, pauses: Bool = true) -> CapturedMotion {
        let names = ["neck", "root", "leftShoulder", "rightShoulder", "leftHip", "rightHip", "leftKnee", "rightKnee", "leftAnkle", "rightAnkle"]
        var frames: [PoseFrame] = []
        var tick: Int64 = 0
        while Double(tick) / 1_000 < duration {
            let index = frames.count
            let time = Double(tick) / 1_000
            let movingTime = pauses ? time - min(max(time - 6.8, 0), 0.6) - min(max(time - 15.2, 0), 0.6) : time
            let missing = confidence == 0 || (missingEvery > 0 && index % missingEvery == 0)
            let ambiguous = ambiguousEvery > 0 && index % ambiguousEvery == 0
            let joints: [String: PoseJoint] = missing ? [:] : Dictionary(uniqueKeysWithValues: names.enumerated().map {
                ($0.element, PoseJoint(x: 0.1 + movingTime * 0.01 + Double($0.offset) * 0.02, y: 0.1 + Double($0.offset) * 0.07, confidence: confidence))
            })
            frames.append(PoseFrame(timestamp: time, timestampValue: tick, timestampTimescale: 1_000, joints: joints, bodyCount: missing ? 0 : ambiguous ? 2 : 1, ambiguous: !missing && ambiguous))
            tick += cadence[index % cadence.count]
        }
        let detected = frames.filter(\.hasDetectedBody).count
        let report = PoseReport(sourceName: "SYNTHETIC_POSE_ARRANGEMENT.mov", frames: frames, duration: duration, decodedFrameCount: frames.count, detectedFrameCount: detected, coverage: Double(detected) / Double(frames.count), createdAt: Date(timeIntervalSince1970: 1), coordinateSystem: "synthetic normalized XY", modelName: "synthetic-fixture-only", modelRevision: 1)
        return CapturedMotion(schemaVersion: 1, id: UUID(), name: "Synthetic arrangement", createdAt: Date(), imageAspectRatio: 4.0 / 3, report: report, segments: [CapturedMotionSegment(name: "Existing segment", startFrame: 0, endFrame: frames.count - 1)])
    }
}
