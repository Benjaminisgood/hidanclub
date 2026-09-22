import Foundation

public struct AISTSequence: Codable, Identifiable, Sendable, Hashable {
    public let id: String
    public let genreCode: String
    public let genreName: String
    public let dancerID: String
    public let musicID: String
    public let frameCount: Int
    public let fps: Double
    public let rawPath: String
    public let optimizedPath: String
    public let byteCount: Int
    public let ignored: Bool
    public var duration: Double { Double(frameCount) / fps }
    public var choreographyCode: String { id.split(separator: "_").map(String.init).first { $0.hasPrefix("ch") } ?? "" }
    public var isBasic: Bool { id.split(separator: "_").contains("sBM") }
    public var category: String { isBasic ? "基础动作" : "进阶组合" }
    public var bpm: Int? {
        guard let index = musicID.last?.wholeNumberValue, (0...5).contains(index) else { return nil }
        return musicID.hasPrefix("mHO") ? 110 + 5 * index : 80 + 10 * index
    }

    fileprivate func validate() throws {
        let validID = id.range(of: "^g[A-Z]{2}_s[A-Z]{2}_cAll_d[0-9]+_m[A-Z]{2}[0-9]+_ch[0-9]+$", options: .regularExpression) != nil
        guard validID, frameCount > 0, frameCount <= Int.max / AISTMotion.bytesPerFrame,
              fps == 60, byteCount == frameCount * AISTMotion.bytesPerFrame,
              rawPath == "sequences/\(id).raw.f64",
              optimizedPath == "sequences/\(id).optimized.f64" else {
            throw AISTDataError.invalidManifest
        }
    }

    /// A manifest is data, not permission to read arbitrary files. Resolve both
    /// the selected directory and its candidate so symlinks cannot escape it.
    public func motionURL(in directory: URL, optimized: Bool) throws -> URL {
        try validate()
        guard directory.isFileURL else { throw AISTDataError.unsafePath }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(optimized ? optimizedPath : rawPath)
            .standardizedFileURL.resolvingSymlinksInPath()
        let rootParts = root.pathComponents
        let candidateParts = candidate.pathComponents
        guard candidateParts.count > rootParts.count,
              Array(candidateParts.prefix(rootParts.count)) == rootParts else {
            throw AISTDataError.unsafePath
        }
        return candidate
    }

    /// Both published layers are required. A sequence with only one file is not a playable action.
    public func requireBothCoordinateFiles(in directory: URL) throws {
        let expected = frameCount * AISTMotion.bytesPerFrame
        for optimized in [false, true] {
            let url = try motionURL(in: directory, optimized: optimized)
            let values: URLResourceValues
            do { values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) }
            catch { throw AISTDataError.missingCoordinateLayer(id) }
            guard values.isRegularFile == true, values.fileSize == expected else {
                throw AISTDataError.missingCoordinateLayer(id)
            }
        }
    }
}

public struct AISTManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let fps: Double
    public let jointNamesCOCO: [String]
    public let coordinateType: String
    public let arrayOrder: String
    public let jointCount: Int
    public let coordinateCount: Int
    public let sourceURL: String
    public let licenseURL: String
    public let sourceSHA256: String
    public let totalFrames: Int
    public let totalBinaryBytes: Int
    public let sequenceCount: Int
    public let sequences: [AISTSequence]

    public static let cocoJointNames = [
        "nose", "left_eye", "right_eye", "left_ear", "right_ear",
        "left_shoulder", "right_shoulder", "left_elbow", "right_elbow",
        "left_wrist", "right_wrist", "left_hip", "right_hip", "left_knee",
        "right_knee", "left_ankle", "right_ankle"
    ]

    public func validate() throws {
        guard schemaVersion == 1, fps == 60, jointNamesCOCO == Self.cocoJointNames,
              coordinateType == "float64-little-endian", arrayOrder == "frame,joint,xyz",
              jointCount == 17, coordinateCount == 3,
              sequenceCount == sequences.count, sequenceCount > 0,
              Set(sequences.map(\.id)).count == sequences.count else {
            throw AISTDataError.invalidManifest
        }
        var countedFrames = 0
        for sequence in sequences {
            try sequence.validate()
            let (sum, overflow) = countedFrames.addingReportingOverflow(sequence.frameCount)
            guard !overflow else { throw AISTDataError.invalidManifest }
            countedFrames = sum
        }
        let (expectedBytes, overflow) = countedFrames.multipliedReportingOverflow(by: AISTMotion.bytesPerFrame * 2)
        guard !overflow, totalFrames == countedFrames, totalBinaryBytes == expectedBytes else {
            throw AISTDataError.invalidManifest
        }
    }
}

public enum AISTDataError: LocalizedError, Equatable {
    case invalidManifest
    case invalidLength(expected: Int, actual: Int)
    case outOfBounds
    case unsafePath
    case missingCoordinateLayer(String)
    public var errorDescription: String? {
        switch self {
        case .invalidManifest: return "动作索引不完整或格式不兼容，请重新完成 AIST++ 数据适配。"
        case .invalidLength(let expected, let actual): return "动作文件不完整：应有 \(expected) 字节，实际 \(actual) 字节。"
        case .outOfBounds: return "帧范围超出动作序列。"
        case .unsafePath: return "动作文件路径不在所选数据目录内，已停止读取。"
        case .missingCoordinateLayer(let id): return "动作 \(id) 必须同时有原始逐帧重建和官方时序优化两套坐标，且帧数一致。缺一则不载入。"
        }
    }
}

/// Memory-mapped Float64 values, with original world coordinates and all frames.
public struct AISTMotion: Sendable {
    public static let bytesPerFrame = 17 * 3 * MemoryLayout<UInt64>.size
    public let data: Data
    public let frameCount: Int
    public init(directory: URL, sequence: AISTSequence, optimized: Bool) throws {
        try self.init(url: sequence.motionURL(in: directory, optimized: optimized), frameCount: sequence.frameCount)
    }
    public init(url: URL, frameCount: Int) throws {
        guard frameCount > 0, frameCount <= Int.max / Self.bytesPerFrame else { throw AISTDataError.invalidManifest }
        guard url.isFileURL else { throw AISTDataError.unsafePath }
        let expected = frameCount * Self.bytesPerFrame
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw AISTDataError.unsafePath }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == expected else { throw AISTDataError.invalidLength(expected: expected, actual: data.count) }
        self.data = data; self.frameCount = frameCount
    }
    public func joints(at frame: Int) -> [SIMD3<Double>] {
        guard (0..<frameCount).contains(frame) else { return [] }
        return data.withUnsafeBytes { bytes in
            (0..<17).map { joint in
                let offset = (frame * 51 + joint * 3) * 8
                func coordinate(_ axis: Int) -> Double {
                    Double(bitPattern: UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + axis * 8, as: UInt64.self)))
                }
                return SIMD3(coordinate(0), coordinate(1), coordinate(2))
            }
        }
    }
    /// Exact contiguous byte slice; no resampling, conversion or normalization.
    public func bytes(in range: ClosedRange<Int>) throws -> Data {
        guard range.lowerBound >= 0, range.upperBound < frameCount else { throw AISTDataError.outOfBounds }
        return data.subdata(in: (range.lowerBound * Self.bytesPerFrame)..<((range.upperBound + 1) * Self.bytesPerFrame))
    }
}
