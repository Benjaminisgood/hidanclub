import Foundation

public enum PracticeMotionError: LocalizedError, Equatable {
    case incompletePair(String)
    case unknownMove(String)

    public var errorDescription: String? {
        switch self {
        case .incompletePair(let id): return "练习动作 \(id) 必须同时有逐帧采样和时序平滑两套坐标，且帧数一致。"
        case .unknownMove(let id): return "没有找到练习动作 \(id)。"
        }
    }
}

/// App-authored standing practice coordinates in the AIST++ Float64 layout:
/// 60 FPS, COCO 17 joints, little-endian `(frame, joint, xyz)`.
/// Every move writes both a per-frame sample and a wrapped temporal smooth.
/// These are not AIST++ measurements and are not an official optimization.
public enum PracticeMotionLibrary {
    public static let fps = 60.0
    public static let version = 1
    public static let jointCount = 17

    public static func frameCount(for move: DanceMove) -> Int {
        let bpm = Double(move.bpmMin + move.bpmMax) / 2
        return max(180, Int((8 * 60 / bpm * fps).rounded()))
    }

    public static func makePair(for move: DanceMove) -> (raw: [[SIMD3<Double>]], optimized: [[SIMD3<Double>]]) {
        let count = frameCount(for: move)
        let clean = (0..<count).map { sample(moveID: move.id, t: Double($0) / Double(count)) }
        return (jitter(clean, id: move.id), smooth(clean))
    }

    public static func install(into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if try installedManifestMatches(directory) { return }
        var entries: [Manifest.Entry] = []
        for move in DanceCatalog.moves {
            let pair = makePair(for: move)
            let count = frameCount(for: move)
            let raw = try encode(pair.raw, frameCount: count, id: move.id)
            let optimized = try encode(pair.optimized, frameCount: count, id: move.id)
            guard raw.count == optimized.count else { throw PracticeMotionError.incompletePair(move.id) }
            let rawName = "\(move.id).raw.f64"
            let optimizedName = "\(move.id).optimized.f64"
            try atomic(raw, at: directory.appendingPathComponent(rawName))
            try atomic(optimized, at: directory.appendingPathComponent(optimizedName))
            entries.append(Manifest.Entry(id: move.id, frameCount: count, byteCount: raw.count, raw: rawName, optimized: optimizedName))
        }
        let manifest = Manifest(version: version, fps: fps, jointCount: jointCount, moves: entries)
        let data = try JSONEncoder().encode(manifest)
        try atomic(data, at: directory.appendingPathComponent("manifest.json"))
        guard try installedManifestMatches(directory) else { throw PracticeMotionError.incompletePair("manifest") }
    }

    public static func frameCount(in directory: URL, id: String) throws -> Int {
        guard let entry = try manifest(in: directory).moves.first(where: { $0.id == id }) else {
            throw PracticeMotionError.unknownMove(id)
        }
        return entry.frameCount
    }

    /// Loads one layer only after both files exist and share the indexed frame count.
    public static func load(in directory: URL, id: String, optimized: Bool) throws -> AISTMotion {
        guard let entry = try manifest(in: directory).moves.first(where: { $0.id == id }) else {
            throw PracticeMotionError.unknownMove(id)
        }
        let expected = entry.frameCount * AISTMotion.bytesPerFrame
        let rawURL = directory.appendingPathComponent(entry.raw)
        let optimizedURL = directory.appendingPathComponent(entry.optimized)
        guard fileSize(rawURL) == expected, fileSize(optimizedURL) == expected, entry.byteCount == expected else {
            throw PracticeMotionError.incompletePair(id)
        }
        return try AISTMotion(url: optimized ? optimizedURL : rawURL, frameCount: entry.frameCount)
    }

    private struct Manifest: Codable, Equatable {
        struct Entry: Codable, Equatable {
            let id: String
            let frameCount: Int
            let byteCount: Int
            let raw: String
            let optimized: String
        }
        let version: Int
        let fps: Double
        let jointCount: Int
        let moves: [Entry]
    }

    private static func manifest(in directory: URL) throws -> Manifest {
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    private static func installedManifestMatches(_ directory: URL) throws -> Bool {
        guard let manifest = try? manifest(in: directory),
              manifest.version == version, manifest.fps == fps, manifest.jointCount == jointCount,
              manifest.moves.map(\.id) == DanceCatalog.moves.map(\.id) else { return false }
        return manifest.moves.allSatisfy { entry in
            let expected = entry.frameCount * AISTMotion.bytesPerFrame
            return entry.byteCount == expected
                && fileSize(directory.appendingPathComponent(entry.raw)) == expected
                && fileSize(directory.appendingPathComponent(entry.optimized)) == expected
        }
    }

    private static func fileSize(_ url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { return nil }
        return values.fileSize
    }

    private static func encode(_ frames: [[SIMD3<Double>]], frameCount: Int, id: String) throws -> Data {
        guard frames.count == frameCount, frames.allSatisfy({ $0.count == jointCount }) else {
            throw PracticeMotionError.incompletePair(id)
        }
        var data = Data()
        data.reserveCapacity(frameCount * jointCount * 3 * 8)
        for frame in frames {
            for joint in frame {
                for axis in 0..<3 {
                    var bits = joint[axis].bitPattern.littleEndian
                    withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
                }
            }
        }
        return data
    }

    private static func atomic(_ data: Data, at url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).partial")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.moveItem(at: temporary, to: url)
    }

