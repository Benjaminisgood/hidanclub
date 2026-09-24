import Foundation

/// Wire protocol for dancing with one friend over a direct peer-to-peer link.
/// Everything here is Foundation-only and deterministic: framing, message
/// bodies, the binary video packet, NTP-style clock alignment and the shared
/// beat grid. Transport, cameras and codecs live in the app target.
public enum PartyProtocol {
    public static let version = 1
    /// Bonjour service type advertised by a host on the local network.
    public static let serviceType = "_hidanclub._tcp"
    /// Bonjour TXT key carrying `version`, so incompatible rooms can be labelled before joining.
    public static let versionTXTKey = "v"
    /// Largest accepted frame; anything longer is treated as a corrupt stream.
    public static let maxFrameLength = 8 * 1024 * 1024
    /// One shared beat bar: eight counts, matching the built-in beat loop.
    public static let beatsPerBar = 8
}

// MARK: - Framing

/// One length-prefixed unit on the wire: `UInt32 big-endian length` (kind + payload), `UInt8 kind`, payload.
public struct PartyFrame: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        /// JSON-encoded `PartyMessage`.
        case control = 1
        /// Binary `PartyVideoPacket`.
        case video = 2
    }
    public let kind: Kind
    public let payload: Data
    public init(kind: Kind, payload: Data) { self.kind = kind; self.payload = payload }

    public func encoded() -> Data {
        var data = Data(capacity: payload.count + 5)
        data.appendBigEndian(UInt32(payload.count + 1))
        data.append(kind.rawValue)
        data.append(payload)
        return data
    }
}

public enum PartyFrameError: Error, Equatable, Sendable {
    case frameTooLarge(Int)
    case emptyFrame
    case unknownKind(UInt8)
}

/// Incremental parser: feed arbitrary byte chunks, receive complete frames in order.
public struct PartyFrameDecoder: Sendable {
    private var buffer = Data()
    public init() {}
    public var bufferedByteCount: Int { buffer.count }

    public mutating func append(_ data: Data) throws -> [PartyFrame] {
        buffer.append(data)
        var frames: [PartyFrame] = []
        while buffer.count >= 4 {
            let length = Int(buffer.readBigEndianUInt32(at: buffer.startIndex))
            guard length >= 1 else { buffer.removeAll(); throw PartyFrameError.emptyFrame }
            guard length <= PartyProtocol.maxFrameLength else { buffer.removeAll(); throw PartyFrameError.frameTooLarge(length) }
            let total = 4 + length
            guard buffer.count >= total else { break }
            let kindByte = buffer[buffer.startIndex + 4]
            guard let kind = PartyFrame.Kind(rawValue: kindByte) else { buffer.removeAll(); throw PartyFrameError.unknownKind(kindByte) }
            let payload = Data(buffer[(buffer.startIndex + 5)..<(buffer.startIndex + total)])
            frames.append(PartyFrame(kind: kind, payload: payload))
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + total))
        }
        return frames
    }
}

// MARK: - Control messages

public struct PartyHello: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let peerID: String
    public let name: String
    public let appVersion: String
    public init(protocolVersion: Int = PartyProtocol.version, peerID: String, name: String, appVersion: String) {
        self.protocolVersion = protocolVersion; self.peerID = peerID; self.name = name; self.appVersion = appVersion
    }
}

public struct PartyWelcome: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let peerID: String
    public let name: String
    public let appVersion: String
    public init(protocolVersion: Int = PartyProtocol.version, peerID: String, name: String, appVersion: String) {
        self.protocolVersion = protocolVersion; self.peerID = peerID; self.name = name; self.appVersion = appVersion
    }
}

public struct PartyRejection: Codable, Equatable, Sendable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

public struct PartyPing: Codable, Equatable, Sendable {
    public let id: UInt32
    /// Sender's monotonic clock when the ping left.
    public let sentAt: Double
    public init(id: UInt32, sentAt: Double) { self.id = id; self.sentAt = sentAt }
}

