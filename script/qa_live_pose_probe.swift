
import Combine
import CoreMedia
import SwiftUI

// These are technical fixtures, not recordings or validation of pose accuracy.
@main
struct LivePoseProbe {
    struct Failure: Error { let message: String }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }
    final class ActiveFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true
        func read() -> Bool { lock.lock(); defer { lock.unlock() }; return active }
        func disable() { lock.lock(); active = false; lock.unlock() }
    }

    @MainActor static func main() async throws {
        try feedbackTests()
        try await authorizationAndAvailabilityTests()
        let camera = LivePoseCamera()
        try check(camera.state == .off && camera.snapshot == nil, "Camera must start off without permission access")
        var cameraChanges = 0, frameChanges = 0
        let cameraWatch = camera.objectWillChange.sink { cameraChanges += 1 }
        let frameWatch = camera.frames.objectWillChange.sink { frameChanges += 1 }
        let observation = LivePoseObservation(frameNumber: 1, timestamp: 0, width: 640, height: 480, bodyCount: 0, joints: [:])
        camera.frames.publish(LivePoseCameraSnapshot(image: nil, observation: observation), statistics: LivePoseCameraStatistics())
        try check(cameraChanges == 0 && frameChanges == 1, "High-rate frames must not publish the lifecycle object")
        try check(camera.aspectRatio == 4 / 3, "Native preview aspect ratio changed")
        camera.stop()
        try check(camera.state == .off && camera.snapshot == nil, "Stop must clear the preview immediately")
        withExtendedLifetime([cameraWatch, frameWatch]) {}
        let rect = LivePoseCameraSurface.imageRect(in: CGSize(width: 640, height: 480), aspectRatio: 16 / 9)
        try check(rect == CGRect(x: 0, y: 60, width: 640, height: 360), "Aspect-fit source and canvas rectangles differ")
        try check(LivePoseCameraSurface.imageRect(in: .zero, aspectRatio: 1) == .zero, "Empty preview size should be safe")

        let active = ActiveFlag()
        var packets: [LivePoseCameraSnapshot] = []
        var lastStats = LivePoseCameraStatistics()
        let pipeline = LivePoseCapturePipeline(format: "Synthetic 320 × 240", isActive: { active.read() }, onFrame: { snapshot, stats in
            packets.append(snapshot); lastStats = stats
        }, onStatistics: { lastStats = $0 })
        let timestamps: [Int64] = [0, 1, 3, 4, 7, 8, 12, 15]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue(label: "club.hidan.synthetic-camera-probe").async {
                do {
                let buffers = try timestamps.enumerated().map { try makeBuffer(timestamp: $0.element, brightness: UInt8(24 + $0.offset * 16)) }
                for buffer in buffers { pipeline.process(buffer) }
                pipeline.recordSystemDrop(buffers[0])
                pipeline.recordSystemDrop(buffers[1])
                active.disable()
                pipeline.process(buffers[0])
                pipeline.recordSystemDrop(buffers[0])
                continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        try check(packets.count == timestamps.count, "Frame was skipped, duplicated, or delivered after cancellation")
        try check(lastStats.captured == 8 && lastStats.analyzed == 8 && lastStats.analysisErrors == 0, "Full-buffer Vision processing counts differ")
        try check(lastStats.systemDropped == 2, "System-reported drops should be counted independently, never fabricated as analyzed frames")
        for (index, packet) in packets.enumerated() {
            try check(packet.observation.frameNumber == index + 1, "Source-frame ordering changed")
            try check(abs(packet.observation.timestamp - Double(timestamps[index]) / 30) < 0.0000001, "Source PTS changed")
            try check(packet.image?.width == 320 && packet.image?.height == 240, "Native buffer image dimensions were resized")
            try check(packet.observation.bodyCount == 0 && packet.observation.joints.isEmpty, "Blank frame should not fabricate a body")
        }
        print("PASS: 8/8 synthetic VFR buffers processed synchronously with original PTS and 320×240 pixels; no fabricated body; exact image/pose packets; 2 synthetic system-drop notifications counted; post-stop frame/drop suppression; high-rate frame publications isolated from camera lifecycle.")
        print("PASS: aspect-correct 2D angles, mirrored-angle invariance, confidence/NaN/degenerate rejection, whole-body/framing/multiple-person guidance, preview aspect-fit mapping, default-off and stop clearing; injected denied/restricted/not-determined authorization, cancel during permission request, no-device and restart paths. No capture session was started and no system camera permission was requested.")
    }

    @MainActor static func authorizationAndAvailabilityTests() async throws {
        for authorization in [AVAuthorizationStatus.denied, .restricted] {
            let denied = LivePoseCamera(authorizationStatus: { authorization },
                requestAccess: { _ in fatalError("Already-denied authorization must not request permission again") },
                deviceProvider: { fatalError("Denied authorization must not discover or open devices") })
            denied.start()
            try check(denied.state == .denied && denied.snapshot == nil, "Denied/restricted state was not handled")
            denied.stop()
        }
        var completion: (@Sendable (Bool) -> Void)?
        let pending = LivePoseCamera(authorizationStatus: { .notDetermined },
            requestAccess: { completion = $0 },
            deviceProvider: { fatalError("Cancelled permission result must not begin capture") })
        pending.start()
        try check(pending.state == .requestingPermission && completion != nil, "Explicit start must request first-time permission")
        pending.stop()
        completion?(true)
        try await Task.sleep(nanoseconds: 20_000_000)
        try check(pending.state == .off, "Late authorization callback restarted a stopped camera")
        let noDevice = LivePoseCamera(authorizationStatus: { .authorized },
            requestAccess: { _ in fatalError("Authorized camera must not request permission again") }, deviceProvider: { nil })
        for _ in 0..<2 {
            noDevice.start()
            for _ in 0..<100 {
                if !noDevice.isBusy { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            guard case .unavailable = noDevice.state else { throw Failure(message: "Missing device did not report unavailable") }
            noDevice.stop()
        }
    }

    static func feedbackTests() throws {
        func point(_ x: Double, _ y: Double, _ confidence: Double = 1) -> LivePosePoint { .init(x: x, y: y, confidence: confidence) }
        let a = point(0.25, 0.25), b = point(0.5, 0.5), c = point(0.75, 0.25)
        let angle = LivePoseFeedback.angle(a: a, vertex: b, c: c, width: 2000, height: 1000)!
        try check(abs(angle - 126.869897645844) < 0.00001, "Angle must use pixel aspect ratio, not a square normalized canvas")
        let mirrored = LivePoseFeedback.angle(a: point(1-a.x, a.y), vertex: point(1-b.x, b.y), c: point(1-c.x, c.y), width: 2000, height: 1000)!
        try check(abs(angle - mirrored) < 0.000001, "Display mirroring changed an observed angle")
        try check(LivePoseFeedback.angle(a: a, vertex: a, c: c, width: 640, height: 480) == nil, "Degenerate limbs must not produce angles")
        try check(LivePoseFeedback.angle(a: a, vertex: b, c: point(0.75, 0.25, 0.34), width: 640, height: 480) == nil, "Low-confidence joint produced an angle")
        try check(!LivePoseFeedback.isVisible(point(.nan, 0.5)), "NaN should be hidden")
        try check(!LivePoseFeedback.isVisible(point(1.01, 0.5)), "Out-of-frame joint should be hidden")
        try check(!LivePoseFeedback.isVisible(point(0.5, 0.5, .infinity)), "Invalid confidence should be hidden")
        let joints: [String: LivePosePoint] = [
            "leftShoulder": point(0.35, 0.78), "rightShoulder": point(0.65, 0.78),
            "leftHip": point(0.40, 0.50), "rightHip": point(0.60, 0.50),
            "leftKnee": point(0.40, 0.30), "rightKnee": point(0.60, 0.30),
            "leftAnkle": point(0.40, 0.10), "rightAnkle": point(0.60, 0.10)
        ]
        func feedback(_ values: [String: LivePosePoint], count: Int = 1) -> LivePoseFeedback {
            LivePoseFeedback(observation: .init(frameNumber: 1, timestamp: 0, width: 640, height: 480, bodyCount: count, joints: values))
        }
        let full = feedback(joints)
        try check(full.fullBodyVisible && full.headline == "全身已入镜" && full.leftKnee == 180, "Complete posture should be visible with straight projected knees")
        var missingAnkle = joints; missingAnkle.removeValue(forKey: "rightAnkle")
        try check(feedback(missingAnkle).headline.contains("脚踝"), "Missing ankle needs actionable framing feedback")
        var edge = joints; edge["leftAnkle"] = point(0.01, 0.10)
        try check(feedback(edge).guidance.contains("后退"), "Border posture needs space guidance")
        let multiple = feedback(joints, count: 2)
        try check(multiple.visibleJointCount == 0 && multiple.leftKnee == nil && multiple.headline.contains("2"), "Multiple people must not silently select a skeleton")
        try check(feedback([:], count: 0).headline.contains("还没"), "No-body feedback missing")
    }

    static func makeBuffer(timestamp: Int64, brightness: UInt8) throws -> CMSampleBuffer {
        var optional: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA,
                                        [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &optional)
        guard status == kCVReturnSuccess, let buffer = optional else { throw Failure(message: "Cannot create synthetic pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<240 { for column in 0..<320 {
            let base = row * stride + column * 4
            bytes[base] = brightness; bytes[base + 1] = brightness; bytes[base + 2] = brightness; bytes[base + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format) == noErr,
              let format else { throw Failure(message: "Cannot create synthetic format description") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: timestamp, timescale: 30), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { throw Failure(message: "Cannot create synthetic sample buffer") }
        return sample
    }
}
