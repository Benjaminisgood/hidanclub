import AVFoundation
import Combine
import Foundation

/// Synthetic joints below exercise state and precision only. The real Vision
/// decoder is independently exercised with an eight-frame blank VFR video.
@main struct CapturedMotionProbe {
    enum Failure: Error { case assertion(String) }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure.assertion(message) } }
    @MainActor static func wait(_ name: String, seconds: Double = 5, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() { if Date() > deadline { throw Failure.assertion("Timeout: " + name) }; try await Task.sleep(nanoseconds: 10_000_000) }
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let store = CapturedMotionStore()
        try await wait("empty storage") { !store.isLoading }
        let clip = root.appendingPathComponent("vfr-blank.mov")
        let pts: [Int64] = [0, 1, 3, 4, 7, 8, 12, 15]
        try await makeVideo(at: clip, timestamps: pts)
        if let keep = ProcessInfo.processInfo.environment["HIDAN_CAPTURE_QA_KEEP_DIR"] {
            let keepDirectory = URL(fileURLWithPath: keep, isDirectory: true)
            try FileManager.default.createDirectory(at: keepDirectory, withIntermediateDirectories: true)
            try Data(contentsOf: clip).write(to: keepDirectory.appendingPathComponent("QA-blank-vfr.mov"), options: .atomic)
        }
        let blank = try await PoseVideoDecoder.analyze(url: clip, onProgress: { _ in })
        try require(blank.decodedFrameCount == 8 && blank.frames.count == 8, "All real decoded frames must survive")
        for (frame, expected) in zip(blank.frames, pts) { try require(abs(frame.timestamp - Double(expected) / 30) < 1e-10, "Original VFR PTS") }
        store.beginCapture(name: "空白视频诊断", imageAspectRatio: 4.0 / 3)
        try store.acceptAnalysis(blank)
        let blankID = store.selected!.id
        try store.acceptAnalysis(blank)
        try require(store.selected?.id == blankID, "Reappearing capture page must not regenerate the same report")
        try require(!store.hasPlayableMotion && store.selected?.usableFrameCount == 0, "Blank input must never be playable")
        store.start(); try require(!store.playback.isPlaying, "Blank motion blocks playback")
        await store.saveSelected()
        try require(!store.hasUnsavedChanges && store.errorMessage == nil, "Blank frames are still saved")
        let restoredBlank = CapturedMotionPersistence.load(from: store.directory).models.first!
        try compareFrames(blank.frames, restoredBlank.report.frames)
        try FileManager.default.removeItem(at: clip)
        try require(restoredBlank.frameCount == 8, "Saved model is independent of its source file")

        let fixture = makeFixture()
        try fixture.validate()
        try require(fixture.usableFrameCount == 4 && fixture.report.frames.count == 6, "Usable coverage excludes missing and ambiguous frames")
        try require(fixture.hasPlayableMotion, "Fixture arrangement has usable bodies")
        try require(fixture.frameDuration(at: 2) == 0, "Duplicate PTS frames stay present")
        try require(abs(fixture.duration(of: fixture.segments[0]) - 0.4) < 1e-10, "A–B includes the final selected frame hold")
        try CapturedMotionPersistence.save(fixture, to: store.directory)
        let restored = CapturedMotionPersistence.load(from: store.directory).models.first { $0.id == fixture.id }!
        try compareFrames(fixture.report.frames, restored.report.frames)
        try require(restored.segments.map(\.id) == fixture.segments.map(\.id), "Arrangement identity round-trip")
        try require(restored.name == "../../offline fixture", "Model names must remain data")
        let modelPath = store.directory.appendingPathComponent(fixture.id.uuidString.lowercased() + ".json")
        try require(FileManager.default.fileExists(atPath: modelPath.path), "Saved filename must be UUID")

        store.select(restored)
        var parentChanges = 0
        let observation = store.objectWillChange.sink { parentChanges += 1 }
        let player = store.playback
        player.start()
        var visited: [Int] = [player.frameIndex]
        for _ in 0..<9 { player.advanceOneFrame(); if !player.isCompleted { visited.append(player.frameIndex) } }
        try require(visited == [0, 1, 2, 0, 1, 2, 3, 4, 5], "Every frame, blank and duplicate PTS included, must be visited in arrangement order")
        try require(player.isCompleted && !player.isPlaying && abs(player.elapsed - player.planDuration) < 1e-10, "Arrangement completion")
        try require(parentChanges == 0, "High frequency playback must not invalidate parent store")
        player.start(); try require(player.frameIndex == 0 && player.segmentIndex == 0 && !player.isCompleted, "Completed arrangement restarts from first segment")
        player.pause(); let pausedFrame = player.frameIndex
        try await Task.sleep(nanoseconds: 150_000_000)
        try require(player.frameIndex == pausedFrame, "Pause cancels timer progression")
        player.stop(); player.loop = true; player.start()
        for _ in 0..<9 { player.advanceOneFrame() }
        try require(player.frameIndex == 0 && player.segmentIndex == 0 && player.repetitionIndex == 0 && player.elapsed == 0 && !player.isCompleted, "Whole arrangement loop resets sequence")
        player.advance(); try require(player.segmentIndex == 1 && player.frameIndex == 3, "Next segment uses selected A–B start")
        player.loop = false; player.advance(); try require(player.isCompleted, "Next after last segment reaches end")
        try require(player.hasSkippedSegments, "Manual skip must not be labelled as full playback")
        player.stop(); try require(!player.hasSkippedSegments, "Restart resets the skip marker")
        player.step(Int.max); try require(player.frameIndex == 5, "Frame step overflow clamps")
        player.step(Int.min); try require(player.frameIndex == 0, "Negative frame step clamps")
        player.speed = .nan; try require(player.speed == 1, "Nonfinite speed resets")
        player.speed = -10; try require(player.speed == 0.25, "Slow speed clamps")
        player.speed = 2; try require(player.speed == 1, "Fast speed clamps")
        observation.cancel()

        // Check live Timer behavior independently of the deterministic visits.
        player.prepare(fixture); player.start(); player.pause(); player.speed = 0.25; player.start()
        try await Task.sleep(nanoseconds: 650_000_000)
        try require(player.frameIndex == 0, "Changing speed while paused scales the remaining hold")
        try await wait("slowed first frame", seconds: 3) { player.frameIndex != 0 }
        player.pause(); player.speed = 1
        // Deliberately stall the main actor past multiple frame intervals.
        player.prepare(fixture); player.start()
        deliberatelyStallActorForTest(0.85)
        player.advanceOneFrame()
        try require(player.frameIndex == 1, "One delayed callback consumes one frame without catch-up")
        player.pause()

        try store.setRange(start: 1, end: 2)
        try store.useSelectionAsArrangement(name: "没有骨架的片段")
        try require(!store.hasPlayableMotion && store.selected!.frameCount == 6, "Empty selected segment blocks practice; full source remains intact")
        try store.setRange(start: 0, end: 0); try store.addSegment(name: "有骨架")
        try require(!store.hasPlayableMotion, "Every selected segment needs usable observations")
        store.removeSegment(store.selected!.segments[0].id)
        try require(store.hasPlayableMotion, "Removing empty arrangement reference enables remaining usable segment")
        store.setSegmentRepeats(store.selected!.segments[0].id, count: 3)
        try require(store.selected!.segments[0].repeats == 3, "Segment repeats edit")
        try store.setRange(start: 3, end: 5); try store.addSegment(name: "收尾")
        let last = store.selected!.segments[1].id
        store.moveSegment(last, by: -1)
        try require(store.selected!.segments[0].id == last, "Order edit")
        store.moveSegment(last, by: Int.max)
        try require(store.selected!.segments[0].id == last, "Overflow order edit is ignored")
        do { try store.setRange(start: -1, end: 6); throw Failure.assertion("Invalid A–B accepted") } catch CapturedMotionError.invalidRange { }
        let exportedURL = root.appendingPathComponent("full-model-export.json")
        let savedIDs = store.saved.map(\.id)
        await store.exportSelected(to: exportedURL)
        try require(store.errorMessage == nil && store.hasUnsavedChanges && !store.isExporting, "Export succeeds without marking draft saved")
        try require(store.saved.map(\.id) == savedIDs, "Export does not mutate managed library")
        let exported = try JSONDecoder().decode(CapturedMotion.self, from: Data(contentsOf: exportedURL))
        try compareFrames(fixture.report.frames, exported.report.frames)
        try require(exported.id == store.selected!.id && exported.name == store.selected!.name && exported.segments.map(\.id) == store.selected!.segments.map(\.id), "Export keeps current model and arrangement")
        try require(exported.report.modelName == fixture.report.modelName && exported.report.modelRevision == fixture.report.modelRevision && exported.report.coordinateSystem == fixture.report.coordinateSystem && exported.imageAspectRatio == fixture.imageAspectRatio, "Export keeps capture provenance and aspect ratio")
        await store.exportSelected(to: root)
        try require(store.errorMessage != nil && store.hasUnsavedChanges && !store.isExporting, "Failed export retains draft and reports error")
        await store.saveSelected()
        try require(!store.hasUnsavedChanges && store.errorMessage == nil, "Edited arrangement saves")
        store.rename(store.selected!.name)
        try require(!store.hasUnsavedChanges, "Unchanged name does not dirty model")
        let arrangementRestored = CapturedMotionPersistence.load(from: store.directory).models.first { $0.id == fixture.id }!
        try compareFrames(fixture.report.frames, arrangementRestored.report.frames)
        try require(arrangementRestored.segments.map(\.id) == store.selected!.segments.map(\.id), "Edited arrangement persists")

        // Damaged existing data must remain intact; valid siblings still load.
        let damaged = Data("not JSON: retained original".utf8)
        try damaged.write(to: modelPath)
        store.rename("不能覆盖损坏文件")
        await store.saveSelected()
        try require(store.errorMessage != nil && store.hasUnsavedChanges, "Corrupt existing file refuses save")
        try require(try Data(contentsOf: modelPath) == damaged, "Corrupt bytes retained")
        let mixedStore = CapturedMotionStore(directory: store.directory)
        try await wait("mixed storage") { !mixedStore.isLoading }
        try require(mixedStore.saved.count == 1 && mixedStore.selected?.id == blankID && mixedStore.errorMessage != nil, "Good models load while corruption remains visible")
        let external = root.appendingPathComponent("outside.json")
        try JSONEncoder().encode(fixture).write(to: external)
        let symlink = store.directory.appendingPathComponent(UUID().uuidString.lowercased() + ".json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: external)
        let loadWithLink = CapturedMotionPersistence.load(from: store.directory)
        try require(loadWithLink.models.count == 1 && loadWithLink.errors.count == 2, "Escaping model symlink is rejected")
        try await checkDraftsAndConcurrentStorage(root: root, fixture: fixture, savedBlank: restoredBlank)
        if let keep = ProcessInfo.processInfo.environment["HIDAN_CAPTURE_QA_KEEP_DIR"] {
            var uiFixture = fixture
            uiFixture.name = "QA 合成关节编排（非真实视频）"
            for index in uiFixture.segments.indices { uiFixture.segments[index].repeats = 10 }
            let destination = URL(fileURLWithPath: keep, isDirectory: true).appendingPathComponent("CapturedMotions", isDirectory: true)
            try CapturedMotionPersistence.save(uiFixture, to: destination)
            print("ISOLATED UI FIXTURE: \(destination.path)")
        }
        print("PASS: real decoder retains 8/8 VFR blank frames and PTS; blank input blocks practice; complete JSON coordinate/PTS round-trip and export metadata; export does not mark saved; drafts survive selection/new capture/concurrent save; stale reload cannot hide saved models; continuous A–B/order/repeats; duplicate and absent frames; one callback per frame; pause/speed/loop/restart; isolated notifications; UUID atomic persistence; source-independent models; corrupt-file retention; symlink rejection.")
        print("LIMIT: synthetic joints test state/precision, not human pose accuracy or 3D capture.")
    }

    /// A synchronous stall is intentional: this models an overloaded UI thread
    /// and proves that the next callback cannot skip overdue source frames.
    static func deliberatelyStallActorForTest(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    @MainActor static func checkDraftsAndConcurrentStorage(root: URL, fixture: CapturedMotion, savedBlank: CapturedMotion) async throws {
        let draftStore = CapturedMotionStore(directory: root.appendingPathComponent("draft-tests"))
        try await wait("draft storage") { !draftStore.isLoading }
        let first = try draftStore.prepare(report: fixture.report, name: "第一个草稿")
        try draftStore.setRange(start: 0, end: 0)
        try draftStore.useSelectionAsArrangement(name: "仅第一帧")
        let editedSegment = draftStore.selected!.segments[0].id
        let firstRevision = draftStore.revision
        draftStore.select(savedBlank); draftStore.select(first)
        try require(draftStore.hasUnsavedChanges && draftStore.selected!.segments[0].id == editedSegment, "Switching to a saved model retains prior draft edits")
        try require(draftStore.revision != firstRevision, "Selection change invalidates a pending practice request")
        let second = try draftStore.prepare(report: makeFixture().report, name: "后台新捕捉")
        try require(draftStore.drafts.count == 2, "New capture preserves the previous unsaved draft")
        draftStore.select(first)
        try require(draftStore.selected!.segments[0].id == editedSegment, "Prior draft remains selectable after new capture")
        await draftStore.saveSelected()
        try require(!draftStore.hasUnsavedChanges && draftStore.drafts.map(\.id) == [second.id], "Saving removes only the matching draft")

        // A large synthetic report makes detached I/O overlap real UI edits and
        // reloads. It is generated solely for state tests, never as dance data.
        let bigJoints = fixture.report.frames[0].joints
        let largeFrames = (0..<20_000).map { index in PoseFrame(timestamp: Double(index) / 30, timestampValue: Int64(index), timestampTimescale: 30, joints: bigJoints, bodyCount: 1, ambiguous: false) }
        let largeReport = PoseReport(sourceName: "SYNTHETIC_IO_RACE_FIXTURE", frames: largeFrames, duration: 20_000.0 / 30, decodedFrameCount: largeFrames.count, detectedFrameCount: largeFrames.count, coverage: 1, createdAt: Date(), coordinateSystem: "synthetic normalized XY", modelName: "test-fixture-only", modelRevision: 1)
        let large = try draftStore.prepare(report: largeReport, name: "较大草稿")
        let saving = Task { await draftStore.saveSelected() }
        try await wait("large save begins") { draftStore.isSaving }
        draftStore.rename("保存期间的新编辑")
        await saving.value
        try require(draftStore.hasUnsavedChanges && draftStore.selected?.name == "保存期间的新编辑", "Saving an old snapshot must not mark newer edits saved")
        try require(draftStore.saved.first { $0.id == large.id }?.name == "较大草稿", "Saved list records the snapshot actually written")
        draftStore.select(second)
        try require(draftStore.hasUnsavedChanges, "Switching to another draft preserves its dirty state")
        draftStore.select(large)
        try require(draftStore.selected?.name == "保存期间的新编辑", "Selecting saved snapshot restores newer draft")

        draftStore.reload()
        try await Task.sleep(nanoseconds: 30_000_000)
        let newSmall = try draftStore.prepare(report: fixture.report, name: "重载期间保存的新模型")
        await draftStore.saveSelected()
        try await wait("concurrent reload completes", seconds: 20) { !draftStore.isLoading }
        try require(draftStore.saved.contains { $0.id == newSmall.id }, "An earlier disk snapshot cannot hide a newly saved model")
        try require(draftStore.drafts.contains { $0.id == large.id && $0.name == "保存期间的新编辑" }, "Reload does not overwrite drafts")
    }

    static func compareFrames(_ expected: [PoseFrame], _ actual: [PoseFrame]) throws {
        try require(expected.count == actual.count, "No frame reduction in persistence")
        for (a, b) in zip(expected, actual) {
            try require(a.timestamp.bitPattern == b.timestamp.bitPattern && a.timestampValue == b.timestampValue && a.timestampTimescale == b.timestampTimescale, "Exact original timestamp preservation")
            try require(a.bodyCount == b.bodyCount && a.ambiguous == b.ambiguous && Set(a.joints.keys) == Set(b.joints.keys), "Full observations preserved")
            for (name, joint) in a.joints {
                let restored = b.joints[name]!
                try require(joint.x.bitPattern == restored.x.bitPattern && joint.y.bitPattern == restored.y.bitPattern && joint.confidence.bitPattern == restored.confidence.bitPattern, "Exact Double coordinate/confidence preservation, including negative zero")
            }
        }
    }
    static func makeFixture() -> CapturedMotion {
        let keys = ["neck", "root", "leftShoulder", "rightShoulder", "leftHip", "rightHip", "leftKnee", "rightKnee", "leftAnkle", "rightAnkle"]
        let ticks: [Int64] = [0, 4, 4, 4, 9, 12]
        let frames = ticks.enumerated().map { index, tick -> PoseFrame in
            let joints = (index == 1 || index == 2) ? [:] : Dictionary(uniqueKeysWithValues: keys.enumerated().map { joint, name in (name, PoseJoint(x: joint == 0 ? -0.0 : Double(joint) / 13, y: Double(index + joint) / 21, confidence: 0.8765432101234567)) })
            return PoseFrame(timestamp: Double(tick) / 10, timestampValue: tick, timestampTimescale: 10, joints: joints, bodyCount: index == 1 ? 0 : index == 2 ? 2 : 1, ambiguous: index == 2)
        }
        let report = PoseReport(sourceName: "SYNTHETIC_STATE_FIXTURE.mov", frames: frames, duration: 1.6, decodedFrameCount: 6, detectedFrameCount: 4, coverage: 4.0 / 6, createdAt: Date(), coordinateSystem: "upright normalized XY; synthetic fixture", modelName: "test-fixture-only", modelRevision: 1)
        return CapturedMotion(schemaVersion: 1, id: UUID(), name: "../../offline fixture", createdAt: Date(), imageAspectRatio: 4.0 / 3, report: report, segments: [CapturedMotionSegment(name: "开场", startFrame: 0, endFrame: 2, repeats: 2), CapturedMotionSegment(name: "收尾", startFrame: 3, endFrame: 5)])
    }
    static func makeVideo(at url: URL, timestamps: [Int64]) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        for timestamp in timestamps {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var optionalBuffer: CVPixelBuffer?
            try require(CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA, nil, &optionalBuffer) == kCVReturnSuccess, "Create blank frame")
            let buffer = optionalBuffer!
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 32, CVPixelBufferGetBytesPerRow(buffer) * 240)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try require(adaptor.append(buffer, withPresentationTime: CMTime(value: timestamp, timescale: 30)), "Append original VFR frame")
        }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error! }
    }
}