public struct PartyPong: Codable, Equatable, Sendable {
    public let id: UInt32
    public let sentAt: Double
    /// Replier's monotonic clock when the ping arrived and when the pong left.
    public let receivedAt: Double
    public let repliedAt: Double
    public init(id: UInt32, sentAt: Double, receivedAt: Double, repliedAt: Double) {
        self.id = id; self.sentAt = sentAt; self.receivedAt = receivedAt; self.repliedAt = repliedAt
    }
}

/// What a peer sends about itself: nothing, only the detected joints, or picture plus joints.
public enum PartyShareMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, skeleton, video
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .off: return "不共享"
        case .skeleton: return "只共享骨架"
        case .video: return "画面与骨架"
        }
    }
    public var sendsPose: Bool { self != .off }
    public var sendsVideo: Bool { self == .video }
}

public struct PartySharing: Codable, Equatable, Sendable {
    public let mode: PartyShareMode
    public let width: Int
    public let height: Int
    public init(mode: PartyShareMode, width: Int, height: Int) { self.mode = mode; self.width = width; self.height = height }
}

/// One camera observation in wire form. Joint values are `[x, y, confidence]`
/// in Vision's normalized bottom-left space; non-finite values never leave the sender.
public struct PartyPose: Codable, Equatable, Sendable {
    public let timestamp: Double
    public let width: Int
    public let height: Int
    public let bodyCount: Int
    public let joints: [String: [Double]]

    public init(timestamp: Double, width: Int, height: Int, bodyCount: Int, joints: [String: [Double]]) {
        self.timestamp = timestamp; self.width = width; self.height = height; self.bodyCount = bodyCount; self.joints = joints
    }

    public init(observation: LivePoseObservation) {
        var joints: [String: [Double]] = [:]
        for (name, point) in observation.joints where point.x.isFinite && point.y.isFinite && point.confidence.isFinite {
            joints[name] = [point.x, point.y, point.confidence]
        }
        self.init(timestamp: observation.timestamp.isFinite ? observation.timestamp : 0,
                  width: observation.width, height: observation.height, bodyCount: observation.bodyCount, joints: joints)
    }

    public var observation: LivePoseObservation {
        var points: [String: LivePosePoint] = [:]
        for (name, values) in joints where values.count == 3 {
            points[name] = LivePosePoint(x: values[0], y: values[1], confidence: values[2])
        }
        return LivePoseObservation(frameNumber: 0, timestamp: timestamp, width: width, height: height,
                                   bodyCount: bodyCount, joints: points, error: nil)
    }
}

/// The host's current beat, mirrored on the guest.
public struct PartyBeatState: Codable, Equatable, Sendable {
    /// Effective tempo the host hears; nil while an imported track has no known BPM.
    public let bpm: Double?
    public let playing: Bool
    public let sourceName: String
    /// True when the host hears an imported track the guest does not have; the guest plays the beat at the same tempo.
    public let isTrack: Bool
    /// Host clock at which the current bar started, when known; lets the guest join on a bar boundary.
    public let barAnchor: Double?
    public init(bpm: Double?, playing: Bool, sourceName: String, isTrack: Bool, barAnchor: Double?) {
        self.bpm = bpm; self.playing = playing; self.sourceName = sourceName; self.isTrack = isTrack; self.barAnchor = barAnchor
    }
}

/// "Start together": both sides start their beat at `startsAt` on the host's clock.
public struct PartyCountdown: Codable, Equatable, Sendable {
    public let startsAt: Double
    public let bpm: Double?
    public let sourceName: String
    public init(startsAt: Double, bpm: Double?, sourceName: String) {
        self.startsAt = startsAt; self.bpm = bpm; self.sourceName = sourceName
    }
}

public struct PartyFarewell: Codable, Equatable, Sendable {
    public let reason: String?
    public init(reason: String?) { self.reason = reason }
}

