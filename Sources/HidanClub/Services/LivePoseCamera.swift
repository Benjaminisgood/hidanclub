import AVFoundation
import AppKit
import CoreImage
import Foundation
import HidanCore
import ImageIO
import Vision

struct LivePoseCameraStatistics {
    var captured = 0
    var analyzed = 0
    var analysisErrors = 0
    var systemDropped = 0
    var lastProcessingMilliseconds = 0.0
    var captureFramesPerSecond = 0.0
    var formatDescription = ""
    var lastDropReason: String?
}

struct LivePoseCameraSnapshot {
    let image: CGImage?
    let observation: LivePoseObservation
}

/// High-frequency frame publications are separate from camera lifecycle state.
/// Only the preview/feedback views observe this object, avoiding a whole training
/// screen rebuild on every captured frame.
@MainActor
final class LivePoseCameraFrames: ObservableObject {
    struct Value {
        var snapshot: LivePoseCameraSnapshot?
        var statistics = LivePoseCameraStatistics()
    }
    @Published private(set) var value = Value()
    var snapshot: LivePoseCameraSnapshot? { value.snapshot }
    var statistics: LivePoseCameraStatistics { value.statistics }
    fileprivate func reset() { value = Value() }
    fileprivate func clearImage() { value = Value(snapshot: nil, statistics: value.statistics) }
    fileprivate func publish(_ snapshot: LivePoseCameraSnapshot, statistics: LivePoseCameraStatistics) {
        value = Value(snapshot: snapshot, statistics: statistics)
    }
    fileprivate func publishStatistics(_ statistics: LivePoseCameraStatistics) {
        value = Value(snapshot: value.snapshot, statistics: statistics)
    }
}

@MainActor
final class LivePoseCamera: ObservableObject {
    enum State: Equatable {
        case off, requestingPermission, starting, running
        case denied, unavailable(String), failed(String)
    }
    enum RecordingState: Equatable { case idle, starting, recording, finishing }
    @Published private(set) var state: State = .off
    @Published private(set) var recordingState: RecordingState = .idle
    @Published private(set) var recordingError: String?
    /// Set by the app's long-lived video library host. The movie is finalized,
    /// locally readable and retained in PendingRecordings until it is imported.
    var onRecordingSaved: ((URL) -> Void)?
    let frames = LivePoseCameraFrames()
    var snapshot: LivePoseCameraSnapshot? { frames.snapshot }
    var statistics: LivePoseCameraStatistics { frames.statistics }
    @Published var mirrored = true
    private let engine: LivePoseCaptureEngine
    private let authorizationStatus: () -> AVAuthorizationStatus
    private let requestAccess: (@escaping @Sendable (Bool) -> Void) -> Void
    private var generation = UUID()
    var isRunning: Bool { state == .running }
    var isBusy: Bool { state == .requestingPermission || state == .starting }
    var isRecording: Bool { recordingState == .starting || recordingState == .recording }
    var isFinishingRecording: Bool { recordingState == .finishing }
    var aspectRatio: CGFloat {
        guard let observation = snapshot?.observation, observation.height > 0 else { return 16 / 9 }
        return CGFloat(observation.width) / CGFloat(observation.height)
    }
    var feedback: LivePoseFeedback? { snapshot.map { LivePoseFeedback(observation: $0.observation) } }
    var statusText: String {
        switch state {
        case .off: return "摄像头未开启"
        case .requestingPermission: return "等待系统相机授权"
        case .starting: return "正在连接摄像头"
        case .running: return "本机实时检测"
        case .denied: return "相机权限未开启"
        case .unavailable(let message), .failed(let message): return message
        }
    }

    convenience init() {
        self.init(authorizationStatus: { AVCaptureDevice.authorizationStatus(for: .video) },
                  requestAccess: { AVCaptureDevice.requestAccess(for: .video, completionHandler: $0) },
                  deviceProvider: { AVCaptureDevice.default(for: .video) })
    }

