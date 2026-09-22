// Real source-backed plans and production TrainingStore behavior. The runner
// confines session history to a fresh temporary directory; dataset is read-only.
import Foundation
import HidanCore

private struct TrainingDemonstrationFailure: Error, CustomStringConvertible { let description: String }

@main struct AISTTrainingPlanProbe {
    struct Catalog: Decodable {
        struct Entry: Decodable {
            let id: String
            let style: DanceStyle
            let genreCode: String
            let choreographyCode: String
            let name: String
            let observationCue: String
        }
        let entries: [Entry]
    }
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw TrainingDemonstrationFailure(description: message) }
    }
    static func rejected(_ label: String, _ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw TrainingDemonstrationFailure(description: "Invalid action was accepted: \(label)")
    }

    @MainActor static func main() throws {
        guard ProcessInfo.processInfo.environment["HIDAN_AIST_STORE_QA"] == "1",
              let datasetPath = ProcessInfo.processInfo.environment["HIDAN_AIST_DIR"],
              let catalogPath = ProcessInfo.processInfo.environment["HIDAN_TRAINING_MOVES_FILE"],
              let historyPath = ProcessInfo.processInfo.environment["HIDAN_DATA_DIR"],
              !FileManager.default.fileExists(atPath: historyPath) else {
            throw TrainingDemonstrationFailure(description: "Use qa_aist_store.sh with a new isolated history directory")
        }
        let root = URL(fileURLWithPath: datasetPath, isDirectory: true)
        let manifestData = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(AISTManifest.self, from: manifestData)
        try manifest.validate()
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: URL(fileURLWithPath: catalogPath)))
        var moves: [AISTTrainingMove] = []
        for entry in catalog.entries {
            guard let sequence = manifest.sequences.first(where: {
                $0.genreCode == entry.genreCode && $0.choreographyCode == entry.choreographyCode && $0.isBasic && !$0.ignored
            }) else { throw TrainingDemonstrationFailure(description: "Missing actual source for \(entry.id)") }
            let motion = try AISTMotion(directory: root, sequence: sequence, optimized: false)
            try check(motion.frameCount == sequence.frameCount, "Mapped source has wrong full frame count")
            let reference = try AISTPracticeReference(sequence: sequence, name: entry.name,
                                                      startFrame: 0, endFrame: sequence.frameCount - 1,
                                                      optimized: false, speed: 1)
            moves.append(AISTTrainingMove(id: entry.id, style: entry.style, reference: reference, observationCue: entry.observationCue))
        }
        try check(moves.count == 12, "Expected twelve source-backed teaching observations")
        var planCount = 0
        for style in DanceStyle.allCases {
            let candidates = moves.filter { $0.style == style }
            try check(candidates.count == 3, "Each supported style must have three actual demonstrations")
            for minutes in 10...45 {
                for level in 1...2 {
                    let result = try AISTTrainingPlanBuilder.make(durationMinutes: minutes, style: style, level: level, moves: moves)
                    try check(result.plan.totalSeconds == minutes * 60, "Source-backed plan budget differs: \(style), \(minutes), \(level)")
                    try check(result.plan.blocks.first?.kind == .warmup && result.plan.blocks.last?.kind == .cooldown, "Missing warmup/cooldown")
                    try check(result.plan.blocks.contains { $0.kind == .rest }, "Missing recovery")
                    try check(result.plan.blocks.allSatisfy { $0.durationSeconds > 0 }, "Non-positive block duration")
                    let practice = result.plan.blocks.filter { $0.kind == .drill || $0.kind == .freestyle }
                    try check(!practice.isEmpty && result.referencesByBlockID.count == practice.count, "Practice does not have exactly one reference per block")
                    for block in result.plan.blocks {
                        guard block.kind == .drill || block.kind == .freestyle else {
                            try check(result.referencesByBlockID[block.id] == nil, "Recovery block unexpectedly has a dance demonstration")
                            continue
                        }
                        guard let reference = result.referencesByBlockID[block.id], let source = candidates.first(where: { $0.id == block.moveID }) else {
                            throw TrainingDemonstrationFailure(description: "Unmapped drill: \(block.title)")
                        }
                        try check(block.title == reference.name && block.title == source.reference.name, "Drill title is not its real demonstration name")
                        try check(block.cue == source.observationCue, "Drill cue did not come from its observation prompt")
                        try check(reference.sequence == source.reference.sequence && reference.frameRange == source.reference.frameRange && reference.optimized == source.reference.optimized, "Plan changed the source sequence, layer or frame range")
                        try check(reference.speed == (level == 1 ? 0.5 : 0.75), "Level changed something other than supported playback pace")
                    }
                    planCount += 1
                }
            }
        }
        for invalidMinutes in [Int.min, 9, 46, Int.max] {
            try rejected("invalid plan duration") { _ = try AISTTrainingPlanBuilder.make(durationMinutes: invalidMinutes, style: .hipHop, moves: moves) }
        }
        for invalidLevel in [0, 3] {
            try rejected("invalid plan level") { _ = try AISTTrainingPlanBuilder.make(durationMinutes: 20, style: .hipHop, level: invalidLevel, moves: moves) }
        }
        try rejected("empty source library") { _ = try AISTTrainingPlanBuilder.make(durationMinutes: 20, style: .hipHop, moves: []) }
        try rejected("duplicate source ID") { _ = try AISTTrainingPlanBuilder.make(durationMinutes: 20, style: moves[0].style, moves: [moves[0], moves[0]]) }
        let wrongStyle = AISTTrainingMove(id: "wrong-style", style: .popping, reference: moves[0].reference, observationCue: "Observe")
        try rejected("mismatched source genre") { _ = try AISTTrainingPlanBuilder.make(durationMinutes: 20, style: .popping, moves: [wrongStyle]) }
        let missingCue = AISTTrainingMove(id: "missing-cue", style: moves[0].style, reference: moves[0].reference, observationCue: " \n")
        try rejected("missing observation cue") { _ = try AISTTrainingPlanBuilder.make(durationMinutes: 20, style: moves[0].style, moves: [missingCue]) }

        let store = TrainingStore()
        try check(!store.hasDemonstrations && !store.hasConfiguredDemonstrations && store.referencesByBlockID.isEmpty, "Fallback plan has fabricated demonstrations")
        let fallback = store.plan
        let fallbackClock = store.clock.sessionID
        store.start(); store.configureDemonstrations(moves)
        try check(store.plan == fallback && store.clock.sessionID == fallbackClock && store.referencesByBlockID.isEmpty, "Configuration overwrote an active old plan")
        try check(store.hasConfiguredDemonstrations && !store.hasDemonstrations, "Configured library was not retained for next plan")
        store.pause(); store.configureDemonstrations(Array(moves.reversed()))
        try check(store.plan == fallback && store.clock.state == .paused, "Configuration overwrote paused old plan")
        store.stop(); store.rebuild()
        try check(store.hasDemonstrations && store.reference == nil && store.plan.totalSeconds == 1200, "Rebuild did not upgrade old plan to actual demonstrations")
        let mappedPlan = store.plan, mappedReferences = store.referencesByBlockID
        let mappedClock = store.clock.sessionID
        store.start(); store.configureDemonstrations(moves); store.rebuild()
        try check(store.plan == mappedPlan && store.referencesByBlockID == mappedReferences && store.clock.sessionID == mappedClock, "Active demonstrated plan was overwritten")
        store.advance()
        guard let block = store.snapshot.currentBlock else { throw TrainingDemonstrationFailure(description: "Current drill unavailable") }
        try check(block.kind == .drill && store.currentReference == store.reference(for: block) && store.currentReference != nil, "Current demonstration did not follow the training block")
        store.pause(); store.configureDemonstrations([])
        try check(store.referencesByBlockID == mappedReferences && store.clock.state == .paused, "Clearing library destroyed active demonstration mapping")
        store.stop(); store.configureDemonstrations(moves)
        try check(store.hasDemonstrations, "Idle configuration did not restore a source-backed plan")

        let custom = moves.last!.reference
        try store.prepareReference(custom, rounds: 4)
        let customPlan = store.plan, customClock = store.clock.sessionID
        try check(store.reference == custom && store.hasDemonstrations, "Custom fragment is not fully demonstrated")
        for block in customPlan.blocks {
            try check(store.reference(for: block) == (block.kind == .drill ? custom : nil), "Custom plan has an incorrect per-block mapping")
        }
        store.configureDemonstrations(Array(moves.reversed()))
        try check(store.reference == custom && store.plan == customPlan && store.clock.sessionID == customClock, "Library update overwrote custom fragment plan")
        store.minutes = 9; store.rebuild()
        try check(store.plan == customPlan && store.reference == custom && store.hasDemonstrations && store.demonstrationError != nil, "Invalid rebuild was not atomic")
        store.minutes = 20; store.style = .house; store.level = 2; store.rebuild()
        try check(store.reference == nil && store.hasDemonstrations && store.demonstrationError == nil, "Return from custom plan failed")
        try check(store.referencesByBlockID.values.allSatisfy { $0.sequence.genreCode == "gHO" && $0.speed == 0.75 }, "Ordinary style or pace did not reach actual reference mapping")
        store.configureDemonstrations([])
        try check(!store.hasConfiguredDemonstrations && !store.hasDemonstrations && store.referencesByBlockID.isEmpty, "Missing library fallback retained stale demonstration references")
        try check(Data(contentsOf: root.appendingPathComponent("manifest.json")) == manifestData, "QA modified source manifest")
        print("PASS: \(planCount) real-source plans; every drill's title/cue/sequence/layer/full-range mapping; exact 10–45 minute budgets and recovery; 0.5/0.75 pace only; invalid catalog rejection; active and paused protection; custom fragment mappings; idle configuration/rebuild/fallback; current demonstration follows blocks. User history untouched.")
    }
}