public enum PartyMessageError: Error, Equatable, Sendable {
    case unknownType(String)
}

public enum PartyMessage: Equatable, Sendable {
    case hello(PartyHello)
    case welcome(PartyWelcome)
    case rejected(PartyRejection)
    case ping(PartyPing)
    case pong(PartyPong)
    case sharing(PartySharing)
    case pose(PartyPose)
    case beat(PartyBeatState)
    case countdown(PartyCountdown)
    case stop
    case bye(PartyFarewell)

    public var typeName: String {
        switch self {
        case .hello: return "hello"
        case .welcome: return "welcome"
        case .rejected: return "rejected"
        case .ping: return "ping"
        case .pong: return "pong"
        case .sharing: return "sharing"
        case .pose: return "pose"
        case .beat: return "beat"
        case .countdown: return "countdown"
        case .stop: return "stop"
        case .bye: return "bye"
        }
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public init(jsonData: Data) throws { self = try JSONDecoder().decode(PartyMessage.self, from: jsonData) }
    public func frame() throws -> PartyFrame { PartyFrame(kind: .control, payload: try encoded()) }
}

extension PartyMessage: Codable {
    private enum CodingKeys: String, CodingKey { case type, body }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "hello": self = .hello(try container.decode(PartyHello.self, forKey: .body))
        case "welcome": self = .welcome(try container.decode(PartyWelcome.self, forKey: .body))
        case "rejected": self = .rejected(try container.decode(PartyRejection.self, forKey: .body))
        case "ping": self = .ping(try container.decode(PartyPing.self, forKey: .body))
        case "pong": self = .pong(try container.decode(PartyPong.self, forKey: .body))
        case "sharing": self = .sharing(try container.decode(PartySharing.self, forKey: .body))
        case "pose": self = .pose(try container.decode(PartyPose.self, forKey: .body))
        case "beat": self = .beat(try container.decode(PartyBeatState.self, forKey: .body))
        case "countdown": self = .countdown(try container.decode(PartyCountdown.self, forKey: .body))
        case "stop": self = .stop
        case "bye": self = .bye(try container.decode(PartyFarewell.self, forKey: .body))
        default: throw PartyMessageError.unknownType(type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(typeName, forKey: .type)
        switch self {
        case .hello(let body): try container.encode(body, forKey: .body)
        case .welcome(let body): try container.encode(body, forKey: .body)
        case .rejected(let body): try container.encode(body, forKey: .body)
        case .ping(let body): try container.encode(body, forKey: .body)
        case .pong(let body): try container.encode(body, forKey: .body)
        case .sharing(let body): try container.encode(body, forKey: .body)
        case .pose(let body): try container.encode(body, forKey: .body)
        case .beat(let body): try container.encode(body, forKey: .body)
        case .countdown(let body): try container.encode(body, forKey: .body)
        case .stop: break
        case .bye(let body): try container.encode(body, forKey: .body)
        }
    }
}

// MARK: - Video packet

public enum PartyVideoPacketError: Error, Equatable, Sendable {
    case truncated
    case unsupportedVersion(UInt8)
    case invalidDimensions
}

/// One compressed H.264 access unit in AVCC layout (4-byte NAL length prefixes).
/// Keyframes carry the SPS/PPS parameter sets so a late joiner can start decoding.
public struct PartyVideoPacket: Equatable, Sendable {
    public static let formatVersion: UInt8 = 1
    public let timestamp: Double
    public let width: Int
    public let height: Int
    public let isKeyframe: Bool
    public let parameterSets: [Data]
    public let data: Data

    public init(timestamp: Double, width: Int, height: Int, isKeyframe: Bool, parameterSets: [Data], data: Data) {
        self.timestamp = timestamp; self.width = width; self.height = height
        self.isKeyframe = isKeyframe; self.parameterSets = parameterSets; self.data = data
    }

