// Standalone regression probe for full-frame pose analysis. Run from the project root:
// swiftc -swift-version 5 -target arm64-apple-macosx14.0 -o /tmp/hidan_pose_probe Sources/HidanClub/Services/PoseAnalyzer.swift script/qa_pose_probe.swift
// /tmp/hidan_pose_probe
// Requires macOS 14+ and Apple command-line developer tools. For an Intel Mac,
// substitute x86_64-apple-macosx14.0 for the target above.
// Generates its own blank VFR video; downloads no media and requests no camera access.
// Tests decoder/state/export contracts. It does not validate dance pose accuracy.

import AVFoundation
import Foundation
import ImageIO

@main
struct Probe {
    @MainActor
    static func main() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hidan-pose-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clip = directory.appendingPathComponent("vfr-blank.mov")
        let timestamps: [Int64] = [0, 1, 3, 4, 7, 8, 12, 15]
        try await makeVideo(at: clip, timestamps: timestamps)
        let report = try await PoseVideoDecoder.analyze(url: clip, onProgress: { _ in })
        precondition(report.decodedFrameCount == timestamps.count)
        precondition(report.frames.count == timestamps.count)
        precondition(report.detectedFrameCount == 0 && report.coverage == 0)
        precondition(report.frames.allSatisfy { $0.joints.isEmpty && $0.bodyCount == 0 && !$0.ambiguous })
        for (frame, expected) in zip(report.frames, timestamps) {
            precondition(abs(frame.timestamp - Double(expected) / 30) < 0.000001)
            precondition(abs(Double(frame.timestampValue) / Double(frame.timestampTimescale) - frame.timestamp) < 0.000001)
        }
        let transforms: [(CGAffineTransform, CGImagePropertyOrientation)] = [
            (.identity, .up),
            (CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 320, ty: 0), .upMirrored),
            (CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 320, ty: 240), .down),
            (CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 240), .downMirrored),
            (CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0), .leftMirrored),
            (CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 240, ty: 0), .right),
            (CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: 240, ty: 320), .rightMirrored),
            (CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 320), .left)
        ]
        for (transform, expected) in transforms {
            let actual = try PoseVideoDecoder.imageOrientation(for: transform)
            precondition(actual == expected)
        }
        do {
            _ = try PoseVideoDecoder.imageOrientation(for: CGAffineTransform(rotationAngle: 0.4))
            fatalError("Nonstandard rotation should fail")
        } catch PoseAnalysisError.unsupportedTransform { }

        let analyzer = PoseAnalyzer()
        analyzer.analyze(url: clip)
        while analyzer.isAnalyzing { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(analyzer.errorMessage == nil && analyzer.report?.decodedFrameCount == 8)
        let exported = directory.appendingPathComponent("report.json")
        try analyzer.export(to: exported)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(PoseReport.self, from: Data(contentsOf: exported))
        precondition(restored.frames.count == 8 && restored.decodedFrameCount == 8)
        analyzer.analyze(url: clip)
        analyzer.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(!analyzer.isAnalyzing && analyzer.report == nil && analyzer.errorMessage == nil)
        analyzer.analyze(url: clip)
        analyzer.analyze(url: directory.appendingPathComponent("missing.mov"))
        while analyzer.isAnalyzing { try await Task.sleep(nanoseconds: 20_000_000) }
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(analyzer.report == nil && analyzer.errorMessage != nil)
        print("PASS: 8/8 VFR frames retained with original PTS; blank frames retained; JSON round-trip; 8 orientation mappings; nonstandard transform rejected; cancellation; stale-job isolation; invalid-source error")
        print("Probe artifacts: \(directory.path)")
    }

    static func makeVideo(at url: URL, timestamps: [Int64]) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 240
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 240
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        for timestamp in timestamps {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var optionalBuffer: CVPixelBuffer?
            precondition(CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA, nil, &optionalBuffer) == kCVReturnSuccess)
            let buffer = optionalBuffer!
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 32, CVPixelBufferGetBytesPerRow(buffer) * 240)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            precondition(adaptor.append(buffer, withPresentationTime: CMTime(value: timestamp, timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error! }
    }
}
