import Foundation
import Combine

@main struct VideoMotionLibraryProbe {
    struct Failure: Error { let message: String }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    @MainActor static func loaded(_ store: CapturedLibraryStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while store.isLoading {
            if Date() > deadline { throw Failure(message: "Loading timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let names = ["neck", "root", "leftShoulder", "rightShoulder", "leftHip", "rightHip", "leftKnee", "rightKnee"]
        let joints = Dictionary(uniqueKeysWithValues: names.enumerated().map {
            ($0.element, PoseJoint(x: 0.1 + Double($0.offset) * 0.08, y: 0.5, confidence: 0.9))
        })
        let times: [Int64] = [0, 1, 1, 3, 5, 9, 10, 13]
        let frames = times.map { PoseFrame(timestamp: Double($0) / 30, timestampValue: $0, timestampTimescale: 30,
                                           joints: joints, bodyCount: 1, ambiguous: false) }
        let report = PoseReport(sourceName: "synthetic-only.mov", frames: frames, duration: 0.5,
                                decodedFrameCount: frames.count, detectedFrameCount: frames.count, coverage: 1,
                                createdAt: Date(), coordinateSystem: "synthetic-normalized", modelName: "QA fixture", modelRevision: 1)
        let source = CapturedMotion(schemaVersion: 1, id: UUID(), name: "测试来源", createdAt: Date(), imageAspectRatio: 4.0 / 3,
                                    report: report, segments: [CapturedMotionSegment(name: "前段", startFrame: 0, endFrame: 3, repeats: 2),
                                                              CapturedMotionSegment(name: "后段", startFrame: 4, endFrame: 7)])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let originalBytes = try encoder.encode(source)
        let library = CapturedLibraryStore(directory: directory)
        try await loaded(library)
        guard let action = await library.importModel(source, to: .actions, range: 2...5) else { throw Failure(message: library.errorMessage ?? "Import action failed") }
        try require(action.id != source.id && action.sourceModelID == source.id, "Independent identity and source provenance")
        try require(action.segments.count == 1 && action.segments[0].startFrame == 2 && action.segments[0].endFrame == 5, "Action uses requested continuous range")
        try require(action.report.frames.map(\.timestampValue) == times, "Action keeps all original frames, duplicate PTS included")
        guard let arrangement = await library.importModel(source, to: .arrangements) else { throw Failure(message: "Import arrangement failed") }
        try require(arrangement.segments.map(\.repeats) == [2, 1], "Arrangement keeps order and repetitions")
        try require(try encoder.encode(source) == originalBytes, "Source was not mutated")
        let invalid = await library.importModel(source, to: .actions, range: 0...100)
        try require(invalid == nil && library.actions.count == 1, "Invalid range cannot publish")
        let fresh = CapturedLibraryStore(directory: directory)
        try await loaded(fresh)
        try require(fresh.actions.first?.id == action.id && fresh.arrangements.first?.id == arrangement.id, "Both libraries reload independently")
        var edited = arrangement; edited.name = "修改后的编排"; edited.segments.swapAt(0, 1)
        let didUpdate = await fresh.updateArrangement(edited)
        try require(didUpdate && fresh.arrangements.first?.segments[0].name == "后段", "Explicit published editing persists")
        try require(fresh.actions.first?.segments[0].startFrame == 2, "Arrangement edit leaves action copy alone")
        async let firstImport = fresh.importModel(source, to: .actions, range: 0...1)
        async let secondImport = fresh.importModel(source, to: .arrangements)
        let pair = await (firstImport, secondImport)
        try require(pair.0 != nil && pair.1 != nil, "Concurrent destination requests both complete")
        // All requests are queued on the main actor before it yields. A completed
        // write must not announce idle while another accepted request is waiting.
        var idleTransitions = 0
        let activity = fresh.$isImporting.dropFirst().sink { busy in
            if !busy { idleTransitions += 1 }
        }
        let queued = (0..<8).map { index in
            Task { @MainActor in
                await fresh.importModel(source, to: index.isMultiple(of: 2) ? .actions : .arrangements)
            }
        }
        for task in queued {
            let result = await task.value
            try require(result != nil, "Every queued publication completes")
        }
        try require(!fresh.isImporting && idleTransitions == 1, "Termination-visible activity stays busy until all queued writes finish")
        activity.cancel()
        let corruptURL = directory.appendingPathComponent("Arrangements").appendingPathComponent(arrangement.id.uuidString.lowercased() + ".json")
        let corrupt = Data("not valid json".utf8); try corrupt.write(to: corruptURL)
        let refused = await fresh.updateArrangement(edited)
        try require(!refused, "Corrupt existing data blocks overwrite")
        try require(try Data(contentsOf: corruptURL) == corrupt, "Corrupt bytes preserved")
        print("Video motion library QA passed: isolated imports, full VFR provenance, restart, editing, queued writes stay busy through final completion, corrupt-file refusal.")
    }
}