    public func encoded() -> Data {
        var out = Data(capacity: data.count + 64)
        out.append(Self.formatVersion)
        out.append(isKeyframe ? 1 : 0)
        out.appendBigEndian(UInt16(clamping: width))
        out.appendBigEndian(UInt16(clamping: height))
        out.appendBigEndian(timestamp.bitPattern)
        out.append(UInt8(clamping: parameterSets.count))
        for set in parameterSets.prefix(255) {
            out.appendBigEndian(UInt16(clamping: set.count))
            out.append(set.prefix(Int(UInt16.max)))
        }
        out.appendBigEndian(UInt32(clamping: data.count))
        out.append(data)
        return out
    }

    public func frame() -> PartyFrame { PartyFrame(kind: .video, payload: encoded()) }

    public init(decoding payload: Data) throws {
        var cursor = payload.startIndex
        func take(_ count: Int) throws -> Data {
            guard count >= 0, payload.endIndex - cursor >= count else { throw PartyVideoPacketError.truncated }
            defer { cursor += count }
            return payload[cursor..<(cursor + count)]
        }
        let version = try take(1).first!
        guard version == Self.formatVersion else { throw PartyVideoPacketError.unsupportedVersion(version) }
        let flags = try take(1).first!
        let width = Int(try take(2).readBigEndianUInt16())
        let height = Int(try take(2).readBigEndianUInt16())
        guard width > 0, height > 0 else { throw PartyVideoPacketError.invalidDimensions }
        let timestamp = Double(bitPattern: try take(8).readBigEndianUInt64())
        let setCount = Int(try take(1).first!)
        var sets: [Data] = []
        for _ in 0..<setCount {
            let length = Int(try take(2).readBigEndianUInt16())
            sets.append(Data(try take(length)))
        }
        let dataLength = Int(try take(4).readBigEndianUInt32())
        let data = Data(try take(dataLength))
        guard cursor == payload.endIndex else { throw PartyVideoPacketError.truncated }
        self.init(timestamp: timestamp, width: width, height: height, isKeyframe: flags & 1 == 1, parameterSets: sets, data: data)
    }
}

// MARK: - Clock alignment

/// NTP-style offset estimation from ping/pong samples. `offset` is
/// `remoteClock − localClock`; the sample with the smallest round trip wins.
public struct PartyClockSync: Equatable, Sendable {
    public struct Sample: Equatable, Sendable {
        public let offset: Double
        public let roundTrip: Double
        public init(offset: Double, roundTrip: Double) { self.offset = offset; self.roundTrip = roundTrip }
    }
    public private(set) var samples: [Sample] = []
    public let capacity: Int
    public init(capacity: Int = 16) { self.capacity = max(1, capacity) }

    /// `t0` local send, `t1` remote receive, `t2` remote reply, `t3` local receive.
    @discardableResult
    public mutating func record(sentAt t0: Double, remoteReceivedAt t1: Double, remoteRepliedAt t2: Double, receivedAt t3: Double) -> Sample? {
        guard [t0, t1, t2, t3].allSatisfy(\.isFinite), t3 >= t0, t2 >= t1 else { return nil }
        let roundTrip = (t3 - t0) - (t2 - t1)
        guard roundTrip >= 0 else { return nil }
        let sample = Sample(offset: ((t1 - t0) + (t2 - t3)) / 2, roundTrip: roundTrip)
        samples.append(sample)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
        return sample
    }

    public var best: Sample? { samples.min { $0.roundTrip < $1.roundTrip } }
    public var offset: Double? { best?.offset }
    public var roundTrip: Double? { best?.roundTrip }
    public func localTime(forRemote remote: Double) -> Double? { offset.map { remote - $0 } }
    public func remoteTime(forLocal local: Double) -> Double? { offset.map { local + $0 } }
    public mutating func reset() { samples.removeAll() }
}

/// Bar boundaries fall at `anchor + k × barLength`, all on one clock.
public enum PartyBeatGrid {
    public static func barLength(bpm: Double, beatsPerBar: Int = PartyProtocol.beatsPerBar) -> Double? {
        guard bpm.isFinite, bpm > 0, beatsPerBar > 0 else { return nil }
        return Double(beatsPerBar) * 60 / bpm
    }

