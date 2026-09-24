import XCTest
@testable import HidanCore

final class PartyProtocolTests: XCTestCase {
    func testFramesRoundTripThroughArbitraryChunking() throws {
        let frames = [
            PartyFrame(kind: .control, payload: Data("{\"type\":\"stop\"}".utf8)),
            PartyFrame(kind: .video, payload: Data((0..<5_000).map { UInt8($0 & 0xFF) })),
            PartyFrame(kind: .control, payload: Data())
        ]
        let stream = frames.map { $0.encoded() }.reduce(Data(), +)
        for chunk in [1, 3, 7, 64, 4_096, stream.count] {
            var decoder = PartyFrameDecoder()
            var received: [PartyFrame] = []
            var cursor = stream.startIndex
            while cursor < stream.endIndex {
                let end = min(cursor + chunk, stream.endIndex)
                received += try decoder.append(stream[cursor..<end])
                cursor = end
            }
            XCTAssertEqual(received, frames, "chunk \(chunk)")
            XCTAssertEqual(decoder.bufferedByteCount, 0)
        }
    }

    func testFrameDecoderRejectsCorruptStreams() {
        var oversize = PartyFrameDecoder()
        var header = Data(); header.appendBigEndian(UInt32(PartyProtocol.maxFrameLength + 1))
        XCTAssertThrowsError(try oversize.append(header)) { XCTAssertEqual($0 as? PartyFrameError, .frameTooLarge(PartyProtocol.maxFrameLength + 1)) }
        var empty = PartyFrameDecoder()
        XCTAssertThrowsError(try empty.append(Data([0, 0, 0, 0]))) { XCTAssertEqual($0 as? PartyFrameError, .emptyFrame) }
        var unknown = PartyFrameDecoder()
        XCTAssertThrowsError(try unknown.append(Data([0, 0, 0, 2, 9, 1]))) { XCTAssertEqual($0 as? PartyFrameError, .unknownKind(9)) }
        var partial = PartyFrameDecoder()
        XCTAssertEqual(try partial.append(Data([0, 0, 0, 3, 1, 0x7B])), [])
        XCTAssertEqual(partial.bufferedByteCount, 6)
    }

