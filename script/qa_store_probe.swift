// Isolated TrainingStore persistence regression probe. Run via qa_store.sh so
// HIDAN_DATA_DIR points to a fresh temporary fixture, never the user's history.
import Foundation
import HidanCore

private struct StoreProbeFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct StoreProbe {
    @MainActor
    static func main() async throws {
        guard let directoryPath = ProcessInfo.processInfo.environment["HIDAN_DATA_DIR"],
              ProcessInfo.processInfo.environment["HIDAN_STORE_PROBE"] == "1",
              CommandLine.arguments.count == 2 else {
            throw StoreProbeFailure(description: "Use script/qa_store.sh with an isolated HIDAN_DATA_DIR.")
        }
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        try expect(!FileManager.default.fileExists(atPath: directory.path), "Fixture path must not already exist")
        switch CommandLine.arguments[1] {
        case "normal": try await normalPersistence(directory: directory)
        case "corrupt": try await corruptArchive(directory: directory)
        case "write-failure": try await writeFailure(directory: directory)
        default: throw StoreProbeFailure(description: "Unknown probe scenario")
        }
    }

    private static func expect(_ condition: Bool, _ message: String,
                               file: StaticString = #fileID, line: UInt = #line) throws {
        guard condition else { throw StoreProbeFailure(description: "\(file):\(line): \(message)") }
    }

    @MainActor
    private static func normalPersistence(directory: URL) async throws {
        let store = TrainingStore()
        try expect(store.dataDirectory.standardizedFileURL == directory.standardizedFileURL, "Store uses isolated directory")
        try expect(store.history.isEmpty && store.persistenceError == nil && store.canRetrySaving, "Clean initial state")
        store.effort = 6
        store.start()
        try expect(store.clock.state == .running, "Start transitions to running")
        try await Task.sleep(nanoseconds: 350_000_000)
        let runningSnapshot = store.snapshot
        try expect(runningSnapshot.activeSeconds > 0, "Running clock accumulates actual elapsed time")
        store.pause()
        let pausedSeconds = store.clock.activeSeconds
        try expect(store.clock.state == .paused && pausedSeconds > 0 && pausedSeconds < 10, "Pause captures short actual training")
        try await Task.sleep(nanoseconds: 250_000_000)
        try expect(store.snapshot.activeSeconds == pausedSeconds, "Paused wall time does not count")
        store.stop()
        try expect(store.clock.state == .stopped && store.history.count == 1, "Stop saves one real session")
        let record = store.history[0]
        try expect(record.activeSeconds == pausedSeconds && record.completedBlocks == 0, "No completed block or duration invented")
        try expect(record.totalBlocks == store.plan.blocks.count && record.perceivedEffort == 6, "Actual plan and effort stored")
        try expect(store.persistenceError == nil, "Normal write succeeds")
        try expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.json").path), "Archive exists")
        store.stop()
        store.pause()
        store.advance()
        store.retrySaving()
        try expect(store.history.count == 1, "Repeated stop/advance/save does not duplicate record")
        let restored = TrainingStore()
        try expect(restored.history == [record], "New store restores the exact record once")
        try expect(restored.clock.state == .idle && !restored.active, "Running state is not falsely restored")
        try expect(restored.persistenceError == nil && restored.canRetrySaving, "Restored archive stays writable")
        restored.retrySaving()
        let restoredAgain = TrainingStore()
        try expect(restoredAgain.history == [record], "Repeated restore/save remains deduplicated")
        print("PASS store normal: \(String(format: "%.3f", record.activeSeconds)) actual seconds; paused time excluded; 0/\(record.totalBlocks) completed blocks; one persisted UUID; two independent reloads; no fabricated running state")
    }

    @MainActor
    private static func corruptArchive(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archiveURL = directory.appendingPathComponent("history.json")
        let corruptBytes = Data("{\"version\":1,\"sessions\":[ deliberately broken JSON\n\u{0000}retain-original-bytes".utf8)
        try corruptBytes.write(to: archiveURL)
        let store = TrainingStore()
        try expect(store.history.isEmpty && store.persistenceError != nil, "Corrupt archive visibly refuses load")
        try expect(!store.canRetrySaving, "Corruption blocks saving retry")
        let bytesAfterLoad = try Data(contentsOf: archiveURL)
        try expect(bytesAfterLoad == corruptBytes, "Initial read preserves corrupt original bytes")
        store.start()
        try await Task.sleep(nanoseconds: 80_000_000)
        store.stop()
        try expect(store.history.count == 1 && store.history[0].activeSeconds > 0, "New session remains available in memory")
        try expect(!store.canRetrySaving && store.persistenceError != nil, "New session cannot silently clear corruption block")
        store.retrySaving()
        let bytesAfterAttemptedSave = try Data(contentsOf: archiveURL)
        try expect(bytesAfterAttemptedSave == corruptBytes, "Training stop and explicit retry do not overwrite corrupt original")
        let reopened = TrainingStore()
        try expect(reopened.history.isEmpty && reopened.persistenceError != nil && !reopened.canRetrySaving, "Reopening still refuses untouched corrupt archive")
        print("PASS store corrupt: original \(corruptBytes.count) bytes unchanged after read, training stop, and retry; canRetrySaving=false; clear error; no silent overwrite")
    }

    @MainActor
    private static func writeFailure(directory: URL) async throws {
        let parent = directory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let blockerBytes = Data("ordinary file deliberately blocking the archive parent directory".utf8)
        try blockerBytes.write(to: directory)
        let store = TrainingStore()
        try expect(store.history.isEmpty && store.canRetrySaving, "A new archive with obstructed directory is recoverable")
        store.start()
        try await Task.sleep(nanoseconds: 80_000_000)
        store.pause()
        store.stop()
        try expect(store.history.count == 1 && store.history[0].activeSeconds > 0, "Write failure retains actual session in memory")
        let record = store.history[0]
        try expect(store.persistenceError != nil && store.canRetrySaving, "Write failure is visible and explicitly retryable")
        let untouchedBlocker = try Data(contentsOf: directory)
        try expect(untouchedBlocker == blockerBytes, "Failed save leaves obstruction unchanged")
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archiveURL = directory.appendingPathComponent("history.json")
        try expect(!FileManager.default.fileExists(atPath: archiveURL.path), "Removing obstruction alone does not claim successful save")
        try expect(store.persistenceError != nil, "Error remains until explicit retry succeeds")
        store.retrySaving()
        try expect(store.persistenceError == nil && store.canRetrySaving, "Successful explicit retry clears error")
        try expect(FileManager.default.fileExists(atPath: archiveURL.path), "Explicit retry creates archive")
        try expect(store.history == [record], "Retry does not duplicate or alter in-memory session")
        let restored = TrainingStore()
        try expect(restored.history == [record] && restored.persistenceError == nil, "Fresh store restores recovered record exactly once")
        print("PASS store write failure: parent-file obstruction preserved; real session retained; visible recoverable error; explicit retry persisted original UUID; clean reload")
    }
}
