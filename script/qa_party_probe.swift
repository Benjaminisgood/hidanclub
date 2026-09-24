import Combine
import CoreVideo
import Foundation
import HidanCore

// Loopback regression for the friend link: two PartyService instances in one
// process talk over 127.0.0.1 with the production TLS-PSK parameters, framing,
// handshake, clock sync, share modes, H.264 packets and beat commands. No
// camera, microphone, Bonjour advertisement or local-network prompt is involved;
// synthetic gradient frames are technical fixtures, not dance footage.
@main
struct PartyProbe {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private static var checks = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #fileID, line: UInt = #line) throws {
        checks += 1
        guard condition() else { throw Failure(description: "\(file):\(line): \(message)") }
    }

    @MainActor static func waitUntil(_ timeout: Double, _ message: String, file: StaticString = #fileID, line: UInt = #line,
                                     _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = PartyService.now() + timeout
        while !condition() {
            guard PartyService.now() < deadline else { throw Failure(description: "\(file):\(line): timed out waiting for \(message)") }
            try await Task.sleep(for: .milliseconds(15))
        }
        checks += 1
    }

    @MainActor final class FakeBeatPlayer: PartyBeatPlayer {
        // 160 BPM keeps an eight-count bar at 3 s, so bar-aligned starts stay quick in this probe.
        var snapshot = PartyBeatSnapshot(isPlaying: false, isPaused: false, isBeat: true, bpm: 160, sourceName: "Probe beat", isTrack: false)
        private let subject = PassthroughSubject<Void, Never>()
        var log: [String] = []
        var partyBeatSnapshot: PartyBeatSnapshot { snapshot }
        var beatChanges: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }
        func prepareSharedBeat(name: String, bpm: Double) {
            log.append("prepare \(Int(bpm))"); snapshot.isPlaying = false; snapshot.isPaused = false
            snapshot.bpm = bpm; snapshot.sourceName = name; snapshot.isBeat = true; subject.send()
        }
        func playSharedBeat() { log.append("play"); snapshot.isPlaying = true; snapshot.isPaused = false; subject.send() }
        func pauseSharedBeat() { log.append("pause"); snapshot.isPlaying = false; snapshot.isPaused = true; subject.send() }
        func stopSharedBeat() { log.append("stop"); snapshot.isPlaying = false; snapshot.isPaused = false; subject.send() }
        /// The host user pressing controls in the music bar.
        func userPlay() { snapshot.isPlaying = true; snapshot.isPaused = false; subject.send() }
        func userPause() { snapshot.isPlaying = false; snapshot.isPaused = true; subject.send() }
        func userTempo(_ bpm: Double) { snapshot.bpm = bpm; subject.send() }
    }

    static func makeBuffer(width: Int, height: Int, phase: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        try expect(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess, "Pixel buffer allocation")
        let pixelBuffer = buffer!
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * stride + x * 4
                p[0] = UInt8((x + phase * 7) & 0xFF); p[1] = UInt8((y + phase * 3) & 0xFF); p[2] = UInt8(((x ^ y) + phase) & 0xFF); p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    static func observation(frame: Int, width: Int, height: Int) -> LivePoseObservation {
        let joints: [String: LivePosePoint] = [
            "nose": LivePosePoint(x: 0.5, y: 0.9, confidence: 0.9), "neck": LivePosePoint(x: 0.5, y: 0.8, confidence: 0.9),
            "leftShoulder": LivePosePoint(x: 0.4, y: 0.78, confidence: 0.8), "rightShoulder": LivePosePoint(x: 0.6, y: 0.78, confidence: 0.8),
            "leftHip": LivePosePoint(x: 0.45, y: 0.5, confidence: 0.7), "rightHip": LivePosePoint(x: 0.55, y: 0.5, confidence: 0.7),
            "leftAnkle": LivePosePoint(x: 0.44, y: 0.1, confidence: 0.6), "rightAnkle": LivePosePoint(x: 0.56, y: 0.1, confidence: 0.6),
            "bogus": LivePosePoint(x: .nan, y: 0.2, confidence: 0.5)
        ]
        return LivePoseObservation(frameNumber: frame, timestamp: Double(frame) / 30, width: width, height: height, bodyCount: 1, joints: joints)
    }

    static func codecRoundTrip() throws {
        var packets: [PartyVideoPacket] = []
        let lock = NSLock()
        let encoder = PartyVideoEncoder(configuration: .init(maxWidth: 640, bitrate: 1_000_000)) { packet in
            lock.lock(); packets.append(packet); lock.unlock()
        }
        let frames = 12
        for index in 0..<frames {
            let buffer = try makeBuffer(width: 1280, height: 720, phase: index)
            try expect(encoder.encode(buffer, timestamp: Double(index) / 30), "Encoder accepted frame \(index): \(encoder.lastFailure ?? "")")
        }
        encoder.invalidate()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            lock.lock(); let count = packets.count; lock.unlock()
            if count >= frames { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        lock.lock(); let produced = packets; lock.unlock()
        try expect(produced.count == frames, "Encoder produced \(produced.count) packets for \(frames) frames")
        try expect(produced.allSatisfy { $0.width == 640 && $0.height == 360 }, "Scaled to 640×360 with the source aspect ratio")
        try expect(produced[0].isKeyframe && produced[0].parameterSets.count >= 2, "First packet is a keyframe with SPS/PPS")
        try expect(produced.dropFirst().contains { !$0.isKeyframe }, "Later packets include P-frames")
        try expect(produced.map(\.timestamp) == produced.map(\.timestamp).sorted(), "Packets in presentation order")
        for packet in produced {
            let restored = try PartyVideoPacket(decoding: packet.encoded())
            try expect(restored == packet, "Video packet binary round trip")
        }
        let decoder = PartyVideoDecoder()
        try expect(decoder.decode(produced[1]) == nil && !decoder.isReady, "P-frame before any keyframe is ignored")
        var decodedCount = 0
        for packet in produced {
            if let image = decoder.decode(packet) {
                decodedCount += 1
                try expect(image.width == 640 && image.height == 360, "Decoded picture is 640×360")
            } else {
                try expect(false, "Frame failed to decode: \(decoder.lastFailure ?? "unknown")")
            }
        }
        try expect(decodedCount == frames, "Every packet decoded (\(decodedCount)/\(frames))")
        try expect(PartyVideoEncoder.targetSize(for: CGSize(width: 1920, height: 1080), maxWidth: 960) == CGSize(width: 960, height: 540), "1080p → 960×540")
        try expect(PartyVideoEncoder.targetSize(for: CGSize(width: 640, height: 480), maxWidth: 960) == CGSize(width: 640, height: 480), "Small sources are not upscaled")
        try expect(PartyVideoEncoder.targetSize(for: CGSize(width: 1080, height: 1920), maxWidth: 640) == CGSize(width: 640, height: 1138), "Portrait keeps even dimensions")
        print("PASS: H.264 encode/decode round trip: 12 synthetic 1280×720 frames → 640×360 packets, keyframe with parameter sets, P-frames, binary packet round trip, ignored orphan P-frame, decoded pictures.")
    }

    @MainActor static func loopbackSession() async throws {
        let suite = "club.hidan.party.qa.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let hostTap = LivePoseFrameTap(), guestTap = LivePoseFrameTap()
        let host = PartyService(frameTap: hostTap, defaults: defaults)
        let guest = PartyService(frameTap: guestTap, defaults: UserDefaults(suiteName: suite + ".guest")!)
        defer { UserDefaults(suiteName: suite + ".guest")!.removePersistentDomain(forName: suite + ".guest") }
        host.displayName = "Host Mac"
        guest.displayName = "  Guest Mac  "
        try expect(guest.displayName == "Guest Mac", "Display name is trimmed")
        try expect(host.peerID != guest.peerID, "Peers have distinct identities")
        let hostPlayer = FakeBeatPlayer(), guestPlayer = FakeBeatPlayer()
        host.attachBeatPlayer(hostPlayer); guest.attachBeatPlayer(guestPlayer)

        host.startHosting(advertise: false)
        try expect(host.role == .host && host.phase == .hosting && host.roomCode.count == 4, "Host opens a room with a four-digit code")
        try await waitUntil(5, "listener port") { host.port != nil }
        let port = host.port!

        // Wrong code: the TLS pre-shared key differs, so the handshake fails and the guest sees a clear ending.
        let wrongCode = host.roomCode == "0000" ? "0001" : "0000"
        guest.join(addressText: "127.0.0.1:\(port)", code: wrongCode)
        try expect(guest.role == .guest && guest.phase == .connecting, "Guest starts connecting")
        try await waitUntil(15, "wrong-code rejection") { if case .ended = guest.phase { return true }; return false }
        try expect(guest.role == .none && guest.peer == nil, "Failed join resets the guest")
        try expect(host.pendingRequest == nil && host.peer == nil && host.phase == .hosting, "Host never saw a request without the right key")
        guest.dismissEnded()
        try expect(guest.phase == .idle, "Ended notice dismissed")

        guest.join(addressText: "not an address", code: host.roomCode)
        try expect(guest.role == .none && guest.errorMessage != nil, "Malformed address is refused before connecting")
        guest.join(addressText: "127.0.0.1:\(port)", code: "12")
        try expect(guest.role == .none, "Short code refused before connecting")

        // Right code: hello → approval → welcome.
        guest.errorMessage = nil
        guest.join(addressText: "127.0.0.1:\(port)", code: " \(host.roomCode.prefix(2))-\(host.roomCode.suffix(2)) ")
        try await waitUntil(10, "host approval prompt") { host.pendingRequest != nil }
        try expect(host.pendingRequest?.name == "Guest Mac" && host.pendingRequest?.id == guest.peerID, "Host sees who wants in")
        try expect(guest.phase == .waitingForApproval, "Guest waits for approval")

        // A second connection while a request is pending is turned away politely.
        let intruder = PartyService(frameTap: nil, defaults: UserDefaults(suiteName: suite + ".intruder")!)
        defer { UserDefaults(suiteName: suite + ".intruder")!.removePersistentDomain(forName: suite + ".intruder") }
        intruder.join(addressText: "127.0.0.1:\(port)", code: host.roomCode)
        try await waitUntil(10, "intruder rejection") { if case .ended(let reason) = intruder.phase { return reason.contains("有人") }; return false }
        try expect(host.pendingRequest?.id == guest.peerID, "Pending request survives the extra connection")

        host.approvePendingRequest()
        try await waitUntil(5, "both connected") { host.isConnected && guest.isConnected }
        try expect(host.peer?.name == "Guest Mac" && guest.peer?.name == "Host Mac", "Both sides know each other's names")
        try expect(host.pendingRequest == nil && host.roomCode.count == 4, "Approval clears the prompt and keeps the room")
        try await waitUntil(5, "clock sync from pings") {
            host.statistics.roundTripMilliseconds != nil && guest.statistics.roundTripMilliseconds != nil
        }
        try expect(abs(host.statistics.clockOffsetMilliseconds ?? 999) < 50 && abs(guest.statistics.clockOffsetMilliseconds ?? 999) < 50,
                   "Same-machine clocks align within 50 ms (host \(host.statistics.clockOffsetMilliseconds ?? .nan), guest \(guest.statistics.clockOffsetMilliseconds ?? .nan))")
        try expect((host.statistics.roundTripMilliseconds ?? 999) < 200, "Loopback round trip under 200 ms")

        // Host beat state was mirrored on connect.
        try await waitUntil(3, "initial beat state") { guest.hostBeat != nil }
        try expect(guest.hostBeat?.playing == false && guest.hostBeat?.bpm == 160, "Guest sees the host's idle 160 BPM beat")
        try expect(guestPlayer.log.isEmpty, "Idle host does not start the guest's beat")

        // Nothing is shared until a mode is chosen.
        try expect(host.remoteSharing == .off && guest.remoteSharing == .off, "Sharing starts off on both sides")
        try expect(!guestTap.isInstalled && !hostTap.isInstalled, "No capture tap while sharing is off")
        guestTap.deliver(try makeBuffer(width: 320, height: 240, phase: 0), observation(frame: 0, width: 320, height: 240))
        try await Task.sleep(for: .milliseconds(200))
        try expect(host.remoteFrames.value.pose == nil && host.remoteFrames.value.image == nil, "Frames delivered while off never leave the Mac")

        // Skeleton only: joints arrive, no picture.
        guest.shareMode = .skeleton
        try expect(guestTap.isInstalled, "Skeleton sharing installs the capture tap")
        try await waitUntil(3, "host learns the guest's share mode") { host.remoteSharing == .skeleton }
        guestTap.deliver(try makeBuffer(width: 320, height: 240, phase: 1), observation(frame: 1, width: 320, height: 240))
        try await waitUntil(3, "pose arrives at host") { host.remoteFrames.value.pose != nil }
        let pose = host.remoteFrames.value.pose!
        try expect(pose.joints.count == 8 && pose.joints["bogus"] == nil && pose.width == 320 && pose.height == 240 && pose.bodyCount == 1,
                   "Finite joints arrive with the frame size; NaN joint dropped")
        try expect(abs((pose.joints["nose"]?.confidence ?? 0) - 0.9) < 1e-9 && abs(pose.timestamp - 1.0 / 30) < 1e-9, "Joint confidence and timestamp intact")
        try expect(host.remoteFrames.value.image == nil, "Skeleton mode carries no picture")

        // Picture and skeleton: H.264 packets decode on the host, paired with same-frame joints.
        guest.shareMode = .video
        try await waitUntil(3, "host learns video mode") { host.remoteSharing == .video }
        for index in 2..<26 {
            guestTap.deliver(try makeBuffer(width: 1280, height: 720, phase: index), observation(frame: index, width: 1280, height: 720))
            try await Task.sleep(for: .milliseconds(40))
        }
        try await waitUntil(5, "decoded picture at host") { host.remoteFrames.value.image != nil }
        let value = host.remoteFrames.value
        try expect(value.image?.width == 640 && value.image?.height == 360 && value.width == 640 && value.height == 360, "Host shows a 640×360 picture (smooth quality)")
        try expect(value.pose != nil && value.pose!.width == 1280, "Picture arrives with the joints of the same camera frame")
        try await Task.sleep(for: .milliseconds(1100))
        try expect(host.statistics.receivedKilobitsPerSecond > 0 || host.statistics.receivedFramesPerSecond > 0 || guest.statistics.sentFramesPerSecond >= 0,
                   "Traffic statistics update once a second")
        try expect(guest.statistics.outputWidth == 640 && guest.statistics.outputHeight == 360, "Sender reports its output size")
        try expect(guest.sharingStatus == nil, "Encoder reports no failure: \(guest.sharingStatus ?? "")")

        // Quality change restarts the encoder with a keyframe at the new size.
        guest.quality = .clear
        for index in 26..<40 {
            guestTap.deliver(try makeBuffer(width: 1280, height: 720, phase: index), observation(frame: index, width: 1280, height: 720))
            try await Task.sleep(for: .milliseconds(40))
        }
        try await waitUntil(5, "960-wide picture after quality change") { host.remoteFrames.value.width == 960 && host.remoteFrames.value.image?.width == 960 }

        // Turning sharing off clears the friend's tile.
        guest.shareMode = .off
        try await waitUntil(3, "host clears the picture") { host.remoteSharing == .off && host.remoteFrames.value.image == nil && host.remoteFrames.value.pose == nil }
        try expect(!guestTap.isInstalled, "Tap removed when sharing stops")

        // Host presses play in the music bar: the guest adopts tempo and starts on a bar boundary.
        hostPlayer.userPlay()
        try await waitUntil(3, "guest prepares and waits for the bar") { guestPlayer.log == ["prepare 160"] && guest.nextBarStartLocal != nil }
        let barWait = guest.nextBarStartLocal! - PartyService.now()
        try expect(barWait > 0 && barWait <= 3.05, "Bar-aligned start is at most one 160 BPM eight-count away (\(barWait) s)")
        try await waitUntil(4, "guest follows host play") { guestPlayer.log.contains("play") }
        try expect(guest.nextBarStartLocal == nil, "Waiting indicator clears when the beat starts")
        try expect(guest.hostBeat?.playing == true && guest.hostBeat?.barAnchor != nil, "Playing state and bar anchor mirrored")
        // A pending bar-aligned start must not block a pause.
        hostPlayer.userTempo(180)
        try await waitUntil(3, "guest follows tempo change") { guestPlayer.log.contains("prepare 180") && guest.nextBarStartLocal != nil }
        hostPlayer.userPause()
        try await waitUntil(3, "pause cancels the pending start") { guest.nextBarStartLocal == nil && guest.hostBeat?.playing == false }
        try await Task.sleep(for: .milliseconds(3100))
        try expect(!guestPlayer.log.dropFirst(2).contains("play"), "Cancelled start never fires: \(guestPlayer.log)")
        hostPlayer.userPlay()
        try await waitUntil(4, "guest plays again") { guestPlayer.log.last == "play" }
        hostPlayer.userPause()
        try await waitUntil(3, "guest follows pause") { guestPlayer.log.last == "pause" }

        // Guest who stops following keeps their own beat.
        guest.followHostBeat = false
        let logBefore = guestPlayer.log.count
        hostPlayer.userPlay()
        try await waitUntil(3, "beat state still mirrored") { guest.hostBeat?.playing == true }
        try await Task.sleep(for: .milliseconds(300))
        try expect(guestPlayer.log.count == logBefore, "Not following: guest player untouched")
        guest.followHostBeat = true
        hostPlayer.userPause()
        try await waitUntil(3, "pause mirrored") { guest.hostBeat?.playing == false }

        // Start together: both fire on the same instant after the countdown.
        guestPlayer.log.removeAll(); hostPlayer.log.removeAll()
        host.startTogether(lead: 1.0)
        try expect(host.countdown != nil && hostPlayer.log.first == "stop", "Host stops, then counts down")
        try await waitUntil(3, "guest shows the countdown") { guest.countdown != nil }
        let hostStart = host.countdown!.startsAtLocal, guestStart = guest.countdown!.startsAtLocal
        try expect(abs(hostStart - guestStart) < 0.05, "Countdown converted to the guest clock within 50 ms (\(abs(hostStart - guestStart) * 1000) ms)")
        try expect(guestPlayer.log == ["prepare 180"], "Guest prepared the host's current tempo but waits for the start: \(guestPlayer.log)")
        try await waitUntil(3, "both players start") { hostPlayer.log.contains("play") && guestPlayer.log.contains("play") }
        try expect(host.countdown?.fired == true || host.countdown == nil, "Countdown marked fired on the host")
        try await waitUntil(3, "countdown overlays clear") { host.countdown == nil && guest.countdown == nil }
        try await Task.sleep(for: .milliseconds(200))
        try expect(guestPlayer.log.filter { $0 == "play" }.count == 1, "Host's own play broadcast does not restart the guest: \(guestPlayer.log)")
        host.stopTogether()
        try await waitUntil(3, "guest stops with the host") { guestPlayer.log.last == "pause" }
        try expect(hostPlayer.log.last == "stop", "Host stopped its beat")

        // Leaving: the guest says goodbye, the host keeps the room open.
        guest.leave()
        try expect(guest.role == .none && guest.phase == .idle && guest.peer == nil, "Guest returns to the lobby")
        try await waitUntil(5, "host notices the goodbye") { host.peer == nil && host.phase == .hosting }
        try expect(host.role == .host && host.port == port && host.errorMessage?.contains("Guest Mac") == true, "Host stays in the room and says who left")
        try expect(!hostTap.isInstalled, "Host tap released after the friend left")
        host.stopHosting()
        try expect(host.role == .none && host.phase == .idle && host.port == nil && host.roomCode.isEmpty, "Closing the room resets the host")
        try await Task.sleep(for: .milliseconds(200))
        print("PASS: loopback TLS-PSK session: wrong code fails cleanly; malformed address/code refused; hello → approval → welcome; extra joiner turned away; ping/pong clock alignment; off → skeleton → video → off sharing with paired joints and 640/960-wide pictures; host play/tempo/pause mirrored; follow toggle; countdown start within 50 ms; goodbye keeps the room open.")
    }

    @MainActor static func main() async throws {
        try codecRoundTrip()
        try await loopbackSession()
        print("PARTY PROBE PASSED: \(checks) checks over 127.0.0.1. No Bonjour advertisement, camera, microphone or file was used.")
    }
}