    func testMessagesRoundTripAsJSONWithTypeTag() throws {
        let pose = PartyPose(observation: LivePoseObservation(frameNumber: 3, timestamp: 0.1, width: 640, height: 480, bodyCount: 1, joints: [
            "nose": LivePosePoint(x: 0.5, y: 0.9, confidence: 0.8),
            "bad": LivePosePoint(x: .nan, y: 0.5, confidence: 0.5)
        ]))
        let messages: [PartyMessage] = [
            .hello(PartyHello(peerID: "a", name: "A", appVersion: "0.5.0")),
            .welcome(PartyWelcome(peerID: "b", name: "B", appVersion: "0.5.0")),
            .rejected(PartyRejection(reason: "full")),
            .ping(PartyPing(id: 7, sentAt: 12.5)),
            .pong(PartyPong(id: 7, sentAt: 12.5, receivedAt: 20, repliedAt: 20.001)),
            .sharing(PartySharing(mode: .skeleton, width: 640, height: 360)),
            .pose(pose),
            .beat(PartyBeatState(bpm: 96, playing: true, sourceName: "Club beat", isTrack: false, barAnchor: 100)),
            .beat(PartyBeatState(bpm: nil, playing: false, sourceName: "Song", isTrack: true, barAnchor: nil)),
            .countdown(PartyCountdown(startsAt: 130, bpm: 96, sourceName: "Club beat")),
            .stop,
            .bye(PartyFarewell(reason: nil))
        ]
        for message in messages {
            let data = try message.encoded()
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["type"] as? String, message.typeName)
            XCTAssertEqual(try PartyMessage(jsonData: data), message)
            let frame = try message.frame()
            XCTAssertEqual(frame.kind, .control)
        }
        XCTAssertEqual(pose.joints.count, 1, "non-finite joints never leave the sender")
        let restored = pose.observation
        XCTAssertEqual(restored.joints["nose"]?.confidence, 0.8)
        XCTAssertEqual(restored.width, 640)
        XCTAssertEqual(restored.bodyCount, 1)
        XCTAssertThrowsError(try PartyMessage(jsonData: Data("{\"type\":\"dance-battle\",\"body\":{}}".utf8))) {
            XCTAssertEqual($0 as? PartyMessageError, .unknownType("dance-battle"))
        }
    }

    func testVideoPacketBinaryRoundTripAndTruncation() throws {
        let packet = PartyVideoPacket(timestamp: 1.25, width: 960, height: 540, isKeyframe: true,
                                      parameterSets: [Data([0x67, 0x42, 0x00]), Data([0x68, 0xCE])], data: Data(repeating: 0xAB, count: 1_000))
        let encoded = packet.encoded()
        XCTAssertEqual(try PartyVideoPacket(decoding: encoded), packet)
        XCTAssertEqual(packet.frame().kind, .video)
        let delta = PartyVideoPacket(timestamp: 1.3, width: 960, height: 540, isKeyframe: false, parameterSets: [], data: Data([1, 2, 3]))
        XCTAssertEqual(try PartyVideoPacket(decoding: delta.encoded()), delta)
        for cut in [0, 1, 5, 13, 20, encoded.count - 1] {
            XCTAssertThrowsError(try PartyVideoPacket(decoding: encoded.prefix(cut)), "cut at \(cut)")
        }
        XCTAssertThrowsError(try PartyVideoPacket(decoding: encoded + Data([0]))) { XCTAssertEqual($0 as? PartyVideoPacketError, .truncated) }
        var wrongVersion = encoded; wrongVersion[wrongVersion.startIndex] = 9
        XCTAssertThrowsError(try PartyVideoPacket(decoding: wrongVersion)) { XCTAssertEqual($0 as? PartyVideoPacketError, .unsupportedVersion(9)) }
        let zero = PartyVideoPacket(timestamp: 0, width: 0, height: 0, isKeyframe: false, parameterSets: [], data: Data([1]))
        XCTAssertThrowsError(try PartyVideoPacket(decoding: zero.encoded())) { XCTAssertEqual($0 as? PartyVideoPacketError, .invalidDimensions) }
    }

    func testClockSyncPrefersTheQuietestSampleAndConverts() {
        var sync = PartyClockSync(capacity: 4)
        XCTAssertNil(sync.offset)
        // Remote clock runs 100 s ahead; symmetric 10 ms legs.
        sync.record(sentAt: 0, remoteReceivedAt: 100.010, remoteRepliedAt: 100.012, receivedAt: 0.022)
        XCTAssertEqual(sync.offset ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(sync.roundTrip ?? 0, 0.020, accuracy: 1e-9)
        // A jittery sample with a skewed offset loses to the lower round trip.
        sync.record(sentAt: 1, remoteReceivedAt: 101.300, remoteRepliedAt: 101.301, receivedAt: 1.320)
        XCTAssertEqual(sync.offset ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(sync.localTime(forRemote: 150) ?? 0, 50, accuracy: 1e-9)
        XCTAssertEqual(sync.remoteTime(forLocal: 50) ?? 0, 150, accuracy: 1e-9)
        XCTAssertNil(sync.record(sentAt: 5, remoteReceivedAt: 105, remoteRepliedAt: 105, receivedAt: 4), "receive before send is rejected")
        XCTAssertNil(sync.record(sentAt: 5, remoteReceivedAt: .nan, remoteRepliedAt: 105, receivedAt: 6))
        for i in 0..<10 { sync.record(sentAt: Double(i), remoteReceivedAt: Double(i) + 100.05, remoteRepliedAt: Double(i) + 100.05, receivedAt: Double(i) + 0.1) }
        XCTAssertEqual(sync.samples.count, 4)
        XCTAssertEqual(sync.offset ?? 0, 100, accuracy: 1e-9)
        sync.reset()
        XCTAssertNil(sync.roundTrip)
    }

    func testBeatGridFindsTheNextEightCount() {
        // 120 BPM: an eight-count bar lasts 4 s, bars start at 10, 14, 18…
        XCTAssertEqual(PartyBeatGrid.barLength(bpm: 120), 4)
        XCTAssertEqual(PartyBeatGrid.nextBarStart(after: 11, anchor: 10, bpm: 120), 14)
        XCTAssertEqual(PartyBeatGrid.nextBarStart(after: 14, anchor: 10, bpm: 120), 14)
        XCTAssertEqual(PartyBeatGrid.nextBarStart(after: 13.9, anchor: 10, bpm: 120, minimumLead: 0.15), 18)
        XCTAssertEqual(PartyBeatGrid.nextBarStart(after: 3, anchor: 10, bpm: 120), 6, "the grid extends before the anchor")
        XCTAssertNil(PartyBeatGrid.nextBarStart(after: 1, anchor: 0, bpm: 0))
        XCTAssertNil(PartyBeatGrid.nextBarStart(after: 1, anchor: 0, bpm: 120, minimumLead: -1))
        XCTAssertEqual(PartyBeatGrid.beatIndex(at: 10.6, anchor: 10, bpm: 120), 1)
        XCTAssertEqual(PartyBeatGrid.beatIndex(at: 14.1, anchor: 10, bpm: 120), 0)
        XCTAssertNil(PartyBeatGrid.beatIndex(at: 9, anchor: 10, bpm: 120))
    }

    func testAddressesAndRoomCodes() {
        XCTAssertEqual(PartyAddress.parse(" 192.168.1.8:52000 "), PartyAddress(host: "192.168.1.8", port: 52000))
        XCTAssertEqual(PartyAddress.parse("[fe80::1%en0]:7000"), PartyAddress(host: "fe80::1%en0", port: 7000))
        XCTAssertEqual(PartyAddress.parse("bens-mac.local:1"), PartyAddress(host: "bens-mac.local", port: 1))
        XCTAssertEqual(PartyAddress(host: "fe80::1", port: 5).description, "[fe80::1]:5")
        XCTAssertEqual(PartyAddress(host: "10.0.0.2", port: 5).description, "10.0.0.2:5")
        for bad in ["", "192.168.1.8", "192.168.1.8:", ":5000", "192.168.1.8:0", "192.168.1.8:65536", "a b:5", "fe80::1:5000", "[fe80::1]5000", "[]:5000", "host:12ab"] {
            XCTAssertNil(PartyAddress.parse(bad), bad)
        }
        var generator = SystemRandomNumberGenerator()
        let code = PartyRoomCode.generate(using: &generator)
        XCTAssertEqual(code.count, 4)
        XCTAssertEqual(PartyRoomCode.normalize(code), code)
        XCTAssertEqual(PartyRoomCode.normalize(" 12-34 "), "1234")
        XCTAssertNil(PartyRoomCode.normalize("123"))
        XCTAssertNil(PartyRoomCode.normalize("12345"))
        XCTAssertNil(PartyRoomCode.normalize("12a4"))
        XCTAssertNil(PartyRoomCode.normalize("１２３４"), "full-width digits are not accepted")
    }
}
