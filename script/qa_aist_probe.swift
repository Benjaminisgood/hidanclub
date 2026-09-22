import CryptoKit
import Foundation

// Standalone production-loader verification. Synthetic corrupt files are created
// only in the caller's temporary QA directory. The installed source is read-only.
@main
struct AISTProbe {
    struct Failure: Error, CustomStringConvertible { let description: String }
    struct Audit: Decodable {
        struct Record: Decodable {
            let id: String
            let rawSHA256: String
            let optimizedSHA256: String
            let rawNaNCount: Int
            let optimizedNaNCount: Int
            let rawInfCount: Int
            let optimizedInfCount: Int
        }
        let rawNaNCount: Int
        let optimizedNaNCount: Int
        let rawInfCount: Int
        let optimizedInfCount: Int
        let ignoredSequenceCount: Int
        let ignoredFrames: Int
        let sequences: [Record]
    }

    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(description: message) }
    }

    static func rejected(_ label: String, _ action: () throws -> Void) throws {
        do { try action() }
        catch { return }
        throw Failure(description: "Unsafe input was accepted: \(label)")
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func decodeManifest(_ object: [String: Any]) throws -> AISTManifest {
        try JSONDecoder().decode(AISTManifest.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw Failure(description: "Usage: aist-probe DATASET_DIRECTORY QA_TEMP_DIRECTORY")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let scratch = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let manifestData = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(AISTManifest.self, from: manifestData)
        let audit = try JSONDecoder().decode(Audit.self, from: manifestData)
        try manifest.validate()
        try require(manifest.sequenceCount == 1_408, "Expected the complete official 1,408-sequence release")
        try require(manifest.totalFrames == 1_123_873, "Unexpected unique 3D timeline-frame total")
        try require(manifest.totalBinaryBytes == 917_080_368, "Unexpected full double-variant byte count")
        try require(manifest.sourceSHA256 == "8b2a3bfcea233b8d1859a0dc93c7800a8f9e832136ef6828d0b3ddff640ddcfd", "Unexpected source archive hash")
        try require(manifest.sequences.filter(\.ignored).count == audit.ignoredSequenceCount, "Ignore-list sequence count differs")
        try require(manifest.sequences.filter(\.ignored).reduce(0, { $0 + $1.frameCount }) == audit.ignoredFrames, "Ignore-list frame count differs")

        let auditByID = Dictionary(uniqueKeysWithValues: audit.sequences.map { ($0.id, $0) })
        var totalBytes = 0
        var totalVariantFrames = 0
        var nanCounts = [0, 0]
        var infCounts = [0, 0]
        for (index, sequence) in manifest.sequences.enumerated() {
            guard let record = auditByID[sequence.id] else { throw Failure(description: "Missing audit record") }
            for variant in 0...1 {
                let optimized = variant == 1
                let motion = try AISTMotion(directory: root, sequence: sequence, optimized: optimized)
                try require(motion.frameCount == sequence.frameCount, "Frame count differs: \(sequence.id)")
                try require(motion.data.count == sequence.byteCount, "Byte count differs: \(sequence.id)")
                try require(digest(motion.data) == (optimized ? record.optimizedSHA256 : record.rawSHA256), "Every-byte SHA-256 differs: \(sequence.id), optimized=\(optimized)")
                totalBytes += motion.data.count
                totalVariantFrames += motion.frameCount
                var nanCount = 0
                var infCount = 0
                // Exercise joints(at:) on every frame of every sequence, including
                // source missing values. No frames are selected, averaged or omitted.
                for frame in 0..<motion.frameCount {
                    let joints = motion.joints(at: frame)
                    try require(joints.count == 17, "Missing COCO joints: \(sequence.id) frame \(frame)")
                    for joint in joints {
                        for axis in 0..<3 {
                            let value = joint[axis]
                            if value.isNaN { nanCount += 1 }
                            else if value.isInfinite { infCount += 1 }
                        }
                    }
                }
                try require(nanCount == (optimized ? record.optimizedNaNCount : record.rawNaNCount), "NaN preservation differs: \(sequence.id)")
                try require(infCount == (optimized ? record.optimizedInfCount : record.rawInfCount), "Inf preservation differs: \(sequence.id)")
                nanCounts[variant] += nanCount
                infCounts[variant] += infCount
                try require(motion.joints(at: -1).isEmpty && motion.joints(at: motion.frameCount).isEmpty, "Out-of-range access returned a fabricated frame")

                // First, interior and final exports retain exact source byte order.
                let middle = motion.frameCount / 2
                for range in [0...0, middle...min(motion.frameCount - 1, middle + 59), (motion.frameCount - 1)...(motion.frameCount - 1)] {
                    let exported = try motion.bytes(in: range)
                    let expected = motion.data.subdata(in: (range.lowerBound * AISTMotion.bytesPerFrame)..<((range.upperBound + 1) * AISTMotion.bytesPerFrame))
                    try require(exported == expected, "Source-order export differs: \(sequence.id) \(range)")
                }
            }
            if (index + 1) % 352 == 0 { print("Verified \(index + 1)/\(manifest.sequenceCount) sequences, both variants, all frames and SHA-256 hashes.") }
        }
        try require(totalBytes == manifest.totalBinaryBytes, "Aggregated byte count differs")
        try require(totalVariantFrames == manifest.totalFrames * 2, "Aggregated frame count differs")
        try require(nanCounts == [audit.rawNaNCount, audit.optimizedNaNCount], "Aggregated NaN counts differ")
        try require(infCounts == [audit.rawInfCount, audit.optimizedInfCount], "Aggregated Inf counts differ")

        let object = try JSONSerialization.jsonObject(with: manifestData) as! [String: Any]
        try verifyManifestRejections(object)
        try verifySyntheticLoaderAndExports(object: object, scratch: scratch)
        try require(try Data(contentsOf: root.appendingPathComponent("manifest.json")) == manifestData, "Source manifest was changed")
        print("PASS: all 1,408 sequences × 2 variants; 2,247,746 full frame reads; 917,080,368 bytes and 2,816 SHA-256 hashes verified. Raw/optimized NaN counts: \(nanCounts); Inf counts: \(infCounts).")
        print("PASS: manifest format/order/dimensions/counts/overflow checks; canonical paths and symlink containment; truncated/extended/missing/non-file rejection; exact single-frame and inclusive contiguous exports; Float64 and NaN bit-pattern preservation; all export bounds. Installed dataset unchanged.")
    }

    static func verifyManifestRejections(_ original: [String: Any]) throws {
        for (key, badValue) in [
            ("schemaVersion", 2 as Any), ("fps", 30), ("coordinateType", "float32-little-endian"),
            ("arrayOrder", "joint,frame,xyz"), ("jointCount", 16), ("coordinateCount", 2),
            ("sequenceCount", 1), ("totalFrames", 42), ("totalBinaryBytes", 0)
        ] {
            var object = original
            object[key] = badValue
            try rejected("manifest \(key)") { try decodeManifest(object).validate() }
        }
        var reordered = original
        reordered["jointNamesCOCO"] = AISTManifest.cocoJointNames.reversed().map { $0 }
        try rejected("COCO names in wrong order") { try decodeManifest(reordered).validate() }
        var missing = original
        missing.removeValue(forKey: "coordinateType")
        try rejected("missing coordinate metadata") { _ = try decodeManifest(missing) }
        let records = original["sequences"] as! [[String: Any]]
        for (key, value) in [
            ("frameCount", 0 as Any), ("frameCount", -1), ("frameCount", Int.max),
            ("fps", 30), ("byteCount", 0), ("id", "../outside")
        ] {
            var object = original
            var changedRecords = records
            changedRecords[0][key] = value
            object["sequences"] = changedRecords
            try rejected("sequence \(key)=\(value)") { try decodeManifest(object).validate() }
        }
        for badPath in ["../outside.f64", "/tmp/outside.f64", "sequences/../../outside.f64", "sequences/./outside.f64", "sequences//outside.f64", "%2e%2e/outside.f64", "sequences\\outside.f64", "sequences/\0outside.f64"] {
            for key in ["rawPath", "optimizedPath"] {
                var object = original
                var changedRecords = records
                changedRecords[0][key] = badPath
                object["sequences"] = changedRecords
                try rejected("unsafe \(key): \(badPath.debugDescription)") { try decodeManifest(object).validate() }
            }
        }
        var duplicate = original
        var duplicateRecords = records
        duplicateRecords[1] = duplicateRecords[0]
        duplicate["sequences"] = duplicateRecords
        try rejected("duplicate sequence IDs") { try decodeManifest(duplicate).validate() }

        var huge = original
        var hugeRecords = Array(records.prefix(2))
        let hugeFrames = Int.max / AISTMotion.bytesPerFrame
        for index in hugeRecords.indices {
            hugeRecords[index]["frameCount"] = hugeFrames
            hugeRecords[index]["byteCount"] = hugeFrames * AISTMotion.bytesPerFrame
        }
        huge["sequences"] = hugeRecords
        huge["sequenceCount"] = hugeRecords.count
        huge["totalFrames"] = hugeFrames * hugeRecords.count
        huge["totalBinaryBytes"] = 0
        try rejected("aggregate byte multiplication overflow") { try decodeManifest(huge).validate() }

        var overflowingSum = original
        var overflowingRecords = Array(records.prefix(409))
        for index in overflowingRecords.indices {
            overflowingRecords[index]["frameCount"] = hugeFrames
            overflowingRecords[index]["byteCount"] = hugeFrames * AISTMotion.bytesPerFrame
        }
        overflowingSum["sequences"] = overflowingRecords
        overflowingSum["sequenceCount"] = overflowingRecords.count
        overflowingSum["totalFrames"] = 0
        overflowingSum["totalBinaryBytes"] = 0
        try rejected("aggregate frame addition overflow") { try decodeManifest(overflowingSum).validate() }
    }

    static func verifySyntheticLoaderAndExports(object: [String: Any], scratch: URL) throws {
        let fixtureRoot = scratch.appendingPathComponent("fixture", isDirectory: true)
        let sequences = fixtureRoot.appendingPathComponent("sequences", isDirectory: true)
        try FileManager.default.createDirectory(at: sequences, withIntermediateDirectories: true)
        var record = (object["sequences"] as! [[String: Any]])[0]
        record["frameCount"] = 4
        record["byteCount"] = 4 * AISTMotion.bytesPerFrame
        let sequence = try JSONDecoder().decode(AISTSequence.self, from: JSONSerialization.data(withJSONObject: record))
        let source = fixtureRoot.appendingPathComponent(sequence.rawPath)
        let patterns: [UInt64] = [
            0x0000000000000000, 0x8000000000000000, 0x3ff8000000000000,
            0xc002000000000000, 0x7ff0000000000000, 0xfff0000000000000,
            0x7ff8000000000042, 0x0000000000000001, 0x7fefffffffffffff
        ]
        var payload = Data()
        for index in 0..<(4 * 51) {
            var bits = patterns[index % patterns.count].littleEndian
            withUnsafeBytes(of: &bits) { payload.append(contentsOf: $0) }
        }
        try payload.write(to: source)
        let motion = try AISTMotion(directory: fixtureRoot, sequence: sequence, optimized: false)
        for frame in 0..<4 {
            let joints = motion.joints(at: frame)
            for joint in 0..<17 {
                for axis in 0..<3 {
                    try require(joints[joint][axis].bitPattern == patterns[(frame * 51 + joint * 3 + axis) % patterns.count], "Float64 little-endian bit pattern changed")
                }
            }
        }
        for start in 0..<4 {
            for end in start..<4 {
                let exported = try motion.bytes(in: start...end)
                try require(exported == payload.subdata(in: (start * 408)..<((end + 1) * 408)), "Inclusive contiguous export changed bytes")
                let exportURL = scratch.appendingPathComponent("export-\(start)-\(end).f64")
                try exported.write(to: exportURL, options: .atomic)
                let restored = try AISTMotion(url: exportURL, frameCount: end - start + 1)
                try require(restored.data == exported, "Export/reload round-trip changed bytes")
                for frame in 0..<restored.frameCount {
                    for (actual, expected) in zip(restored.joints(at: frame), motion.joints(at: start + frame)) {
                        for axis in 0..<3 { try require(actual[axis].bitPattern == expected[axis].bitPattern, "Export changed a Float64 coordinate") }
                    }
                }
            }
        }
        for range in [-1...0, 0...4, 4...4, Int.min...0, 0...Int.max] {
            try rejected("frame export \(range)") { _ = try motion.bytes(in: range) }
        }
        for frame in [-1, 4, Int.min, Int.max] { try require(motion.joints(at: frame).isEmpty, "Invalid frame fabricated data") }
        for frameCount in [0, -1, Int.max, 3, 5] {
            try rejected("invalid frame count \(frameCount)") { _ = try AISTMotion(url: source, frameCount: frameCount) }
        }
        let truncated = scratch.appendingPathComponent("truncated.f64")
        try payload.dropLast().write(to: truncated)
        try rejected("truncated file") { _ = try AISTMotion(url: truncated, frameCount: 4) }
        let extended = scratch.appendingPathComponent("extended.f64")
        try (payload + Data([0])).write(to: extended)
        try rejected("extended file") { _ = try AISTMotion(url: extended, frameCount: 4) }
        try rejected("missing file") { _ = try AISTMotion(url: scratch.appendingPathComponent("missing.f64"), frameCount: 4) }
        try rejected("directory as motion") { _ = try AISTMotion(url: fixtureRoot, frameCount: 4) }
        try rejected("network URL as motion") { _ = try AISTMotion(url: URL(string: "https://example.invalid/motion.f64")!, frameCount: 4) }

        let escapedRoot = scratch.appendingPathComponent("escaped", isDirectory: true)
        try FileManager.default.createDirectory(at: escapedRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: escapedRoot.appendingPathComponent("sequences"), withDestinationURL: sequences)
        try rejected("sequences-directory symlink escapes selected root") {
            _ = try AISTMotion(directory: escapedRoot, sequence: sequence, optimized: false)
        }
        let outside = scratch.appendingPathComponent("outside.f64")
        try payload.write(to: outside)
        let optimizedPath = fixtureRoot.appendingPathComponent(sequence.optimizedPath)
        try FileManager.default.createSymbolicLink(at: optimizedPath, withDestinationURL: outside)
        try rejected("motion-file symlink escapes selected root") {
            _ = try AISTMotion(directory: fixtureRoot, sequence: sequence, optimized: true)
        }
        try FileManager.default.removeItem(at: optimizedPath)
        try FileManager.default.createSymbolicLink(at: optimizedPath, withDestinationURL: source)
        let linked = try AISTMotion(directory: fixtureRoot, sequence: sequence, optimized: true)
        try require(linked.data == payload, "Safe in-directory symlink failed")
        let rootAlias = scratch.appendingPathComponent("fixture-alias")
        try FileManager.default.createSymbolicLink(at: rootAlias, withDestinationURL: fixtureRoot)
        let aliased = try AISTMotion(directory: rootAlias, sequence: sequence, optimized: false)
        try require(aliased.data == payload, "Explicitly selected directory symlink failed")
        try require(try Data(contentsOf: source) == payload, "Original fixture was modified by export")
    }
}
