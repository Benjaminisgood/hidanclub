// Standalone AVPlayer / VideoService regression probe. Run from the project root:
// swiftc -swift-version 5 -target arm64-apple-macosx14.0 -o /tmp/hidan_video_probe Sources/HidanClub/Services/VideoService.swift script/qa_video_probe.swift
// /tmp/hidan_video_probe
// On Intel, substitute x86_64-apple-macosx14.0 for the target above.
// Generates its own blank 1-second video; downloads no media and requests no camera.
// Exercises real media playback plus one explicitly injected delayed end notification
// to reproduce the pause-versus-end-event race deterministically.

import AVFoundation
import Foundation

private struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct VideoProbe {
    @MainActor
    static func main() async {
        do {
            try await run()
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    @MainActor
    private static func run() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hidan-video-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clip = directory.appendingPathComponent("generated-blank.mov")
        try await makeVideo(at: clip)

        let service = VideoService()
        defer { service.pause() }
        service.load(url: clip)
        try await wait("video load") { service.name == clip.lastPathComponent && service.duration > 0 }
        try await wait("player item readiness") { service.player.currentItem?.status == .readyToPlay }
        try check(abs(service.duration - 1) < 0.02, "Expected 1-second asset; received \(service.duration)")
        try check(service.loopStart == 0 && abs(service.loopEnd - service.duration) < 0.001, "Initial loop must span the full asset")
        try check(!service.loopEnabled && !service.isPlaying && service.errorMessage == nil, "Loading must remain paused without an error")

        service.seek(0.35)
        try await wait("exact seek") { abs(service.player.currentTime().seconds - 0.35) < 0.02 }
        try check(service.player.rate == 0, "Seeking while paused must not begin playback")
        service.seek(0)
        try await wait("seek to start") { service.player.currentTime().seconds < 0.02 }

        service.setRate(0.5)
        service.toggle()
        try await wait("0.5x playback") { service.isPlaying && abs(service.player.rate - 0.5) < 0.001 }
        try await wait("media clock advances") { service.player.currentTime().seconds >= 0.15 }
        service.setRate(1)
        try await wait("rate change while playing") { abs(service.player.rate - 1) < 0.001 }
        service.toggle()
        try await wait("toggle pauses") { !service.isPlaying && service.player.rate == 0 }

        service.seek(0)
        try await wait("loop preparation") { service.player.currentTime().seconds < 0.02 }
        service.loopStart = 0
        service.loopEnd = service.duration
        service.loopEnabled = true
        service.toggle()
        try await waitForWraps(service, count: 2, timeout: 4)
        try check(service.isPlaying && service.player.rate > 0, "Full-asset loop stopped at end instead of resuming")

        // Pause around an active loop and leave enough time for seek/end callbacks.
        service.pause()
        let pausedAt = service.player.currentTime().seconds
        try await Task.sleep(nanoseconds: 700_000_000)
        try check(!service.isPlaying && service.player.rate == 0, "Pause unexpectedly resumed the full-asset loop")
        try check(abs(service.player.currentTime().seconds - pausedAt) < 0.06, "Media advanced while paused")

        // A completion notification can already be queued when the user pauses.
        // Inject that ordering explicitly; it must not override user playback intent.
        if let item = service.player.currentItem {
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        try check(!service.isPlaying && service.player.rate == 0, "A delayed end notification restarted playback after pause")

        service.load(url: directory.appendingPathComponent("missing.mov"))
        try await wait("invalid source error") { service.errorMessage != nil }
        try check(!service.isPlaying && service.player.rate == 0, "Failed loading resumed playback")

        print("PASS: load/duration; paused exact seek; 0.5x playback and rate change; full-asset A-B loop (2 wraps); pause stays paused; delayed-end pause race; failed-load error")
        print("Probe artifacts: \(directory.path)")
    }

    @MainActor
    private static func wait(
        _ label: String,
        timeout: TimeInterval = 4,
        condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw ProbeFailure(description: "Timed out: \(label)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor
    private static func waitForWraps(_ service: VideoService, count: Int, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var previous = service.player.currentTime().seconds
        var wraps = 0
        while wraps < count {
            guard Date() < deadline else {
                throw ProbeFailure(description: "Expected \(count) full-asset loops; observed \(wraps), time=\(service.player.currentTime().seconds), rate=\(service.player.rate)")
            }
            try await Task.sleep(nanoseconds: 15_000_000)
            let current = service.player.currentTime().seconds
            if previous > service.duration * 0.7 && current < service.duration * 0.3 { wraps += 1 }
            previous = current
        }
    }

    private static func check(_ condition: Bool, _ description: String) throws {
        if !condition { throw ProbeFailure(description: description) }
    }

    private static func makeVideo(at url: URL) async throws {
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
        guard writer.startWriting() else { throw writer.error ?? ProbeFailure(description: "Video writer failed to start") }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var optionalBuffer: CVPixelBuffer?
            let result = CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA, nil, &optionalBuffer)
            guard result == kCVReturnSuccess, let buffer = optionalBuffer else {
                throw ProbeFailure(description: "Pixel buffer allocation failed")
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 48, CVPixelBufferGetBytesPerRow(buffer) * 240)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try check(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)), "Could not append video frame")
        }
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ProbeFailure(description: "Video writer did not finish") }
    }
}
