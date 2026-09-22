import AVFoundation
import Foundation

@main struct VideoLibraryProbe {
    enum Failure: Error { case assertion(String) }
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure.assertion(message) }
    }
    @MainActor static func wait(_ description: String, seconds: Double = 20, until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate() {
            if Date() > deadline { throw Failure.assertion("Timed out: \(description)") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let source = root.appendingPathComponent("original-vfr.mov")
        let timestamps: [Int64] = [0, 1, 3, 4, 8, 12, 13, 18]
        try await makeVideo(at: source, timestamps: timestamps)
        let originalBytes = try Data(contentsOf: source)
        let folder = root.appendingPathComponent("Videos", isDirectory: true)
        let store = VideoLibraryStore(directory: folder)
        let captured = CapturedMotionStore(directory: root.appendingPathComponent("Models", isDirectory: true))
        try await wait("stores load") { !store.isLoading && !captured.isLoading }

        await store.importVideo(url: source)
        try require(store.items.count == 1 && store.selected != nil && store.errorMessage == nil, "Import creates selected durable item")
        let first = store.selected!
        try require(first.source == .imported && first.displayWidth == 240 && first.displayHeight == 320 && first.orientation == 6, "Original rotation and portrait dimensions retained")
        let copyURL = try store.url(for: first)
        try require(try Data(contentsOf: copyURL) == originalBytes, "Managed original is byte-for-byte identical")
        try require(copyURL.deletingPathExtension().lastPathComponent == first.id.uuidString.lowercased(), "Only UUID determines stored path")

        // Independent concurrent calls must retain every video, including training callbacks.
        async let importA: Void = store.importVideo(url: source)
        async let importB: Void = store.importVideo(url: source, source: .trainingRecording)
        async let importC: Void = store.importVideo(url: source, source: .trainingRecording)
        _ = await (importA, importB, importC)
        try require(store.items.count == 3 && !store.isImporting, "Concurrent imports are not dropped")
        let recording = store.items.first { $0.source == .trainingRecording }!
        async let retryA: Void = store.importVideo(url: source, source: .trainingRecording)
        async let retryB: Void = store.importVideo(url: source, source: .trainingRecording)
        _ = await (retryA, retryB)
        try require(store.items.count == 3 && store.selectedID == recording.id, "Recording retries are idempotent")

        store.select(first.id)
        let reopened = VideoLibraryStore(directory: folder)
        try await wait("reopen") { !reopened.isLoading }
        try require(reopened.items.count == 3 && reopened.selectedID == first.id, "Items and selection survive process-equivalent reload")
        try FileManager.default.removeItem(at: source)
        let asset = AVURLAsset(url: try reopened.url(for: reopened.selected!))
        let reopenedTracks = try await asset.loadTracks(withMediaType: .video)
        try require(reopenedTracks.count == 1, "Source video is playable after original is removed")
        await reopened.importVideo(url: source, source: .trainingRecording)
        try require(reopened.items.count == 3 && reopened.selectedID == recording.id, "Persisted recording identity survives relaunch even without its pending source")

        store.analyzeSelected(captured: captured)
        try await wait("full-frame analysis persisted", seconds: 40) { !store.isAnalyzing }
        try require(store.errorMessage == nil && store.progress == 1 && store.selected?.modelID != nil, "Analysis completion requires persisted model and video link")
        let modelID = store.selected!.modelID!
        try await wait("captured refresh") { !captured.isLoading }
        let storedModels = CapturedMotionPersistence.load(from: captured.directory).models
        let model = storedModels.first { $0.id == modelID }!
        try require(model.report.frames.count == timestamps.count, "Every VFR source frame survives analysis and persistence")
        for (frame, tick) in zip(model.report.frames, timestamps) {
            try require(abs(frame.timestamp - Double(tick) / 30) < 1e-10, "Original frame timestamps remain exact")
        }
        try require(model.imageAspectRatio == 0.75 && !model.hasPlayableMotion, "Portrait aspect ratio retained; blank video is not playable pose data")
        let linkedReload = VideoLibraryPersistence.load(from: folder)
        try require(linkedReload.items.first { $0.id == first.id }?.modelID == modelID, "Model association persists independently")
        store.select(recording.id)
        try require(store.selectModel(id: modelID) && store.selectedID == first.id, "Model links navigate to the owning video")
        try require(!store.selectModel(id: UUID()) && store.selectedID == first.id, "Unknown model leaves selection unchanged")

        store.select(recording.id)
        store.analyzeSelected(captured: captured)
        store.select(first.id)
        try await Task.sleep(nanoseconds: 300_000_000)
        try require(!store.isAnalyzing && store.items.first { $0.id == recording.id }?.modelID == nil, "Switch cancels without assigning result to either video")

        captured.select(model)
        let selectedBeforeBackground = captured.selected!.id
        let playbackBeforeBackground = captured.playback.model!.id
        let third = store.items.first { $0.id != first.id && $0.id != recording.id }!
        store.select(third.id)
        store.analyzeSelected(captured: captured)
        try await wait("background result", seconds: 40) { !store.isAnalyzing && !captured.isLoading }
        try require(captured.selected?.id == selectedBeforeBackground && captured.playback.model?.id == playbackBeforeBackground, "Background completion must not replace another training selection or playback")
        store.select(first.id)

        let invalid = root.appendingPathComponent("not-video.mov")
        try Data("not a video".utf8).write(to: invalid)
        await store.importVideo(url: invalid)
        try require(store.items.count == 3 && store.errorMessage != nil && store.selectedID == first.id, "Invalid video does not enter library or replace selection")

        // Corrupt metadata cannot be overwritten even by an otherwise successful analysis.
        let metadataURL = folder.appendingPathComponent(recording.id.uuidString.lowercased() + ".json")
        let corruptBytes = Data("preserve damaged video metadata".utf8)
        try corruptBytes.write(to: metadataURL)
        store.select(recording.id)
        store.analyzeSelected(captured: captured)
        try await wait("refuse corrupt association write", seconds: 40) { !store.isAnalyzing }
        try require(store.errorMessage != nil && store.selected?.modelID == nil && store.progress == 0, "Failed metadata write never announces completion")
        try require(try Data(contentsOf: metadataURL) == corruptBytes, "Damaged metadata stays byte-identical")
        let mixed = VideoLibraryPersistence.load(from: folder)
        try require(mixed.items.count == 2 && mixed.errors.count == 1, "Valid siblings load while corruption is reported")

        let selectionURL = folder.appendingPathComponent("selection.json")
        try corruptBytes.write(to: selectionURL)
        store.select(first.id)
        try require(try Data(contentsOf: selectionURL) == corruptBytes, "Corrupt selection file also refuses overwrite")

        let external = root.appendingPathComponent("external-original.mov")
        try originalBytes.write(to: external)
        try FileManager.default.removeItem(at: copyURL)
        try FileManager.default.createSymbolicLink(at: copyURL, withDestinationURL: external)
        do { _ = try store.url(for: first); throw Failure.assertion("Escaping original symlink accepted") }
        catch VideoLibraryError.missingVideo { }

        try await checkRecordingRecovery(root: root, movieBytes: originalBytes)

        print("PASS: unmodified source copies, persistent selection and videos, portrait orientation, replay without source, concurrent imports, recording retry deduplication, full VFR frame/PTS preservation, persisted model associations, cancellation isolation, invalid-video rejection, corrupt-file retention, original symlink rejection, and idempotent finalized-recording recovery with strict completion markers.")
        print("LIMIT: generated blank video verifies storage/decoding/state; it does not measure human pose accuracy.")
    }

    @MainActor static func checkRecordingRecovery(root: URL, movieBytes: Data) async throws {
        let pending = root.appendingPathComponent("PendingRecordings", isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let readyBytes = Data("hidan-recording-ready-v1\n".utf8)
        let finished = pending.appendingPathComponent("finished.mov")
        let finishedMarker = finished.appendingPathExtension("ready")
        try movieBytes.write(to: finished)
        try readyBytes.write(to: finishedMarker, options: .atomic)
        let unfinished = pending.appendingPathComponent("still-recording.mov")
        try movieBytes.write(to: unfinished)
        let corrupt = pending.appendingPathComponent("corrupt-marker.mov")
        let corruptMarker = corrupt.appendingPathExtension("ready")
        let corruptBytes = Data("hidan-recording-ready-v2\n".utf8)
        try movieBytes.write(to: corrupt)
        try corruptBytes.write(to: corruptMarker)
        let outerMarker = root.appendingPathComponent("outside.ready")
        try readyBytes.write(to: outerMarker)
        let linkedMarkerMovie = pending.appendingPathComponent("linked-marker.mov")
        try movieBytes.write(to: linkedMarkerMovie)
        try FileManager.default.createSymbolicLink(at: linkedMarkerMovie.appendingPathExtension("ready"), withDestinationURL: outerMarker)
        let linkedMovie = pending.appendingPathComponent("linked-original.mov")
        try FileManager.default.createSymbolicLink(at: linkedMovie, withDestinationURL: root.appendingPathComponent("external-original.mov"))
        try readyBytes.write(to: linkedMovie.appendingPathExtension("ready"))

        let recoveredFolder = root.appendingPathComponent("RecoveredVideos", isDirectory: true)
        let recovered = VideoLibraryStore(directory: recoveredFolder)
        await recovered.recoverFinishedRecordings(from: pending)
        try require(recovered.items.count == 1 && recovered.selected?.originalFilename == "finished.mov", "Startup recovers only a completed regular movie with its exact marker")
        let item = recovered.selected!
        try require(item.source == .trainingRecording && item.recordingSourcePath == finished.standardizedFileURL.resolvingSymlinksInPath().path, "Recovered video retains recording identity")
        try require(try Data(contentsOf: recovered.url(for: item)) == movieBytes, "Recovery copies finalized source bytes unchanged")
        let canonicalPending = pending.standardizedFileURL.resolvingSymlinksInPath()
        try require(recovered.errorMessage?.contains(canonicalPending.appendingPathComponent(corrupt.lastPathComponent).path) == true && recovered.errorMessage?.contains(canonicalPending.appendingPathComponent(linkedMovie.lastPathComponent).path) == true, "Recovery reports failed source paths")
        try require(try Data(contentsOf: finished) == movieBytes && Data(contentsOf: finishedMarker) == readyBytes && Data(contentsOf: corruptMarker) == corruptBytes, "Recovery retains source and valid or damaged marker bytes")

        // Saving a separate selection makes accidental reselection by repeated scans visible.
        await recovered.importVideo(url: finished)
        let selectedID = recovered.selectedID
        let reopened = VideoLibraryStore(directory: recoveredFolder)
        async let scanA: Void = reopened.recoverFinishedRecordings(from: pending)
        async let scanB: Void = reopened.recoverFinishedRecordings(from: pending)
        _ = await (scanA, scanB)
        try require(reopened.items.count == 2 && reopened.selectedID == selectedID, "Repeated concurrent restart scans do not duplicate recordings or change restored selection")
        try require(!reopened.items.contains { $0.originalFilename == unfinished.lastPathComponent }, "Readable but unmarked unfinished movie is never recovered")
    }

    static func makeVideo(at url: URL, timestamps: [Int64]) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240])
        input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 240, ty: 0)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        for timestamp in timestamps {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            try require(CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess, "Create blank frame")
            CVPixelBufferLockBaseAddress(buffer!, [])
            memset(CVPixelBufferGetBaseAddress(buffer!), 32, CVPixelBufferGetBytesPerRow(buffer!) * 240)
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            try require(adaptor.append(buffer!, withPresentationTime: CMTime(value: timestamp, timescale: 30)), "Append VFR frame")
        }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error! }
    }
}