    /// First bar start at or after `time + minimumLead`.
    public static func nextBarStart(after time: Double, anchor: Double, bpm: Double,
                                    beatsPerBar: Int = PartyProtocol.beatsPerBar, minimumLead: Double = 0) -> Double? {
        guard let bar = barLength(bpm: bpm, beatsPerBar: beatsPerBar), time.isFinite, anchor.isFinite,
              minimumLead.isFinite, minimumLead >= 0 else { return nil }
        let target = time + minimumLead
        let k = ((target - anchor) / bar).rounded(.up)
        return anchor + k * bar
    }

    /// Zero-based beat within the bar at `time`, or nil before the anchor.
    public static func beatIndex(at time: Double, anchor: Double, bpm: Double, beatsPerBar: Int = PartyProtocol.beatsPerBar) -> Int? {
        guard bpm.isFinite, bpm > 0, beatsPerBar > 0, time.isFinite, anchor.isFinite, time >= anchor else { return nil }
        let beats = (time - anchor) / (60 / bpm)
        return Int(beats.rounded(.down)) % beatsPerBar
    }
}

// MARK: - Addresses and room codes

/// `host:port`, `[ipv6]:port` or `name.local:port` typed by hand.
public struct PartyAddress: Equatable, Sendable, CustomStringConvertible {
    public let host: String
    public let port: UInt16
    public init(host: String, port: UInt16) { self.host = host; self.port = port }

    public static func parse(_ text: String) -> PartyAddress? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            guard rest.hasPrefix(":"), let port = parsePort(rest.dropFirst()), !host.isEmpty, host.contains(":") else { return nil }
            return PartyAddress(host: host, port: port)
        }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let port = parsePort(parts[1]) else { return nil }
        let host = String(parts[0])
        guard !host.isEmpty else { return nil }
        return PartyAddress(host: host, port: port)
    }

    private static func parsePort(_ text: Substring) -> UInt16? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = UInt16(text), value > 0 else { return nil }
        return value
    }

    public var description: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
}

/// Four digits shown on the host's screen; both ends derive the link key from it.
public enum PartyRoomCode {
    public static let length = 4

    public static func generate<G: RandomNumberGenerator>(using generator: inout G) -> String {
        (0..<length).map { _ in String(Int.random(in: 0...9, using: &generator)) }.joined()
    }

    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return generate(using: &generator)
    }

    /// Accepts spaces or dashes between digits; anything else is rejected.
    public static func normalize(_ text: String) -> String? {
        let digits = text.filter { !$0.isWhitespace && $0 != "-" }
        guard digits.count == length, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return digits
    }
}

// MARK: - Big-endian helpers

extension Data {
    mutating func appendBigEndian(_ value: UInt16) { append(UInt8(value >> 8)); append(UInt8(value & 0xFF)) }
    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8(value >> 24)); append(UInt8((value >> 16) & 0xFF)); append(UInt8((value >> 8) & 0xFF)); append(UInt8(value & 0xFF))
    }
    mutating func appendBigEndian(_ value: UInt64) {
        appendBigEndian(UInt32(value >> 32)); appendBigEndian(UInt32(value & 0xFFFF_FFFF))
    }
    func readBigEndianUInt16(at index: Data.Index? = nil) -> UInt16 {
        let i = index ?? startIndex
        return UInt16(self[i]) << 8 | UInt16(self[i + 1])
    }
    func readBigEndianUInt32(at index: Data.Index? = nil) -> UInt32 {
        let i = index ?? startIndex
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }
    func readBigEndianUInt64(at index: Data.Index? = nil) -> UInt64 {
        let i = index ?? startIndex
        return UInt64(readBigEndianUInt32(at: i)) << 32 | UInt64(readBigEndianUInt32(at: i + 4))
    }
}
