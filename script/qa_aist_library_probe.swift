// Run via qa_aist_store.sh: production store, real data read-only, isolated app
// UserDefaults domain and Bundle.module accessor. No UI or audio starts.
import Foundation
import HidanCore

private struct AISTLibraryProbeFailure: Error, CustomStringConvertible {
    let description: String
}

@main struct AISTLibraryProbe {
    @MainActor static func main() async {
        do { try await run() }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw AISTLibraryProbeFailure(description: message) }
    }

    @MainActor private static func wait(_ label: String, timeout: Double = 5, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw AISTLibraryProbeFailure(description: "Timed out: \(label)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor private static func run() async throws {
        guard ProcessInfo.processInfo.environment["HIDAN_AIST_STORE_QA"] == "1",
              let domain = ProcessInfo.processInfo.environment["HIDAN_QA_DEFAULTS_DOMAIN"],
              domain.hasPrefix("org.hidanclub.qa."), Bundle.main.bundleIdentifier == domain,
              let datasetPath = ProcessInfo.processInfo.environment["HIDAN_AIST_DIR"] else {
            throw AISTLibraryProbeFailure(description: "Use qa_aist_store.sh; unique app preference-domain isolation is required")
        }
        let preferences = UserDefaults.standard
        try check(preferences.persistentDomain(forName: domain) == nil, "QA preference domain must be new")
        preferences.set([String](), forKey: "aist.favorites")
        preferences.set("/invalid/qa/override", forKey: "aist.datasetDirectory")
        preferences.synchronize()
        defer { preferences.removePersistentDomain(forName: domain); preferences.synchronize() }
        try check(preferences.persistentDomain(forName: domain)?["aist.favorites"] as? [String] == [], "UserDefaults.standard did not use isolated app domain")
        let dataset = URL(fileURLWithPath: datasetPath, isDirectory: true)
        let manifestURL = dataset.appendingPathComponent("manifest.json")
        let manifestBefore = try Data(contentsOf: manifestURL)
        let store = AISTLibraryStore()
        defer { store.pause() }
        try await wait("initial manifest + source motion") { !store.loading && store.motion != nil }
        guard let initial = store.selected, let manifest = store.manifest else { throw AISTLibraryProbeFailure(description: "Initial selection unavailable") }
        try check(store.directory.standardizedFileURL == dataset.standardizedFileURL, "HIDAN_AIST_DIR must override saved directory")
        try check(initial.genreCode == "gMH" && initial.isBasic && !initial.ignored, "Initial sequence is not suitable Middle Hip-hop")
        try check(store.name(for: initial) == "roger rabbit", "Official initial action name did not load from bundled source names: received '\(store.name(for: initial))' for \(initial.id)")
        try check(!store.optimized && !store.isPlaying && store.frameIndex == 0, "Initial playback should be paused on original reconstructed layer")
        try check(store.loopStart == 0 && store.loopEnd == initial.frameCount - 1, "Initial AB range does not cover all source frames")
        try check(store.motion?.data == Data(contentsOf: dataset.appendingPathComponent(initial.rawPath)), "Initial motion bytes differ from original source")

        store.toggleFavorite(initial.id)
        try check(store.favorites == [initial.id], "Favorite was not added")
        preferences.synchronize()
        try check(preferences.persistentDomain(forName: domain)?["aist.favorites"] as? [String] == [initial.id], "Favorite persisted outside isolated domain or did not persist")
        store.toggleFavorite(initial.id)
        try check(store.favorites.isEmpty, "Favorite was not removed")

        guard let runningMan = manifest.sequences.first(where: { $0.genreCode == "gMH" && $0.isBasic && $0.choreographyCode == "ch09" && !$0.ignored }) else {
            throw AISTLibraryProbeFailure(description: "Official Middle Hip-hop ch09 sequence missing")
        }
        store.select(runningMan)
        try await wait("running man action load") { !store.loading && store.motion != nil }
        try check(store.name(for: runningMan) == "running man" && store.selected?.id == runningMan.id, "Middle Hip-hop ch09 did not use official running man name")

        let candidates = manifest.sequences.filter { !$0.ignored && $0.genreCode != initial.genreCode }
        let first = candidates[0], second = candidates[candidates.count / 2], last = candidates[candidates.count - 1]
        let originalReset = store.resetCamera
        store.select(first); store.select(second); store.select(last)
        try await wait("rapid selection final motion") { !store.loading && store.motion != nil && store.selected?.id == last.id }
        try await Task.sleep(nanoseconds: 150_000_000)
        try check(store.selected?.id == last.id && store.resetCamera == originalReset + 1, "A cancelled older load overwrote the final selection")
        try check(store.motion?.data == Data(contentsOf: dataset.appendingPathComponent(last.rawPath)), "Final selection loaded another sequence's bytes")

        store.seek(12); store.setA(); store.seek(101); store.setB(); store.seek(45)
        store.optimized = true; store.switchSource()
        try await wait("optimized source switch") { !store.loading && store.motion != nil }
        try check(store.frameIndex == 45 && store.loopStart == 12 && store.loopEnd == 101, "Source switch discarded frame or AB range")
        try check(store.motion?.data == Data(contentsOf: dataset.appendingPathComponent(last.optimizedPath)), "Source switch did not load optimized bytes")
        try check(!store.isPlaying, "Switching source unexpectedly started playback")

        let reference = try AISTPracticeReference(sequence: initial, name: store.name(for: initial), startFrame: 24, endFrame: 83, optimized: false, speed: 0.5)
        store.restoreReference(reference)
        try await wait("reference source restore") { !store.loading && store.motion != nil }
        try check(store.selected?.id == initial.id && !store.optimized && store.speed == 0.5 && store.loopEnabled, "Reference source or playback settings did not restore")
        try check(store.frameIndex == 24 && store.loopStart == 24 && store.loopEnd == 83, "Reference source frame range did not restore")
        try check(store.practiceReference() == reference, "Restored reference did not round trip through the production store")
        try check(store.currentJoints.count == 17, "Current frame did not retain all COCO joints")

        // Repeat the ordering that previously let restoring a clip cancel the
        // in-flight manifest task, leaving the library without its index.
        let pendingReference = try AISTPracticeReference(sequence: last, name: store.name(for: last), startFrame: 30, endFrame: 89, optimized: true, speed: 0.75)
        store.reload()
        store.restoreReference(reference)
        store.restoreReference(pendingReference)
        try await wait("reload with queued final reference") { !store.loading && store.manifest != nil && store.motion != nil }
        try check(store.practiceReference() == pendingReference, "Queued final reference was lost or cancelled the manifest reload")
        store.restoreReference(reference)
        try await wait("restore initial reference again") { !store.loading && store.motion != nil }

        for (input, expected) in [(Double.nan, 1.0), (.infinity, 1.0), (2.0, 1.0), (0.0, 0.25)] {
            store.speed = input
            try check(store.speed == expected, "Playback speed did not normalize to supported full-frame range")
        }
        store.speed = reference.speed

        store.seek(0); store.step(-1)
        try check(store.frameIndex == 0 && !store.isPlaying, "Step before first frame escaped boundary")
        store.step(1); try check(store.frameIndex == 1, "Step did not advance exactly one source frame")
        store.seek(initial.frameCount - 1); store.step(1)
        try check(store.frameIndex == initial.frameCount - 1, "Step beyond final frame escaped boundary")
        store.seek(-123); try check(store.frameIndex == 0, "Negative seek did not clamp")
        store.seek(Int.max); try check(store.frameIndex == initial.frameCount - 1, "Large seek did not clamp")
        store.step(Int.max); try check(store.frameIndex == initial.frameCount - 1, "Overflowing positive step did not clamp")
        store.step(Int.min); try check(store.frameIndex == 0, "Overflowing negative step did not clamp")

        store.seek(0); store.eightBeats()
        guard let bpm = initial.bpm else { throw AISTLibraryProbeFailure(description: "Known source BPM unavailable") }
        let expectedFrames = min(initial.frameCount, Int((8 * 60 / Double(bpm) * initial.fps).rounded()))
        try check(store.loopEnd - store.loopStart + 1 == expectedFrames, "Eight-beat AB range has an inclusive-frame error")
        try check(abs(store.loopDuration - Double(expectedFrames) / initial.fps) < 0.000001, "Loop source duration changed with playback speed")
        try check(abs(store.loopDuration - 8 * 60 / Double(bpm)) <= 0.5 / initial.fps, "Eight-beat duration differs by more than frame rounding")
        store.seek(initial.frameCount - 2); store.eightBeats()
        try check(store.loopEnd == initial.frameCount - 1 && store.loopEnd - store.loopStart + 1 == 2, "Eight-beat range did not clamp to source end")

        store.fullRange(); store.seek(0); store.speed = 1
        store.play()
        try await wait("sequential playback begins") { store.frameIndex > 0 }
        store.pause()
        let pausedFrame = store.frameIndex
        try await Task.sleep(nanoseconds: 180_000_000)
        try check(!store.isPlaying && store.frameIndex == pausedFrame, "Paused playback advanced source frames")
        store.seek(10); store.setA(); store.seek(12); store.setB(); store.seek(10)
        store.play()
        try await wait("short AB loop advances") { store.frameIndex != 10 }
        try await Task.sleep(nanoseconds: 150_000_000)
        store.pause()
        try check((10...12).contains(store.frameIndex), "Loop playback escaped inclusive AB range")
        try check(Data(contentsOf: manifestURL) == manifestBefore, "QA modified the installed dataset manifest")
        print("PASS: isolated UserDefaults + Bundle.module; roger rabbit initial name and original layer; running man ch09; rapid asynchronous load cancellation; source switch preserves frame/AB; queued reference restoration across reload; exact frame stepping and overflow bounds; speed normalization; eight-beat frame rounding; timer playback/loop; pause prevents progression; dataset remains read-only.")
    }
}
