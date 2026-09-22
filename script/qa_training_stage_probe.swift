// Run only through qa_training_stage.sh. Production stores and complete source
// motions are read directly; all history and preference writes are isolated.
import Foundation
import HidanCore

private struct TrainingStageFailure: Error, CustomStringConvertible {
    let description: String
}

@main struct TrainingStageProbe {
    @MainActor static func main() async {
        do { try await run() }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw TrainingStageFailure(description: message) }
    }

    @MainActor private static func wait(_ label: String, timeout: Double = 8, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw TrainingStageFailure(description: "Timed out: \(label)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor private static func settles() async throws {
        try await Task.sleep(nanoseconds: 180_000_000)
    }

    @MainActor private static func assertReference(_ stage: TrainingDemonstrationStore,
                                                  expected: AISTPracticeReference? = nil) throws {
        guard let reference = expected ?? stage.reference else { throw TrainingStageFailure(description: "Missing displayed reference") }
        try check(stage.isReady, "Stage is not ready for its displayed reference")
        try check(stage.reference == reference, "Displayed reference differs from the expected source reference")
        try check(stage.player.practiceReference() == reference, "Displayed range, source layer, speed or name differs from the training reference")
        try check(stage.player.currentJoints.count == 17, "Displayed reference does not contain the complete COCO frame")
        try check(!reference.sequence.ignored, "Default training selected an ignored reconstruction")
    }

    @MainActor private static func run() async throws {
        guard let mode = ProcessInfo.processInfo.environment["HIDAN_TRAINING_STAGE_QA"],
              ["normal", "missing", "index-only"].contains(mode),
              let domain = ProcessInfo.processInfo.environment["HIDAN_QA_DEFAULTS_DOMAIN"],
              domain.hasPrefix("org.hidanclub.qa.training-stage."), Bundle.main.bundleIdentifier == domain,
              let datasetPath = ProcessInfo.processInfo.environment["HIDAN_AIST_DIR"],
              let historyPath = ProcessInfo.processInfo.environment["HIDAN_DATA_DIR"],
              !FileManager.default.fileExists(atPath: historyPath) else {
            throw TrainingStageFailure(description: "Use qa_training_stage.sh with its isolated application, data and new history fixtures")
        }
        let preferences = UserDefaults.standard
        try check(preferences.persistentDomain(forName: domain) == nil, "QA preference domain must be new")
        defer { preferences.removePersistentDomain(forName: domain); preferences.synchronize() }
        let dataset = URL(fileURLWithPath: datasetPath, isDirectory: true)
        let manifestURL = dataset.appendingPathComponent("manifest.json")
        let manifestBefore = try? Data(contentsOf: manifestURL)
        let training = TrainingStore()
        let stage = TrainingDemonstrationStore(training: training)
        defer { stage.stop(); stage.player.pause() }

        if mode != "normal" {
            try check(!stage.startOrResume(), "Training started before unavailable demonstration data was checked")
            try await wait("missing-data error") { !stage.player.loading && stage.issue != nil }
            try check(!stage.isReady && !stage.startOrResume(), "Missing data did not block start")
            try check(!training.active && !stage.player.isPlaying, "Missing data started a clock or player")
            stage.togglePreview(); try await settles()
            try check(!training.active && !stage.player.isPlaying, "Missing data allowed preview playback")
            if mode == "index-only" {
                try check(stage.player.manifest != nil && stage.player.motion == nil, "Index-only fixture did not isolate missing motion bytes")
            }
            try check((try? Data(contentsOf: manifestURL)) == manifestBefore, "Missing-data test modified the fixture manifest")
            print("PASS: \(mode) data blocks training and preview with a visible issue; no false readiness or playback.")
            return
        }

        try await wait("automatic catalog and first demonstration") { training.hasDemonstrations && stage.isReady }
        try check(training.reference == nil && training.hasConfiguredDemonstrations, "Normal plan did not receive its real demonstration catalog automatically")
        try check(training.clock.state == .idle && !stage.player.isPlaying, "Initial preview auto-started the training clock or player")
        try assertReference(stage)
        for block in training.plan.blocks where block.kind == .drill || block.kind == .freestyle {
            guard let reference = training.reference(for: block) else { throw TrainingStageFailure(description: "Unmapped practice block: \(block.title)") }
            try check(reference.sequence.isBasic && !reference.sequence.ignored, "Practice block did not use a usable basic source sequence")
            try check(block.title.contains(reference.name), "Practice block retained an unrelated old text-card title")
        }
        stage.togglePreview()
        try await wait("idle preview frames") { stage.player.isPlaying && stage.player.frameIndex > 0 }
        try check(training.clock.state == .idle, "Preview incorrectly started training time")
        stage.togglePreview()
        let previewFrame = stage.player.frameIndex
        try await settles()
        try check(!stage.player.isPlaying && stage.player.frameIndex == previewFrame, "Preview pause continued advancing frames")

        for style in DanceStyle.allCases {
            training.style = style; training.minutes = 10; training.level = 1; training.rebuild()
            let genre = ["hipHop": "gMH", "popping": "gPO", "locking": "gLO", "house": "gHO"][style.rawValue]!
            try await wait("\(style.rawValue) demonstrated plan") { stage.isReady && stage.reference?.sequence.genreCode == genre }
            try assertReference(stage)
            try check(stage.startOrResume(), "Cannot start the \(style.rawValue) demonstrated plan")
            try await wait("\(style.rawValue) running warmup") { training.clock.state == .running }
            try check(!stage.isCurrentDrill && stage.stageLabel.contains("预览"), "Warmup demonstration is not labelled as a preview")
            stage.advance()
            try await wait("\(style.rawValue) automatic drill playback") {
                training.clock.state == .running && training.currentReference != nil && stage.isReady && stage.player.isPlaying
            }
            try assertReference(stage, expected: training.currentReference)
            try check(stage.stageLabel.contains("当前动作"), "Running drill is not labelled as the current action")
            stage.pause()
            let pausedFrame = stage.player.frameIndex
            try await settles()
            try check(training.clock.state == .paused && !stage.player.isPlaying && stage.player.frameIndex == pausedFrame,
                      "\(style.rawValue) pause did not freeze both time and reference")
            try check(stage.startOrResume(), "\(style.rawValue) did not resume")
            try await wait("\(style.rawValue) resumed frames") { stage.player.isPlaying && stage.player.frameIndex != pausedFrame }
            stage.stop()
            try await wait("\(style.rawValue) stopped reference settles") { !stage.player.loading }
            try await settles()
            try check(training.clock.state == .stopped && !stage.player.isPlaying, "\(style.rawValue) stop restarted after a queued update")
        }

        training.style = .hipHop; training.rebuild()
        try await wait("skip/cancellation initial reference") { stage.isReady && stage.reference?.sequence.genreCode == "gMH" }
        try check(stage.startOrResume(), "Skip test could not start")
        stage.advance()
        try await wait("skip test first drill") { training.currentReference != nil && stage.isReady && training.clock.state == .running }
        let firstReference = training.currentReference!
        stage.advance()
        try await wait("rest preloads next action") { training.snapshot.currentBlock?.kind == .rest && stage.isReady && training.clock.state == .running }
        try check(stage.reference != firstReference && stage.stageLabel.contains("预览"), "Rest did not preload and label the next source action")
        stage.advance()
        try await wait("second drill follows preloaded action") { training.currentReference != nil && stage.isReady && stage.player.isPlaying }
        try assertReference(stage, expected: training.currentReference)

        // Pause and stop in the same actor turn as a source-changing skip. The
        // pending asynchronous load must not later resume time or playback.
        stage.advance(); stage.pause()
        try await wait("paused pending source load") { !stage.player.loading }
        try await settles()
        try check(training.clock.state == .paused && !stage.player.isPlaying, "An old load restarted explicitly paused training")
        try check(stage.startOrResume(), "Cannot resume after cancelling automatic source resume")
        stage.advance(); stage.advance(); stage.stop()
        try await wait("stopped pending source load") { !stage.player.loading }
        try await settles()
        try check(training.clock.state == .stopped && !stage.player.isPlaying, "An old load restarted stopped training")

        guard let manifest = stage.player.manifest,
              let customSequence = manifest.sequences.first(where: { $0.genreCode == "gPO" && $0.isBasic && $0.choreographyCode == "ch05" && !$0.ignored }) else {
            throw TrainingStageFailure(description: "Custom-range source sequence unavailable")
        }
        let custom = try AISTPracticeReference(sequence: customSequence, name: "body wave", startFrame: 24,
                                                endFrame: 119, optimized: true, speed: 0.75)
        try training.prepareReference(custom, rounds: 2)
        try await wait("custom AB demonstration auto-load") { stage.reference == custom && stage.isReady }
        try assertReference(stage, expected: custom)
        let expectedBytes = try Data(contentsOf: dataset.appendingPathComponent(customSequence.optimizedPath))
        try check(stage.player.motion?.data == expectedBytes, "Custom optimized reference loaded different coordinate bytes")
        try check(stage.startOrResume(), "Custom reference cannot start")
        stage.advance()
        try await wait("custom drill runs") { training.currentReference == custom && stage.isReady && stage.player.isPlaying }
        try assertReference(stage, expected: custom)
        stage.pause(); stage.reload()
        try await wait("reload retains custom reference") { stage.isReady && stage.reference == custom }
        try assertReference(stage, expected: custom)
        try check(training.clock.state == .paused && !stage.player.isPlaying, "Reload resumed a paused custom plan")
        stage.stop()

        // Entry from the arrangement library keeps each explicit source reference.
        try training.prepareArrangement(references: [custom, firstReference], name: "QA source arrangement")
        let arrangementID = training.plan.id
        try check(training.isCustomPlan && training.reference == nil, "Arrangement is not protected as a custom plan")
        try check(training.plan.totalSeconds == 230, "Arrangement warmup/drill/rest/cooldown budget changed")
        let arrangementDrills = training.plan.blocks.filter { $0.kind == .drill }
        try check(arrangementDrills.compactMap { training.reference(for: $0) } == [custom, firstReference], "Arrangement changed source order/range/layer/speed")
        training.configureDemonstrations([AISTTrainingMove(id: "qa-custom-catalog", style: .hipHop, reference: firstReference, observationCue: "QA observation")])
        try check(training.plan.id == arrangementID && training.isCustomPlan, "Catalog refresh overwrote an idle arrangement")
        do { try training.prepareArrangement(references: [], name: "empty"); throw TrainingStageFailure(description: "Empty arrangement accepted") }
        catch is TrainingStageFailure { throw TrainingStageFailure(description: "Empty arrangement accepted") }
        catch { try check(training.plan.id == arrangementID, "Invalid arrangement changed the plan") }
        try await wait("arrangement first reference") { stage.reference == custom && stage.isReady }
        try check(stage.startOrResume(), "Arrangement did not start")
        stage.advance()
        try await wait("arrangement first drill") { training.currentReference == custom && stage.isReady && stage.player.isPlaying }
        stage.pause()
        do { try training.prepareArrangement(references: [firstReference], name: "overwrite"); throw TrainingStageFailure(description: "Paused arrangement overwritten") }
        catch is TrainingStageFailure { throw TrainingStageFailure(description: "Paused arrangement overwritten") }
        catch { try check(training.plan.id == arrangementID, "Paused arrangement changed on rejected prepare") }
        try check(stage.startOrResume(), "Arrangement did not resume")
        stage.advance(); stage.advance()
        try await wait("arrangement second drill") { training.currentReference == firstReference && stage.isReady && stage.player.isPlaying }
        try assertReference(stage, expected: firstReference)
        stage.stop(); training.rebuild()
        try check(!training.isCustomPlan && training.plan.id != arrangementID, "Ordinary rebuild retained custom arrangement state")
        print("PASS: arrangement entry preserves source order, A-B, variant and speed; exact 230-second training budget; catalog refresh and paused overwrite protection; next-clip playback; return to ordinary plans.")

        try check(Data(contentsOf: manifestURL) == manifestBefore, "Training stage QA modified the installed source manifest")
        print("PASS: automatic bundled catalog; all drill-to-source mappings; idle preview; four styles start/pause/resume/stop; warmup/rest labels; automatic next-action loading; pending-load pause/stop cancellation; exact custom AB/variant/speed and source bytes; paused reload; installed data remains read-only.")
    }
}
