// Run with qa_aist_store.sh. Reads the dataset; writes only isolated training fixtures.
import Foundation
import HidanCore

@main struct AISTPracticeProbe {
    @MainActor static func main() throws {
        guard ProcessInfo.processInfo.environment["HIDAN_AIST_STORE_QA"] == "1",
              let datasetPath = ProcessInfo.processInfo.environment["HIDAN_AIST_DIR"],
              let historyPath = ProcessInfo.processInfo.environment["HIDAN_DATA_DIR"],
              !FileManager.default.fileExists(atPath: historyPath) else {
            throw NSError(domain: "AISTPracticeProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Run via qa_aist_store.sh with a new isolated history directory."])
        }
        let manifestURL = URL(fileURLWithPath: datasetPath).appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(AISTManifest.self, from: Data(contentsOf: manifestURL))
        let sequence = manifest.sequences.first { $0.genreCode == "gHO" && !$0.ignored }!
        let reference = try AISTPracticeReference(sequence: sequence, name: "  Train Shuffle  ", startFrame: 12, endFrame: 71, optimized: true, speed: 0.5)
        precondition(reference.name == "Train Shuffle")
        precondition(reference.frameCount == 60 && reference.sourceDuration == 1 && reference.duration == 2)
        precondition(reference.frameRange == 12...71)
        let restored = try JSONDecoder().decode(AISTPracticeReference.self, from: JSONEncoder().encode(reference))
        precondition(restored == reference)
        for rounds in [2, 4, 6] {
            let plan = try AISTPracticePlanBuilder.make(reference: reference, rounds: rounds)
            precondition(plan.totalSeconds == 90 + rounds * 60 + (rounds - 1) * 20)
            precondition(plan.blocks.first?.durationSeconds == 60 && plan.blocks.last?.durationSeconds == 30)
            precondition(plan.blocks.filter { $0.kind == .drill }.count == rounds)
            precondition(plan.blocks.filter { $0.kind == .rest }.count == rounds - 1)
            precondition(plan.title.contains(sequence.id) && plan.title.contains(sequence.genreName) && plan.title.contains("13–72") && plan.title.contains(reference.name))
            var clock = TrainingClock(plan: plan)
            let now = Date(timeIntervalSince1970: 1000)
            clock.start(at: now)
            clock.pause(at: now.addingTimeInterval(10))
            clock.resume(at: now.addingTimeInterval(30))
            clock.tick(at: now.addingTimeInterval(Double(plan.totalSeconds + 20)))
            precondition(clock.finishedSession()?.planTitle == plan.title)
            precondition(clock.activeSeconds == Double(plan.totalSeconds))
        }
        func expectFailure(_ action: () throws -> Void) {
            do { try action(); preconditionFailure("Expected error") } catch { }
        }
        for (first, last) in [(-1, 2), (2, 1), (0, sequence.frameCount), (Int.min, Int.max)] {
            expectFailure { _ = try AISTPracticeReference(sequence: sequence, name: "x", startFrame: first, endFrame: last, optimized: false, speed: 1) }
        }
        for speed in [0.0, -1.0, Double.nan, .infinity, 0.1, 1.1, 2.0] {
            expectFailure { _ = try AISTPracticeReference(sequence: sequence, name: "x", startFrame: 0, endFrame: 1, optimized: true, speed: speed) }
        }
        expectFailure { _ = try AISTPracticeReference(sequence: sequence, name: " \n", startFrame: 0, endFrame: 1, optimized: true, speed: 1) }
        for rounds in [0, 1, 3, 7, Int.max] { expectFailure { _ = try AISTPracticePlanBuilder.make(reference: reference, rounds: rounds) } }
        var tampered = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reference)) as! [String: Any]
        tampered["endFrame"] = -1
        let tamperedData = try JSONSerialization.data(withJSONObject: tampered)
        expectFailure { _ = try JSONDecoder().decode(AISTPracticeReference.self, from: tamperedData) }
        let store = TrainingStore()
        precondition(store.reference == nil)
        try store.prepareReference(reference, rounds: 4)
        precondition(store.reference == reference && store.clock.state == .idle && store.plan.totalSeconds == 390)
        let originalID = store.plan.id
        expectFailure { try store.prepareReference(reference, rounds: 3) }
        precondition(store.plan.id == originalID && store.reference == reference)
        store.start()
        expectFailure { try store.prepareReference(reference, rounds: 2) }
        store.rebuild()
        precondition(store.reference == reference && store.plan.id == originalID && store.active)
        store.pause()
        expectFailure { try store.prepareReference(reference, rounds: 6) }
        precondition(store.clock.state == .paused && store.plan.id == originalID)
        store.stop()
        precondition(store.history.first?.planTitle == store.plan.title)
        let recordedTitle = store.plan.title
        let restoredStore = TrainingStore()
        precondition(restoredStore.history.first?.planTitle == recordedTitle)
        precondition(restoredStore.history.first?.id == store.history.first?.id)
        store.rebuild()
        precondition(store.reference == nil && store.clock.state == .idle && store.plan.totalSeconds == 1200)
        print("PASS: real AIST reference Codable; inclusive frames; speed-duration; 2/4/6 round exact budgets; source traceability; pause exclusion; invalid ranges/speeds/rounds/decoded data; active and paused plan replacement rejection; failure atomicity; rebuild clearing; session title persistence. User history untouched.")
    }
}
