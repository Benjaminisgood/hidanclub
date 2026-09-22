import AVFoundation
import Foundation

/// Delegate-driven fake: it never creates/starts a capture session, discovers a
/// camera or requests permission. File bytes exercise handoff ownership only;
/// this probe does not claim that a real device encoded a playable movie.
private final class FakeMovieOutput: CameraMovieOutput {
    var isRecording = false
    var startCalls = 0
    var stopCalls = 0
    var url: URL!
    weak var delegate: AVCaptureFileOutputRecordingDelegate?
    private let callbackOutput = AVCaptureMovieFileOutput()
    func startRecording(to outputFileURL: URL, recordingDelegate delegate: AVCaptureFileOutputRecordingDelegate) {
        startCalls += 1; url = outputFileURL; self.delegate = delegate
    }
    func stopRecording() { stopCalls += 1 }
    func sendStarted() {
        isRecording = true
        delegate?.fileOutput?(callbackOutput, didStartRecordingTo: url, from: [])
    }
    func sendFinished(error: Error? = nil, writeBytes: Bool = true) throws {
        if writeBytes { try Data("synthetic finalized output".utf8).write(to: url) }
        isRecording = false
        delegate?.fileOutput(callbackOutput, didFinishRecordingTo: url, from: [], error: error)
    }
}

