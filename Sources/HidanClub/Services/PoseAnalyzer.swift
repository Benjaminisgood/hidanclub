import AVFoundation
import Combine
import Foundation
import ImageIO
import Vision

/// Vision's normalized coordinates, in the upright image with a bottom-left origin.
/// A zero-confidence joint is retained as an invalid observation, never as a measurement.
struct PoseJoint: Codable, Sendable {
    let x: Double
    let y: Double
    let confidence: Double
}

struct PoseFrame: Codable, Sendable {
    let timestamp: Double
    let timestampValue: Int64
    let timestampTimescale: Int32
    let joints: [String: PoseJoint]
    let bodyCount: Int
    let ambiguous: Bool

    var hasDetectedBody: Bool {
        bodyCount == 1 && joints.values.contains { $0.confidence > 0 }
    }
}

struct PoseReport: Codable, Sendable {
    let sourceName: String
    let frames: [PoseFrame]
    let duration: Double
    let decodedFrameCount: Int
    let detectedFrameCount: Int
    /// Fraction of decoded frames containing one body with at least one valid joint.
    /// This is detection coverage, not dance quality or complete-skeleton coverage.
    let coverage: Double
    let createdAt: Date
    let coordinateSystem: String
    let modelName: String
    let modelRevision: Int

    var ambiguousFrameCount: Int { frames.filter(\.ambiguous).count }
}

@MainActor
final class PoseAnalyzer: ObservableObject {
    @Published private(set) var isAnalyzing = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var report: PoseReport?
    @Published private(set) var errorMessage: String?

    private var generation = UUID()
    private var worker: Task<PoseReport, Error>?
    private var completion: Task<Void, Never>?

    func analyze(url: URL) {
        cancel()
        report = nil
        errorMessage = nil
        progress = 0
        isAnalyzing = true

        let identifier = UUID()
        generation = identifier
        let progressHandler: @Sendable (Double) async -> Void = { [weak self] value in
            await self?.receiveProgress(value, generation: identifier)
        }
        let newWorker = Task.detached(priority: .userInitiated) {
            try await PoseVideoDecoder.analyze(url: url, onProgress: progressHandler)
        }
        worker = newWorker
        completion = Task { [weak self] in
            do {
                let result = try await newWorker.value
                guard let self, !Task.isCancelled, self.generation == identifier else { return }
                self.report = result
                self.progress = 1
                self.isAnalyzing = false
                self.worker = nil
                self.completion = nil
            } catch {
                guard let self, !Task.isCancelled, self.generation == identifier else { return }
                self.isAnalyzing = false
                self.progress = 0
                self.worker = nil
                self.completion = nil
                if !(error is CancellationError) {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancel() {
        generation = UUID()
        worker?.cancel()
        completion?.cancel()
        worker = nil
        completion = nil
        if isAnalyzing {
            isAnalyzing = false
            progress = 0
        }
    }

    func export(to url: URL) throws {
        guard let report else { throw PoseAnalysisError.noCompletedReport }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let scopedAccess = url.startAccessingSecurityScopedResource()
        defer { if scopedAccess { url.stopAccessingSecurityScopedResource() } }
        try encoder.encode(report).write(to: url, options: .atomic)
    }

    private func receiveProgress(_ value: Double, generation identifier: UUID) {
        guard generation == identifier, isAnalyzing else { return }
        progress = min(max(value, 0), 0.999)
    }

    deinit {
        worker?.cancel()
        completion?.cancel()
    }
}

enum PoseAnalysisError: LocalizedError {
    case noVideoTrack
    case invalidDuration
    case unsupportedTransform
    case readerUnavailable
    case missingPixelBuffer
    case invalidTimestamp
    case invalidJoint
    case noFrames
    case incompleteRead(String)
    case noCompletedReport

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "这个文件没有可读取的视频轨道。"
        case .invalidDuration: return "视频时长无效，无法完成全帧分析。"
        case .unsupportedTransform: return "视频使用了不支持的旋转或变形；请导出为标准方向的视频后再分析。"
        case .readerUnavailable: return "无法创建视频解码输出，请检查文件格式及读取权限。"
        case .missingPixelBuffer: return "一个视频帧未能解码为图像，分析已停止，没有输出部分报告。"
        case .invalidTimestamp: return "视频包含无效或逆序的时间戳，分析已停止。"
        case .invalidJoint: return "人体检测返回无效坐标，分析已停止。"
        case .noFrames: return "视频没有可解码的图像帧。"
        case .incompleteRead(let reason): return "视频未能完整读取：\(reason)"
        case .noCompletedReport: return "请先完成一次视频分析，再导出完整报告。"
        }
    }
}

/// Runs only in a detached task. No frame-rate conversion, subsampling, interpolation,
/// image-size cap, or live-preview frame-dropping is used in this analysis path.
enum PoseVideoDecoder {
    static func analyze(
        url: URL,
        onProgress: @escaping @Sendable (Double) async -> Void
    ) async throws -> PoseReport {
        let scopedAccess = url.startAccessingSecurityScopedResource()
        defer { if scopedAccess { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()

        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PoseAnalysisError.noVideoTrack
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw PoseAnalysisError.invalidDuration }
        let transform = try await track.load(.preferredTransform)
        let orientation = try imageOrientation(for: transform)
        try Task.checkCancellation()

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw PoseAnalysisError.readerUnavailable }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? PoseAnalysisError.readerUnavailable
        }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let request = VNDetectHumanBodyPoseRequest()
        request.revision = VNDetectHumanBodyPoseRequestRevision1
        var frames: [PoseFrame] = []
        var detectedCount = 0
        var lastTimestamp: Double?
        var lastProgressUpdate = Date.distantPast

        while true {
            try Task.checkCancellation()
            let frame: PoseFrame? = try autoreleasepool {
                guard let sample = output.copyNextSampleBuffer() else { return nil }
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                    throw PoseAnalysisError.missingPixelBuffer
                }
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                let timestamp = time.seconds
                guard time.isNumeric, time.timescale > 0, timestamp.isFinite,
                      lastTimestamp.map({ timestamp >= $0 }) ?? true else {
                    throw PoseAnalysisError.invalidTimestamp
                }
                let handler = VNImageRequestHandler(
                    cvPixelBuffer: pixelBuffer,
                    orientation: orientation,
                    options: [:]
                )
                try handler.perform([request])
                let observations = request.results ?? []
                var joints: [String: PoseJoint] = [:]
                if observations.count == 1, let observation = observations.first {
                    for (name, point) in try observation.recognizedPoints(.all) {
                        let x = Double(point.location.x)
                        let y = Double(point.location.y)
                        let confidence = Double(point.confidence)
                        guard x.isFinite, y.isFinite, confidence.isFinite else {
                            throw PoseAnalysisError.invalidJoint
                        }
                        joints[jointKey(name)] = PoseJoint(x: x, y: y, confidence: confidence)
                    }
                }
                return PoseFrame(
                    timestamp: timestamp,
                    timestampValue: time.value,
                    timestampTimescale: time.timescale,
                    joints: joints,
                    bodyCount: observations.count,
                    ambiguous: observations.count > 1
                )
            }
            guard let frame else { break }
            try Task.checkCancellation()
            frames.append(frame)
            if frame.hasDetectedBody { detectedCount += 1 }
            lastTimestamp = frame.timestamp

            // Throttle UI messages by wall time only. Every decoded frame is retained.
            let now = Date()
            if now.timeIntervalSince(lastProgressUpdate) >= 0.1 {
                lastProgressUpdate = now
                await onProgress(frame.timestamp / duration)
            }
        }
        try Task.checkCancellation()
        guard reader.status == .completed else {
            throw PoseAnalysisError.incompleteRead(reader.error?.localizedDescription ?? "读取未完成")
        }
        guard !frames.isEmpty else { throw PoseAnalysisError.noFrames }

        return PoseReport(
            sourceName: url.lastPathComponent,
            frames: frames,
            duration: duration,
            decodedFrameCount: frames.count,
            detectedFrameCount: detectedCount,
            coverage: Double(detectedCount) / Double(frames.count),
            createdAt: Date(),
            coordinateSystem: "upright-image-normalized-bottom-left; original-presentation-timestamps",
            modelName: "VNDetectHumanBodyPoseRequest",
            modelRevision: request.revision
        )
    }

