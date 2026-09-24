// Run only through qa_party_ui.sh. Two PartyService instances pair over
// 127.0.0.1 exactly as the app does, synthetic frames flow through the
// production tap → H.264 → link → decoder path, and the production PartyView
// is rendered offscreen at each stage. No window is ordered on screen, no
// camera or Bonjour advertisement is used; gradient frames are fixtures.
import AppKit
import CoreVideo
import Foundation
import HidanCore
import SwiftUI

@main struct PartyUIProbe {
    struct Failure: Error { let message: String }

    @MainActor static func waitUntil(_ label: String, timeout: Double = 15, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw Failure(message: "Timed out waiting for \(label)") }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    @MainActor static func pump(_ seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    @MainActor static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, scheme: ColorScheme = .light, to url: URL) throws {
        NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let framed = view.frame(width: width, height: height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme).tint(ClubTheme.accent)
            .buttonStyle(.bordered)
        let host = NSHostingView(rootView: framed)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSApp.appearance
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        pump(0.25)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw Failure(message: "Native snapshot failed: \(url.lastPathComponent)")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure(message: "PNG encoding failed: \(url.lastPathComponent)")
        }
        window.contentView = nil
        try png.write(to: url, options: .atomic)
        print("rendered \(url.lastPathComponent)")
    }

    static func makeBuffer(width: Int, height: Int, phase: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess, let pixelBuffer = buffer else {
            throw Failure(message: "Pixel buffer allocation failed")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * stride + x * 4
                // Dim studio-like gradient with a brighter floor band.
                let floor = y > height * 3 / 4 ? 40 : 0
                p[0] = UInt8(min(255, 30 + x / 12 + floor)); p[1] = UInt8(min(255, 22 + y / 9 + floor)); p[2] = UInt8(min(255, 44 + phase * 2)); p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    /// A standing dancer, arms slightly out; Vision-style bottom-left normalized coordinates.
    static func observation(frame: Int, width: Int, height: Int) -> LivePoseObservation {
        let sway = sin(Double(frame) / 6) * 0.02
        func p(_ x: Double, _ y: Double, _ c: Double = 0.9) -> LivePosePoint { LivePosePoint(x: x + sway, y: y, confidence: c) }
        let joints: [String: LivePosePoint] = [
            "nose": p(0.50, 0.88), "leftEye": p(0.485, 0.895), "rightEye": p(0.515, 0.895), "leftEar": p(0.47, 0.885), "rightEar": p(0.53, 0.885),
            "neck": p(0.50, 0.80), "leftShoulder": p(0.42, 0.78), "rightShoulder": p(0.58, 0.78),
            "leftElbow": p(0.36, 0.64), "rightElbow": p(0.66, 0.66), "leftWrist": p(0.33, 0.50), "rightWrist": p(0.72, 0.56),
            "root": p(0.50, 0.52), "leftHip": p(0.455, 0.52), "rightHip": p(0.545, 0.52),
            "leftKnee": p(0.45, 0.32), "rightKnee": p(0.56, 0.31), "leftAnkle": p(0.445, 0.10), "rightAnkle": p(0.575, 0.10)
        ]
        return LivePoseObservation(frameNumber: frame, timestamp: Double(frame) / 30, width: width, height: height, bodyCount: 1, joints: joints)
    }

    @MainActor static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else { throw Failure(message: "usage: PartyUIProbe <png-dir>") }
        let pngDir = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: pngDir, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.prohibited)

        let suite = "club.hidan.party.ui-qa.\(UUID().uuidString)"
        let hostDefaults = UserDefaults(suiteName: suite + ".host")!, guestDefaults = UserDefaults(suiteName: suite + ".guest")!
        defer { hostDefaults.removePersistentDomain(forName: suite + ".host"); guestDefaults.removePersistentDomain(forName: suite + ".guest") }
        let hostCamera = LivePoseCamera(), guestCamera = LivePoseCamera()
        let hostMusic = MusicService(), guestMusic = MusicService()
        hostMusic.volume = 0; guestMusic.volume = 0
        let host = PartyService(frameTap: hostCamera.frameTap, defaults: hostDefaults)
        let guest = PartyService(frameTap: guestCamera.frameTap, defaults: guestDefaults)
        host.displayName = "小北的 MacBook"
        guest.displayName = "阿雅"
        host.attachBeatPlayer(hostMusic); guest.attachBeatPlayer(guestMusic)
        hostMusic.bpm = 96

        // 1. Guest lobby, idle: nothing nearby (no Bonjour in this probe), manual join visible.
        try render(PartyView(party: guest, camera: guestCamera, music: guestMusic), width: 1180, height: 760, to: pngDir.appendingPathComponent("lobby-idle.png"))

        // 2. Host lobby while the room is open.
        host.startHosting(advertise: false)
        try waitUntil("listener port") { host.port != nil }
        try render(PartyView(party: host, camera: hostCamera, music: hostMusic), width: 1180, height: 760, to: pngDir.appendingPathComponent("lobby-hosting.png"))

        // 3. Join request pending on the host.
        guest.join(addressText: "127.0.0.1:\(host.port!)", code: host.roomCode)
        try waitUntil("approval prompt") { host.pendingRequest != nil }
        try render(PartyView(party: host, camera: hostCamera, music: hostMusic), width: 1180, height: 760, to: pngDir.appendingPathComponent("lobby-request.png"))
        try render(PartyView(party: guest, camera: guestCamera, music: guestMusic), width: 1180, height: 760, to: pngDir.appendingPathComponent("lobby-waiting.png"))

        // 4. Connected: the host shares picture + skeleton through the real tap → H.264 → link → decoder path.
        host.approvePendingRequest()
        try waitUntil("both connected") { host.isConnected && guest.isConnected }
        try waitUntil("clock sync") { guest.statistics.roundTripMilliseconds != nil }
        host.shareMode = .video
        try waitUntil("guest learns share mode") { guest.remoteSharing == .video }
        for index in 0..<40 {
            hostCamera.frameTap.deliver(try makeBuffer(width: 1280, height: 720, phase: index), observation(frame: index, width: 1280, height: 720))
            pump(0.04)
        }
        try waitUntil("decoded picture on the guest") { guest.remoteFrames.value.image != nil && guest.remoteFrames.value.pose != nil }
        guard guest.remoteFrames.value.width == 640, guest.remoteFrames.value.height == 360 else {
            throw Failure(message: "Unexpected remote size \(guest.remoteFrames.value.width)×\(guest.remoteFrames.value.height)")
        }
        pump(1.1)
        try render(PartyView(party: guest, camera: guestCamera, music: guestMusic), width: 1180, height: 760, scheme: .dark,
                   to: pngDir.appendingPathComponent("stage-guest.png"))

        // 5. Guest shares only the skeleton back; host stage in light mode.
        guest.shareMode = .skeleton
        try waitUntil("host learns skeleton mode") { host.remoteSharing == .skeleton }
        for index in 0..<6 {
            guestCamera.frameTap.deliver(try makeBuffer(width: 640, height: 480, phase: index), observation(frame: index, width: 640, height: 480))
            pump(0.04)
        }
        try waitUntil("skeleton on the host") { host.remoteFrames.value.pose != nil && host.remoteFrames.value.image == nil }
        try render(PartyView(party: host, camera: hostCamera, music: hostMusic), width: 1180, height: 760,
                   to: pngDir.appendingPathComponent("stage-host.png"))

        // 6. Countdown overlay on both sides.
        host.startTogether(lead: 6)
        try waitUntil("guest countdown") { guest.countdown != nil }
        try render(PartyView(party: guest, camera: guestCamera, music: guestMusic), width: 1180, height: 760, scheme: .dark,
                   to: pngDir.appendingPathComponent("stage-countdown.png"))
        host.stopTogether()
        guest.leave()
        try waitUntil("host sees the goodbye") { host.peer == nil }
        host.stopHosting()
        pump(0.3)
        print("PARTY UI PROBE PASSED: 7 offscreen renders of the production PartyView; loopback session with decoded H.264 and paired joints. No window shown, no camera or Bonjour used.")
    }
}