    /// Dependency injection stays file-private; the standalone merged-source QA
    /// can exercise denied/no-device paths without touching system permissions.
    fileprivate init(authorizationStatus: @escaping () -> AVAuthorizationStatus,
                     requestAccess: @escaping (@escaping @Sendable (Bool) -> Void) -> Void,
                     deviceProvider: @escaping () -> AVCaptureDevice?) {
        self.authorizationStatus = authorizationStatus
        self.requestAccess = requestAccess
        engine = LivePoseCaptureEngine(deviceProvider: deviceProvider)
    }

    /// Call only in response to the user's explicit camera-enable action.
    func start() {
        guard !isRunning, !isBusy, recordingState == .idle else { return }
        generation = UUID()
        let token = generation
        frames.reset()
        switch authorizationStatus() {
        case .authorized: begin(token: token)
        case .notDetermined:
            state = .requestingPermission
            requestAccess { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    if granted { self.begin(token: token) } else { self.state = .denied }
                }
            }
        case .denied, .restricted: state = .denied
        @unknown default: state = .denied
        }
    }

    /// The host also calls this when leaving training, on sleep and before quit.
    /// Preview pixels are cleared immediately; capture shutdown never blocks UI.
    func stop() {
        prepareForStop()
        engine.stop()
    }

    /// App termination uses this completion to wait for movie finalization.
    /// onRecordingSaved is delivered on the main queue before completion.
    func stop(completion: @escaping () -> Void) {
        prepareForStop()
        engine.stop(completion: completion)
    }

    private func prepareForStop() {
        generation = UUID()
        if isRecording { recordingState = .finishing }
        state = .off
        frames.clearImage()
    }

    /// Camera permission/activation and movie recording are separate explicit
    /// actions. This never enables a camera or requests microphone access.
    func startRecording() {
        guard isRunning, recordingState == .idle else { return }
        recordingError = nil
        recordingState = .starting
        engine.startRecording(token: generation) { [weak self] event in
            guard let self else { return }
            switch event {
            case .started:
                if self.recordingState == .starting { self.recordingState = .recording }
            case .finishing: self.recordingState = .finishing
            case .finished(let url, let error):
                self.recordingState = .idle
                self.recordingError = error
                if let url { self.onRecordingSaved?(url) }
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        recordingState = .finishing
        engine.stopRecording()
    }

    private func begin(token: UUID) {
        state = .starting
        engine.start(token: token, onState: { [weak self] event in
            guard let self, self.generation == token else { return }
            switch event {
            case .ready: self.state = .running
            case .unavailable(let message): self.state = .unavailable(message); self.frames.clearImage()
            case .failed(let message): self.state = .failed(message); self.frames.clearImage()
            }
        }, onFrame: { [weak self] snapshot, statistics in
            guard let self, self.generation == token else { return }
            self.frames.publish(snapshot, statistics: statistics)
            if self.state != .running { self.state = .running }
        }, onStatistics: { [weak self] statistics in
            guard let self, self.generation == token else { return }
            self.frames.publishStatistics(statistics)
        })
    }

    deinit { engine.stop() }
}

/// The capture session and configuration are owned by one serial queue. Vision
/// runs synchronously on a separate serial delegate queue, once per delivered
/// buffer. UI delivery blocks that delegate until the matching image/pose packet
/// is consumed, so this implementation cannot accumulate unbounded frame tasks.
private final class LivePoseCaptureEngine: @unchecked Sendable {
    enum Event { case ready, unavailable(String), failed(String) }
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "club.hidan.camera.session", qos: .userInitiated)
    private let captureQueue = DispatchQueue(label: "club.hidan.camera.frames", qos: .userInitiated)
    private let lock = NSLock()
    private let deviceProvider: () -> AVCaptureDevice?
    private var activeToken: UUID?
    private var acceptingFrames = false
    private var output: AVCaptureVideoDataOutput?
    private var movieOutput: AVCaptureMovieFileOutput?
    private lazy var recorder = CameraMovieRecorder(queue: sessionQueue)
    private var shutdownAfterRecording = false
    private var stopCompletions: [@MainActor () -> Void] = []
    private var pipeline: LivePoseCapturePipeline?
    private var observers: [NSObjectProtocol] = []

    init(deviceProvider: @escaping () -> AVCaptureDevice?) { self.deviceProvider = deviceProvider }

    func start(token: UUID, onState: @escaping @MainActor (Event) -> Void,
               onFrame: @escaping @MainActor (LivePoseCameraSnapshot, LivePoseCameraStatistics) -> Void,
               onStatistics: @escaping @MainActor (LivePoseCameraStatistics) -> Void) {
        lock.lock(); activeToken = token; acceptingFrames = true; lock.unlock()
        sessionQueue.async { [weak self] in
            guard let self, self.isActive(token) else { return }
            guard !self.recorder.isBusy else {
                self.report(.unavailable("正在保存上一段录像，请稍后启用摄像头"), token: token, callback: onState)
                return
            }
            self.shutdownSession()
            guard self.isActive(token) else { return }
            guard let device = self.deviceProvider(), device.isConnected else {
                self.report(.unavailable("未找到可用摄像头"), token: token, callback: onState); return
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                self.session.beginConfiguration()
                self.session.inputs.forEach { self.session.removeInput($0) }
                self.session.outputs.forEach { self.session.removeOutput($0) }
                guard self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    self.report(.unavailable("此摄像头暂不可用于采集"), token: token, callback: onState); return
                }
                self.session.addInput(input)
                // Keep the device's current native format and negotiated frame
                // duration. No resolution cap, explicit resizing, FPS reduction,
                // nth-frame selection or delegate throttling is applied.
                let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                let format = "\(dimensions.width) × \(dimensions.height) · 相机协商格式"
                let output = AVCaptureVideoDataOutput()
                // On macOS a nil settings dictionary follows the session's
                // preset; explicitly request the current full image dimensions.
                output.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: Int(dimensions.width),
                    kCVPixelBufferHeightKey as String: Int(dimensions.height)
                ]
                output.alwaysDiscardsLateVideoFrames = false
                guard self.session.canAddOutput(output) else {
                    self.session.commitConfiguration()
                    self.report(.unavailable("摄像头不支持视频帧输出"), token: token, callback: onState); return
                }
                self.session.addOutput(output)
                if let connection = output.connection(with: .video) {
                    connection.automaticallyAdjustsVideoMirroring = false
                    if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
                    if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
                }
                // AVFoundation writes every frame delivered to this native
                // video connection. No audio input, resizing, FPS override or
                // preview/Vision overlay is part of the movie connection.
                let movieOutput = AVCaptureMovieFileOutput()
                if self.session.canAddOutput(movieOutput) {
                    self.session.addOutput(movieOutput)
                    movieOutput.connection(with: .audio)?.isEnabled = false
                    if let connection = movieOutput.connection(with: .video) {
                        movieOutput.setOutputSettings([
                            AVVideoCodecKey: AVVideoCodecType.h264,
                            AVVideoWidthKey: Int(dimensions.width),
                            AVVideoHeightKey: Int(dimensions.height)
                        ], for: connection)
                        connection.automaticallyAdjustsVideoMirroring = false
                        if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
                        if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
                    }
                    self.movieOutput = movieOutput
                }
                let pipeline = LivePoseCapturePipeline(
                    format: format, isActive: { [weak self] in self?.canDeliverFrames(token) == true },
                    onFrame: onFrame, onStatistics: onStatistics
                )
                output.setSampleBufferDelegate(pipeline, queue: self.captureQueue)
                self.output = output; self.pipeline = pipeline
                self.session.commitConfiguration()
                self.installObservers(token: token, device: device, callback: onState)
                guard self.isActive(token) else { self.shutdownSession(); return }
                self.session.startRunning()
                if self.session.isRunning { self.report(.ready, token: token, callback: onState) }
                else { self.report(.failed("摄像头未能启动，请检查是否被其他应用占用"), token: token, callback: onState) }
            } catch {
                self.shutdownSession()
                self.report(.failed("摄像头启动失败：\(error.localizedDescription)"), token: token, callback: onState)
            }
        }
    }

    func stop(completion: (@MainActor () -> Void)? = nil) {
        lock.lock(); activeToken = nil; acceptingFrames = false; lock.unlock()
        // Strong capture also carries camera deinitialization through shutdown.
        sessionQueue.async { [self] in
            if let completion { stopCompletions.append(completion) }
            stopSessionAfterSaving()
        }
    }

    func startRecording(token: UUID, onEvent: @escaping @MainActor (CameraMovieRecorder.Event) -> Void) {
        sessionQueue.async { [self] in
            guard isActive(token), session.isRunning, !shutdownAfterRecording else {
                DispatchQueue.main.async { onEvent(.finished(nil, "摄像头已停用，未开始录像")) }
                return
            }
            guard let movieOutput, movieOutput.connection(with: .video)?.isEnabled == true else {
                DispatchQueue.main.async { onEvent(.finished(nil, "此摄像头当前不支持录像，请重新连接后重试")) }
                return
            }
            recorder.start(output: movieOutput, onEvent: onEvent, onFinished: { [self] in
                if shutdownAfterRecording { shutdownSession() }
            })
        }
    }

    func stopRecording() {
        sessionQueue.async { [self] in recorder.stop() }
    }

    private func stopSessionAfterSaving(interruptionReason: String? = nil) {
        if recorder.isBusy {
            shutdownAfterRecording = true
            recorder.stop(interruptionReason: interruptionReason)
        } else { shutdownSession() }
    }

    private func isActive(_ token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return activeToken == token
    }
    private func canDeliverFrames(_ token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return activeToken == token && acceptingFrames
    }
    private func shutdownSession() {
        // A movie's final delegate callback must arrive before stopRunning.
        guard !recorder.isBusy else { stopSessionAfterSaving(); return }
        output?.setSampleBufferDelegate(nil, queue: nil)
        if session.isRunning { session.stopRunning() }
        output = nil; movieOutput = nil; pipeline = nil; shutdownAfterRecording = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        let completions = stopCompletions
        stopCompletions.removeAll()
        if !completions.isEmpty {
            DispatchQueue.main.async { completions.forEach { $0() } }
        }
    }
    private func report(_ event: Event, token: UUID, callback: @escaping @MainActor (Event) -> Void) {
        if case .ready = event {} else {
            lock.lock(); if activeToken == token { acceptingFrames = false }; lock.unlock()
        }
        DispatchQueue.main.async { [weak self] in
            guard self?.isActive(token) == true else { return }
            MainActor.assumeIsolated { callback(event) }
        }
    }
    private func installObservers(token: UUID, device: AVCaptureDevice, callback: @escaping @MainActor (Event) -> Void) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self?.runtimeFailure("相机运行中断：\(error?.localizedDescription ?? "请重新启用摄像头")", token: token, callback: callback)
        })
        observers.append(center.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: device, queue: nil) { [weak self] _ in
            self?.runtimeFailure("摄像头已断开，请连接后重新启用", token: token, callback: callback)
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { [weak self] _ in
            self?.runtimeFailure("摄像头被系统暂停，请稍后重新启用", token: token, callback: callback)
        })
    }
    private func runtimeFailure(_ message: String, token: UUID, callback: @escaping @MainActor (Event) -> Void) {
        guard isActive(token) else { return }
        lock.lock(); if activeToken == token { acceptingFrames = false }; lock.unlock()
        // Shutdown runs on the session queue, never on the blocked frame delegate.
        sessionQueue.async { [weak self] in
            guard let self, self.isActive(token) else { return }
            self.stopSessionAfterSaving(interruptionReason: message)
            self.report(.failed(message), token: token, callback: callback)
        }
    }
}