    private static func smooth(_ frames: [[SIMD3<Double>]]) -> [[SIMD3<Double>]] {
        let count = frames.count
        return frames.indices.map { frame in
            (0..<jointCount).map { joint in
                var sum = SIMD3<Double>.zero
                for offset in -2...2 {
                    let index = (frame + offset + count) % count
                    sum += frames[index][joint]
                }
                return sum / 5
            }
        }
    }

    private static func jitter(_ frames: [[SIMD3<Double>]], id: String) -> [[SIMD3<Double>]] {
        var seed: UInt64 = 14_695_981_039_346_656_037
        for byte in id.utf8 { seed = (seed ^ UInt64(byte)) &* 1_099_511_628_211 }
        func unit(_ frame: Int, _ joint: Int, _ axis: Int) -> Double {
            var value = seed &+ UInt64(frame &* 131) &+ UInt64(joint &* 17) &+ UInt64(axis &* 3)
            value ^= value >> 12
            value ^= value << 25
            value ^= value >> 27
            value = value &* 2_685_821_657_736_338_717
            return Double(value % 2001) / 1000 - 1
        }
        return frames.enumerated().map { frame, joints in
            joints.enumerated().map { joint, point in
                var value = SIMD3(
                    point.x + unit(frame, joint, 0) * 0.45,
                    point.y + unit(frame, joint, 1) * 0.45,
                    point.z + unit(frame, joint, 2) * 0.45
                )
                if joint == 9, frame % 120 == 60 { value.x = .nan }
                return value
            }
        }
    }

    /// `t` is the phase in `0..<1` across one looping phrase.
    private static func sample(moveID: String, t: Double) -> [SIMD3<Double>] {
        var pose = standing()
        let bounce8 = 0.5 - 0.5 * cos(t * 2 * .pi * 8)
        let sway4 = sin(t * 2 * .pi * 4)
        switch moveID {
        case "hiphop-bounce":
            squat(&pose, amount: bounce8, depth: 10)
        case "hiphop-rock":
            squat(&pose, amount: abs(sway4) * 0.35, depth: 6)
            shift(&pose, indices: upper, SIMD3(0, 0, 14 * sway4))
            shift(&pose, indices: arms, SIMD3(0, 0, -8 * sway4))
        case "hiphop-step-touch":
            step(&pose, side: sway4, reach: 18)
        case "hiphop-two-step":
            step(&pose, side: sin(t * 2 * .pi * 2), reach: 16)
            step(&pose, side: sin(t * 2 * .pi * 8) * 0.45, reach: 8)
        case "hiphop-running-man":
            let left = max(0, sin(t * 2 * .pi * 4))
            let right = max(0, sin(t * 2 * .pi * 4 + .pi))
            pose[13] += SIMD3(0, 22 * left, 6 * left)
            pose[15] += SIMD3(0, 26 * left, 12 * left)
            pose[14] += SIMD3(0, 22 * right, -4 * right)
            pose[16] += SIMD3(0, 4 * right, -12 * right)
            squat(&pose, amount: max(left, right), depth: 6)
        case "hiphop-party-groove":
            squat(&pose, amount: bounce8, depth: 8)
            step(&pose, side: sin(t * 2 * .pi * 2) * 0.7, reach: 14)
        case "hiphop-arm-groove":
            squat(&pose, amount: bounce8 * 0.6, depth: 7)
            swingArms(&pose, amount: sway4)
        case "popping-isolation":
            shift(&pose, indices: head + [5, 6], SIMD3(9 * sin(t * 2 * .pi * 2), 0, 0))
        case "popping-arm-wave":
            let shoulder = sin(t * 2 * .pi * 4)
            let elbow = sin((t * 4 - 0.08) * 2 * .pi)
            let wrist = sin((t * 4 - 0.16) * 2 * .pi)
            pose[6] += SIMD3(0, 3 * shoulder, 0)
            pose[8] += SIMD3(0, 8 * elbow, 4 * elbow)
            pose[10] += SIMD3(5 * wrist, 12 * wrist, 6 * wrist)
        case "popping-dime-stop":
            let local = (t * 8).truncatingRemainder(dividingBy: 1)
            let travel = min(1, local / 0.4)
            let direction: Double = Int(t * 8) % 2 == 0 ? 1 : -1
            pose[8] += SIMD3(8 * travel * direction, 2 * travel, 3 * travel)
            pose[10] += SIMD3(16 * travel * direction, 6 * travel, 8 * travel)
        case "popping-hand-path":
            let angle = t * 2 * .pi * 2
            pose[8] += SIMD3(6 * cos(angle), 4 * sin(angle), 0)
            pose[10] += SIMD3(14 * cos(angle), 10 * sin(angle), 4 * sin(angle))
        case "locking-point":
            let extend = 0.5 - 0.5 * cos(t * 2 * .pi * 4)
            pose[8] = mix(pose[8], SIMD3(-34, 148, 8), extend)
            pose[10] = mix(pose[10], SIMD3(-54, 152, 14), extend)
        case "locking-lock":
            let local = (t * 4).truncatingRemainder(dividingBy: 1)
            let held = local > 0.5 ? 1.0 : local / 0.5
            pose[7] += SIMD3(-8 * held, 12 * held, 6 * held)
            pose[9] += SIMD3(-10 * held, 18 * held, 8 * held)
            pose[8] += SIMD3(8 * held, 12 * held, 6 * held)
            pose[10] += SIMD3(10 * held, 18 * held, 8 * held)
            squat(&pose, amount: held, depth: 6)
        case "house-jack":
            squat(&pose, amount: bounce8, depth: 14)
            shift(&pose, indices: head + [5, 6], SIMD3(0, 0, 6 * sway4))
        case "house-side-step":
            squat(&pose, amount: bounce8 * 0.45, depth: 8)
            step(&pose, side: sway4, reach: 20)
        case "house-weight-shift":
            let lift = 0.5 - 0.5 * cos(t * 2 * .pi * 4)
            if sway4 >= 0 {
                pose[15].y += 9 * lift
                shift(&pose, indices: upper + hips, SIMD3(5 * lift, -2 * lift, 0))
            } else {
                pose[16].y += 9 * lift
                shift(&pose, indices: upper + hips, SIMD3(-5 * lift, -2 * lift, 0))
            }
        default:
            squat(&pose, amount: bounce8 * 0.5, depth: 8)
        }
        return pose
    }

