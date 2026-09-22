import CryptoKit
import Foundation
import HidanCore

private struct ArrangementFailure: Error, CustomStringConvertible { let description: String }

@main struct ArrangementProbe {
    @MainActor static func main() throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let qa = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let manifestURL = source.appendingPathComponent("manifest.json")
        let manifestBytes = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(AISTManifest.self, from: manifestBytes)
        try manifest.validate()
        let sequences = manifest.sequences.filter { !$0.ignored && $0.frameCount > 600 }
        guard sequences.count >= 2 else { throw ArrangementFailure(description: "Need two installed full source sequences") }
        let first = try AISTPracticeReference(sequence: sequences[0], name: "原始选段", startFrame: 24, endFrame: 119, optimized: false, speed: 0.25)
        let second = try AISTPracticeReference(sequence: sequences[1], name: "官方优化选段", startFrame: 120, endFrame: 599, optimized: true, speed: 0.75)
        let sourceURL = try first.sequence.motionURL(in: source, optimized: false)
        let sourceHash = SHA256.hash(data: try Data(contentsOf: sourceURL))
        let store = AISTArrangementStore()
        try expect(store.directory == qa.appendingPathComponent("state", isDirectory: true), "Environment isolation ignored")
        try expect(store.draft.isEmpty && store.saved.isEmpty && store.canEditDraft, "New store is not empty/writable")
        try store.add(reference: first); try store.add(reference: second); try store.add(reference: first)
        try expect(store.draft == [first, second, first], "Duplicate source slots lost")
        try store.renameDraft("练习的名字")
        let reopened = AISTArrangementStore()
        try expect(reopened.draft == store.draft && reopened.draftName == "练习的名字", "Unsaved draft/name did not survive reopening")
        try store.moveDraft(at: 0, by: 1)
        try expect(store.draft == [second, first, first], "Reorder lost source references")
        try store.removeDraft(at: 2)
        try expect(store.draft == [second, first], "Remove lost unrelated ranges")
        let a = try store.saveDraft(name: "  完整源片段组合  ")
        try expect(a.name == "完整源片段组合" && a.references == [second, first], "Save changed name or reference metadata")
        try expect(abs(a.sourceDuration - second.sourceDuration - first.sourceDuration) < 1e-9, "Source duration is not exact full-range sum")
        try expect(abs(a.duration - second.duration - first.duration) < 1e-9, "Playback speeds lost from duration")
        let loaded = AISTArrangementStore()
        try expect(loaded.saved == [a] && loaded.selected == a && loaded.draft == a.references, "UUID JSON roundtrip/edit identity failed")
        try loaded.add(reference: first); try loaded.add(reference: second); try loaded.add(reference: first)
        let updated = try loaded.saveDraft(name: "五段编排")
        try expect(updated.id == a.id && updated.createdAt == a.createdAt && updated.references.count == 5, "Edit failed or imposed an artificial four-slot limit")
        try loaded.newDraft()
        try expect(loaded.draft.isEmpty && loaded.saved.count == 1 && loaded.selected == nil, "New draft deleted saved work")
        try loaded.add(reference: second)
        let b = try loaded.saveDraft(name: "另一套")
        try expect(b.id != a.id && loaded.saved.count == 2, "New save reused old identity")
        try loaded.loadDraft(updated)
        try expect(loaded.draft == updated.references && loaded.selected == updated, "Edit entry loaded wrong references")
        try expectThrows("Invalid move accepted") { try loaded.moveDraft(at: 0, by: -1) }
        try expectThrows("Empty name accepted") { _ = try loaded.saveDraft(name: "  ") }
        try expect(loaded.saved.count == 2, "Invalid edit altered saved entries")

        let damagedURL = loaded.directory.appendingPathComponent(updated.id.uuidString.lowercased()).appendingPathExtension("json")
        let corrupt = Data("{broken original".utf8)
        try corrupt.write(to: damagedURL)
        try expectThrows("Corrupted saved file was overwritten") { _ = try loaded.saveDraft(name: "should fail") }
        try expect(Data(contentsOf: damagedURL) == corrupt, "Corrupted saved file changed")
        let withCorruption = AISTArrangementStore()
        try expect(withCorruption.saved == [b] && withCorruption.errorMessage != nil, "Corrupt entry hid healthy saved work or lost diagnostic")
        try withCorruption.loadDraft(b)

        let draftURL = loaded.directory.appendingPathComponent("draft.json")
        try corrupt.write(to: draftURL)
        let before = loaded.draft
        try expectThrows("Externally corrupted draft was overwritten") { try loaded.add(reference: first) }
        try expect(loaded.draft == before && Data(contentsOf: draftURL) == corrupt, "Rejected draft write mutated memory/file")
        let healthyURL = loaded.directory.appendingPathComponent(b.id.uuidString.lowercased()).appendingPathExtension("json")
        let healthyBefore = try Data(contentsOf: healthyURL)
        try expectThrows("Save ignored externally corrupted draft") { _ = try withCorruption.saveDraft(name: "must not write") }
        try expect(Data(contentsOf: healthyURL) == healthyBefore, "Failed save changed healthy model before checking damaged draft")
        let damagedDraft = AISTArrangementStore()
        try expect(!damagedDraft.canEditDraft && damagedDraft.errorMessage != nil && damagedDraft.saved == [b], "Damaged draft is not protected")
        try expectThrows("New draft silently erased corruption") { try damagedDraft.newDraft() }

        let symlinkDirectory = qa.appendingPathComponent("symlinks", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkDirectory, withIntermediateDirectories: true)
        let external = qa.appendingPathComponent("external.json")
        let encoder = JSONEncoder(); try encoder.encode(b).write(to: external)
        let link = symlinkDirectory.appendingPathComponent(b.id.uuidString.lowercased()).appendingPathExtension("json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        let symlinkStore = AISTArrangementStore(directory: symlinkDirectory)
        try expect(symlinkStore.saved.isEmpty && symlinkStore.errorMessage != nil, "Symlink saved entry was accepted")
        try expect(SHA256.hash(data: try Data(contentsOf: sourceURL)) == sourceHash && Data(contentsOf: manifestURL) == manifestBytes, "Arrangement workflow modified source dataset")
        print("AIST ARRANGEMENT QA PASSED: exact A–B/layer/speed/order; duplicates; 1/2/5-slot arrangements; draft and UUID-save restart; rename/edit/new identities; source/playback durations; invalid operations; corrupted saved/draft refusal; symlink refusal; source hashes unchanged.")
    }
    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw ArrangementFailure(description: message) }
    }
    private static func expectThrows(_ message: String, operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw ArrangementFailure(description: message)
    }
}