    /// Maps the eight standard rotation/mirror transforms to EXIF image orientation.
    /// Translation is irrelevant to normalized pose coordinates. Arbitrary skew or
    /// non-orthogonal rotation is rejected instead of producing a misaligned skeleton.
    static func imageOrientation(for transform: CGAffineTransform) throws -> CGImagePropertyOrientation {
        let horizontalScale = hypot(transform.a, transform.b)
        let verticalScale = hypot(transform.c, transform.d)
        guard horizontalScale.isFinite, verticalScale.isFinite,
              horizontalScale > 0, verticalScale > 0 else {
            throw PoseAnalysisError.unsupportedTransform
        }
        let values = [transform.a / horizontalScale, transform.b / horizontalScale,
                      transform.c / verticalScale, transform.d / verticalScale]
        let candidates: [([CGFloat], CGImagePropertyOrientation)] = [
            ([1, 0, 0, 1], .up),
            ([-1, 0, 0, 1], .upMirrored),
            ([-1, 0, 0, -1], .down),
            ([1, 0, 0, -1], .downMirrored),
            ([0, 1, 1, 0], .leftMirrored),
            ([0, 1, -1, 0], .right),
            ([0, -1, -1, 0], .rightMirrored),
            ([0, -1, 1, 0], .left)
        ]
        for (candidate, orientation) in candidates {
            if zip(values, candidate).allSatisfy({ abs($0.0 - $0.1) < 0.0001 }) {
                return orientation
            }
        }
        throw PoseAnalysisError.unsupportedTransform
    }

    /// Readable stable names for UI and exported data; coordinates/confidence are unchanged.
    static func jointKey(_ name: VNHumanBodyPoseObservation.JointName) -> String {
        let names: [VNHumanBodyPoseObservation.JointName: String] = [
            .nose: "nose", .leftEye: "leftEye", .rightEye: "rightEye",
            .leftEar: "leftEar", .rightEar: "rightEar", .neck: "neck", .root: "root",
            .leftShoulder: "leftShoulder", .leftElbow: "leftElbow", .leftWrist: "leftWrist",
            .rightShoulder: "rightShoulder", .rightElbow: "rightElbow", .rightWrist: "rightWrist",
            .leftHip: "leftHip", .leftKnee: "leftKnee", .leftAnkle: "leftAnkle",
            .rightHip: "rightHip", .rightKnee: "rightKnee", .rightAnkle: "rightAnkle"
        ]
        return names[name] ?? name.rawValue.rawValue
    }
}
