import AVFoundation
import Foundation

/// Recording receives the capture session's original video connection. Vision,
/// preview mirroring and skeleton overlays never enter the recorded movie.
protocol CameraMovieOutput: AnyObject {
    var isRecording: Bool { get }
    func startRecording(to outputFileURL: URL, recordingDelegate delegate: AVCaptureFileOutputRecordingDelegate)
    func stopRecording()
}

extension AVCaptureMovieFileOutput: CameraMovieOutput {}

/// All state and calls into the movie output live on the capture session queue.
/// The retained delegate keeps this recorder (and its session completion closure)
/// alive until AVFoundation has finalized the movie, including during shutdown.
final class CameraMovieRecorder: @unchecked Sendable {
    enum Event {
        case started, finishing
        case finished(URL?, String?)
    }
    private final class Recording {
        let id: UUID
        let url: URL
        let output: CameraMovieOutput
        let delegate: MovieDelegate
        let onEvent: @MainActor (Event) -> Void
        let onFinished: () -> Void
        var stopRequested = false
        var outputStopIssued = false
        var interruptionReason: String?

        init(id: UUID, url: URL, output: CameraMovieOutput, delegate: MovieDelegate,
             onEvent: @escaping @MainActor (Event) -> Void, onFinished: @escaping () -> Void) {
            self.id = id; self.url = url; self.output = output; self.delegate = delegate
            self.onEvent = onEvent; self.onFinished = onFinished
        }
    }

    private let queue: DispatchQueue
    private let directoryProvider: () throws -> URL
    private var recording: Recording?
    var isBusy: Bool { recording != nil }

    init(queue: DispatchQueue, directoryProvider: @escaping () throws -> URL = CameraMovieRecorder.pendingDirectory) {
        self.queue = queue; self.directoryProvider = directoryProvider
    }

    static func pendingDirectory() throws -> URL {
        let directory: URL
        if let override = ProcessInfo.processInfo.environment["HIDAN_RECORDING_DIR"] {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
            directory = support.appendingPathComponent("HidanClub/PendingRecordings", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func start(output: CameraMovieOutput, onEvent: @escaping @MainActor (Event) -> Void,
               onFinished: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard recording == nil else { return }
        do {
            let id = UUID()
            let url = try directoryProvider().appendingPathComponent("training-\(id.uuidString).mov")
            let delegate = MovieDelegate(onStart: { [self] in
                queue.async { [self] in didStart(id: id) }
            }, onFinish: { [self] error in
                queue.async { [self] in didFinish(id: id, error: error) }
            })
            recording = Recording(id: id, url: url, output: output, delegate: delegate,
                                  onEvent: onEvent, onFinished: onFinished)
            output.startRecording(to: url, recordingDelegate: delegate)
        } catch {
            emit(.finished(nil, "无法创建录像文件：\(error.localizedDescription)"), to: onEvent)
            onFinished()
        }
    }

    func stop(interruptionReason: String? = nil) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let recording else { return }
        if let interruptionReason { recording.interruptionReason = interruptionReason }
        if !recording.stopRequested {
            recording.stopRequested = true
            emit(.finishing, to: recording.onEvent)
        }
        stopOutputWhenReady(recording)
    }

    private func stopOutputWhenReady(_ recording: Recording) {
        // A user may stop immediately, before didStartRecording fires. Keep the
        // request until that callback; stopping an idle output would do nothing.
        if recording.output.isRecording, !recording.outputStopIssued {
            recording.outputStopIssued = true
            recording.output.stopRecording()
        }
    }

    private func didStart(id: UUID) {
        guard let recording, recording.id == id else { return }
        if recording.stopRequested { stopOutputWhenReady(recording) }
        else { emit(.started, to: recording.onEvent) }
    }

    private func didFinish(id: UUID, error: Error?) {
        guard let completed = recording, completed.id == id else { return }
        recording = nil
        let nsError = error as NSError?
        let successfullyFinished = nsError == nil ||
            (nsError?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? NSNumber)?.boolValue == true
        let attributes = try? FileManager.default.attributesOfItem(atPath: completed.url.path)
        let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let readable = FileManager.default.isReadableFile(atPath: completed.url.path) && bytes > 0
        if successfullyFinished && readable {
            var warning = completed.interruptionReason.map { "录像已保存，但提前结束：\($0)" } ??
                nsError.map { "录像已保存，但提前结束：\($0.localizedDescription)" }
            do {
                // Recovery must distinguish finalized movies from an in-progress
                // or interrupted file. Publish this marker atomically before
                // notifying the library; only successful readable files qualify.
                try Data("hidan-recording-ready-v1\n".utf8)
                    .write(to: completed.url.appendingPathExtension("ready"), options: .atomic)
            } catch {
                let markerWarning = "录像已保存，但恢复标记写入失败：\(error.localizedDescription)"
                warning = [warning, markerWarning].compactMap { $0 }.joined(separator: "；")
            }
            emit(.finished(completed.url, warning), to: completed.onEvent)
        } else {
            let reason = nsError?.localizedDescription ?? "没有收到可保存的视频帧"
            let recovery = bytes > 0 ? "；现有文件已保留在本机待恢复目录" : ""
            emit(.finished(nil, "录像保存失败：\(reason)\(recovery)"), to: completed.onEvent)
        }
        // Only now may the owner stop/remove capture outputs or release a session.
        completed.onFinished()
    }

    private func emit(_ event: Event, to callback: @escaping @MainActor (Event) -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { callback(event) } }
    }

    private final class MovieDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
        private let onStart: () -> Void
        private let onFinish: (Error?) -> Void
        init(onStart: @escaping () -> Void, onFinish: @escaping (Error?) -> Void) {
            self.onStart = onStart; self.onFinish = onFinish
        }
        func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                        from connections: [AVCaptureConnection]) { onStart() }
        func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                        from connections: [AVCaptureConnection], error: Error?) { onFinish(error) }
    }
}