// Mutable statistics and Vision state are confined to the one delegate queue.
private final class LivePoseCapturePipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let request = VNDetectHumanBodyPoseRequest()
    private let isActive: () -> Bool
    private let onFrame: @MainActor (LivePoseCameraSnapshot, LivePoseCameraStatistics) -> Void
    private let onStatistics: @MainActor (LivePoseCameraStatistics) -> Void
    private var statistics = LivePoseCameraStatistics()
    private var firstTimestamp: Double?
    private static let jointNames: [(String, VNHumanBodyPoseObservation.JointName)] = [
        ("nose", .nose), ("leftEye", .leftEye), ("rightEye", .rightEye),
        ("leftEar", .leftEar), ("rightEar", .rightEar), ("neck", .neck), ("root", .root),
        ("leftShoulder", .leftShoulder), ("rightShoulder", .rightShoulder),
        ("leftElbow", .leftElbow), ("rightElbow", .rightElbow),
        ("leftWrist", .leftWrist), ("rightWrist", .rightWrist),
        ("leftHip", .leftHip), ("rightHip", .rightHip),
        ("leftKnee", .leftKnee), ("rightKnee", .rightKnee),
        ("leftAnkle", .leftAnkle), ("rightAnkle", .rightAnkle)
    ]
    init(format: String, isActive: @escaping () -> Bool,
         onFrame: @escaping @MainActor (LivePoseCameraSnapshot, LivePoseCameraStatistics) -> Void,
         onStatistics: @escaping @MainActor (LivePoseCameraStatistics) -> Void) {
        self.isActive = isActive; self.onFrame = onFrame; self.onStatistics = onStatistics
        statistics.formatDescription = format
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        process(sampleBuffer)
    }

    /// A supplied sample buffer also allows synthetic, permission-free QA of the
    /// exact production decoder. The capture delegate performs no other filtering.
    func process(_ sampleBuffer: CMSampleBuffer) {
        guard isActive() else { return }
        autoreleasepool {
            statistics.captured += 1
            let start = CFAbsoluteTimeGetCurrent()
            let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            if firstTimestamp == nil, timestamp.isFinite { firstTimestamp = timestamp }
            if let firstTimestamp, timestamp > firstTimestamp {
                statistics.captureFramesPerSecond = Double(statistics.captured - 1) / (timestamp - firstTimestamp)
            }
            var image: CGImage?
            var joints: [String: LivePosePoint] = [:]
            var bodyCount = 0
            var failure: String?
            var width = 0, height = 0
            if let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                width = CVPixelBufferGetWidth(buffer); height = CVPixelBufferGetHeight(buffer)
                statistics.formatDescription = "\(width) × \(height) · 相机协商格式"
                let input = CIImage(cvPixelBuffer: buffer)
                image = context.createCGImage(input, from: input.extent)
                do {
                    try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:]).perform([request])
                    let bodies = request.results ?? []
                    bodyCount = bodies.count
                    if bodies.count == 1 {
                        let values = try bodies[0].recognizedPoints(.all)
                        for (name, key) in Self.jointNames {
                            if let point = values[key] {
                                joints[name] = LivePosePoint(x: point.location.x, y: point.location.y, confidence: Double(point.confidence))
                            }
                        }
                    }
                    statistics.analyzed += 1
                } catch { failure = error.localizedDescription; statistics.analysisErrors += 1 }
            } else {
                failure = "相机帧没有可读图像缓冲区"; statistics.analysisErrors += 1
            }
            statistics.lastProcessingMilliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000
            let observation = LivePoseObservation(frameNumber: statistics.captured, timestamp: timestamp,
                                                 width: width, height: height, bodyCount: bodyCount, joints: joints, error: failure)
            let snapshot = LivePoseCameraSnapshot(image: image, observation: observation)
            let counters = statistics
            guard isActive() else { return }
            // Bounded, synchronous handoff: at most the current image/pose packet
            // waits for UI. Never queue one Task or async image operation per frame.
            DispatchQueue.main.sync {
                guard self.isActive() else { return }
                MainActor.assumeIsolated { self.onFrame(snapshot, counters) }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        recordSystemDrop(sampleBuffer)
    }

    func recordSystemDrop(_ sampleBuffer: CMSampleBuffer) {
        guard isActive() else { return }
        statistics.systemDropped += 1
        statistics.lastDropReason = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil) as? String
        let counters = statistics
        DispatchQueue.main.sync {
            guard self.isActive() else { return }
            MainActor.assumeIsolated { self.onStatistics(counters) }
        }
    }
}