    private static let head = [0, 1, 2, 3, 4]
    private static let arms = [7, 8, 9, 10]
    private static let hips = [11, 12]
    private static let upper = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

    private static func standing() -> [SIMD3<Double>] {
        var pose = Array(repeating: SIMD3<Double>.zero, count: jointCount)
        pose[0] = SIMD3(0, 168, 2)
        pose[1] = SIMD3(3.4, 170.5, 5.5)
        pose[2] = SIMD3(-3.4, 170.5, 5.5)
        pose[3] = SIMD3(8.2, 168, -1)
        pose[4] = SIMD3(-8.2, 168, -1)
        pose[5] = SIMD3(18, 146, 0)
        pose[6] = SIMD3(-18, 146, 0)
        pose[7] = SIMD3(24, 116, 6)
        pose[8] = SIMD3(-24, 116, 6)
        pose[9] = SIMD3(26, 90, 10)
        pose[10] = SIMD3(-26, 90, 10)
        pose[11] = SIMD3(11, 98, 0)
        pose[12] = SIMD3(-11, 98, 0)
        pose[13] = SIMD3(12, 52, 1)
        pose[14] = SIMD3(-12, 52, 1)
        pose[15] = SIMD3(13, 6, 0)
        pose[16] = SIMD3(-13, 6, 0)
        return pose
    }

    private static func shift(_ pose: inout [SIMD3<Double>], indices: [Int], _ delta: SIMD3<Double>) {
        for index in indices { pose[index] += delta }
    }

    private static func squat(_ pose: inout [SIMD3<Double>], amount: Double, depth: Double) {
        let drop = depth * amount
        shift(&pose, indices: upper + hips, SIMD3(0, -drop, 0))
        shift(&pose, indices: [13, 14], SIMD3(0, -drop * 0.15, 4 * amount))
    }

    private static func step(_ pose: inout [SIMD3<Double>], side: Double, reach: Double) {
        shift(&pose, indices: upper + hips, SIMD3(reach * side, -3 * abs(side), 0))
        if side >= 0 {
            pose[13] += SIMD3(reach * 0.55 * side, 0, 0)
            pose[15] += SIMD3(reach * 0.9 * side, 2 * side, 0)
        } else {
            pose[14] += SIMD3(reach * 0.55 * side, 0, 0)
            pose[16] += SIMD3(reach * 0.9 * side, 2 * -side, 0)
        }
    }

    private static func swingArms(_ pose: inout [SIMD3<Double>], amount: Double) {
        pose[7] += SIMD3(0, 4 * amount, 8 * amount)
        pose[9] += SIMD3(0, 6 * amount, 14 * amount)
        pose[8] += SIMD3(0, -4 * amount, -8 * amount)
        pose[10] += SIMD3(0, -6 * amount, -14 * amount)
    }

    private static func mix(_ start: SIMD3<Double>, _ end: SIMD3<Double>, _ amount: Double) -> SIMD3<Double> {
        start * (1 - amount) + end * amount
    }
}