@main private struct CameraRecordingProbe {
    struct Failure: Error { let message: String }
    @MainActor final class Events {
        var order: [String] = []
        var saved: URL?
        var error: String?
        var validMarkerAtSave = false
        func record(_ event: CameraMovieRecorder.Event) {
            switch event {
            case .started: order.append("started")
            case .finishing: order.append("finishing")
            case .finished(let url, let error):
                saved = url; self.error = error; order.append("finished")
                if let url {
                    validMarkerAtSave = (try? String(contentsOf: url.appendingPathExtension("ready"), encoding: .utf8)) == "hidan-recording-ready-v1\n"
                }
            }
        }
    }
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    @MainActor static func flush(_ queue: DispatchQueue) async {
        queue.sync {}
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
    @MainActor static func main() async throws {
        guard let override = ProcessInfo.processInfo.environment["HIDAN_RECORDING_DIR"] else {
            throw Failure(message: "QA requires HIDAN_RECORDING_DIR to avoid the user's recording directory")
        }
        let overriddenDirectory = try CameraMovieRecorder.pendingDirectory()
        try check(overriddenDirectory.standardizedFileURL == URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL,
                  "Pending recording directory ignored the isolated environment override")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hidan-recording-qa-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = DispatchQueue(label: "club.hidan.recording.qa")
        var recorder: CameraMovieRecorder? = CameraMovieRecorder(queue: queue, directoryProvider: { directory })
        let events = Events(), output = FakeMovieOutput()
        queue.sync {
            recorder!.start(output: output, onEvent: events.record, onFinished: {
                DispatchQueue.main.async { events.order.append("shutdown completion") }
            })
            recorder!.start(output: output, onEvent: events.record, onFinished: {})
            recorder!.stop()
            recorder!.stop()
        }
        await flush(queue)
        try check(output.startCalls == 1 && output.stopCalls == 0, "Immediate stop must wait for output readiness; duplicate start must be ignored")
        try check(events.order == ["finishing"], "Finalization should be visible while output start is pending")
        try check(!FileManager.default.fileExists(atPath: output.url.appendingPathExtension("ready").path), "A pending take must not have a completion marker")
        output.sendStarted()
        await flush(queue)
        try check(output.stopCalls == 1, "Pending stop was not issued exactly once after output became ready")
        queue.sync { recorder!.stop() }
        try check(output.stopCalls == 1 && events.saved == nil, "Repeated stop duplicated stop or handed off an unfinished movie")
        try check(!FileManager.default.fileExists(atPath: output.url.appendingPathExtension("ready").path), "An active/finalizing take must not have a completion marker")
        weak let lifetime = recorder
        recorder = nil
        try check(lifetime != nil && output.delegate != nil, "Recorder/delegate must survive the host releasing its reference while saving")
        try output.sendFinished()
        await flush(queue)
        try check(events.saved == output.url && events.error == nil, "A successful movie was not handed off")
        try check(events.validMarkerAtSave, "Success callback preceded the atomic versioned ready marker")
        try check(events.order == ["finishing", "finished", "shutdown completion"], "Save notification must precede main-queue termination completion")
        try check(lifetime == nil && output.delegate == nil, "Completed recording retained its delegate/recorder cycle")

        let failures = [
            NSError(domain: AVFoundationErrorDomain, code: -1, userInfo: [NSLocalizedDescriptionKey: "synthetic disconnection"]),
            NSError(domain: AVFoundationErrorDomain, code: -2, userInfo: [
                NSLocalizedDescriptionKey: "synthetic storage boundary", AVErrorRecordingSuccessfullyFinishedKey: true
            ])
        ]
        for (index, failure) in failures.enumerated() {
            let source = FakeMovieOutput(), result = Events()
            let current = CameraMovieRecorder(queue: queue, directoryProvider: { directory })
            queue.sync { current.start(output: source, onEvent: result.record, onFinished: {}) }
            source.sendStarted()
            await flush(queue)
            queue.sync { current.stop(interruptionReason: "相机断开") }
            try source.sendFinished(error: failure)
            await flush(queue)
            try check(result.saved == (index == 1 ? source.url : nil), "Successfully-finished AVFoundation errors must preserve a valid partial movie; failures must not import")
            try check(result.error != nil && FileManager.default.isReadableFile(atPath: source.url.path), "Interrupted output or recovery file was lost")
            try check(FileManager.default.fileExists(atPath: source.url.appendingPathExtension("ready").path) == (index == 1),
                      "Failed output received a ready marker, or a successfully finalized partial output did not")
            try check(queue.sync { !current.isBusy }, "Recorder remained busy after a terminal error")
        }
        let empty = FakeMovieOutput(), emptyEvents = Events()
        let reused = CameraMovieRecorder(queue: queue, directoryProvider: { directory })
        queue.sync { reused.start(output: empty, onEvent: emptyEvents.record, onFinished: {}) }
        try empty.sendFinished(writeBytes: false)
        await flush(queue)
        try check(emptyEvents.saved == nil && emptyEvents.error != nil, "Missing/empty output must not enter the video library")
        try check(!FileManager.default.fileExists(atPath: empty.url.appendingPathExtension("ready").path), "Missing/empty output must not receive a ready marker")
        let second = FakeMovieOutput(), secondEvents = Events()
        queue.sync { reused.start(output: second, onEvent: secondEvents.record, onFinished: {}) }
        try second.sendFinished()
        await flush(queue)
        try check(secondEvents.saved != nil && second.url != empty.url, "A failed take prevented restart or reused its original URL")

        let markerBlocked = FakeMovieOutput(), markerEvents = Events()
        queue.sync { reused.start(output: markerBlocked, onEvent: markerEvents.record, onFinished: {
            DispatchQueue.main.async { markerEvents.order.append("shutdown completion") }
        }) }
        let markerPath = markerBlocked.url.appendingPathExtension("ready")
        try FileManager.default.createDirectory(at: markerPath, withIntermediateDirectories: true)
        try Data("do not replace".utf8).write(to: markerPath.appendingPathComponent("blocker"))
        try markerBlocked.sendFinished()
        await flush(queue)
        try check(markerEvents.saved == markerBlocked.url && markerEvents.error?.contains("恢复标记写入失败") == true,
                  "Marker write failure must warn while still handing off the finalized video")
        try check(!markerEvents.validMarkerAtSave && FileManager.default.isReadableFile(atPath: markerBlocked.url.path),
                  "Marker failure destroyed the original movie or fabricated a valid completion marker")
        try check(markerEvents.order == ["finished", "shutdown completion"], "Marker failure reordered save and shutdown callbacks")

        let failingDirectory = CameraMovieRecorder(queue: queue, directoryProvider: { throw Failure(message: "unwritable directory") })
        let noStart = FakeMovieOutput(), pathEvents = Events()
        queue.sync { failingDirectory.start(output: noStart, onEvent: pathEvents.record, onFinished: {}) }
        await flush(queue)
        try check(noStart.startCalls == 0 && pathEvents.error != nil && !queue.sync { failingDirectory.isBusy }, "Filesystem failure must be surfaced before touching the recording output")
        print("PASS: explicit start, duplicate start/stop, stop before didStart, save-before-termination ordering, delegate/recorder retention and release, interrupted partial output, failed/empty output refusal, retained recovery files, unique URLs, restart, filesystem failure; isolated recording directory; versioned ready markers only after successful finalization and before callbacks; marker-write failure preserves direct import and shutdown ordering. No camera/session activation or microphone access.")
    }
}
