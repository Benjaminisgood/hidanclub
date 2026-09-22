import Foundation
import Combine
import CryptoKit

/// Verifies library import against a real exported motion file plus deliberate
/// variants. The real file is only ever read; its bytes are hashed before and
/// after. Coordinates, confidences, frame order and original PTS must survive
/// an import bit for bit, and every refusal must name the offending field.
@main struct LibraryImportProbe {
    struct Failure: Error { let message: String }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    @MainActor static func loaded(_ store: CapturedLibraryStore) async throws {
        let deadline = Date().addingTimeInterval(20)
        while store.isLoading {
            if Date() > deadline { throw Failure(message: "Loading timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func write(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    @MainActor static func main() async throws {
        guard CommandLine.arguments.count >= 3 else {
            FileHandle.standardError.write("usage: LibraryImportProbe <library-dir> <real-motion.json>\n".data(using: .utf8)!)
            throw Failure(message: "Missing arguments")
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let sourceURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let variants = URL(fileURLWithPath: CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : NSTemporaryDirectory(), isDirectory: true)
        try FileManager.default.createDirectory(at: variants, withIntermediateDirectories: true)
        let originalBytes = try Data(contentsOf: sourceURL)
        let originalHash = hash(originalBytes)

        // Independent view of the same file, without the production decoder.
        guard let raw = try JSONSerialization.jsonObject(with: originalBytes) as? [String: Any],
              let rawReport = raw["report"] as? [String: Any],
              let rawFrames = rawReport["frames"] as? [[String: Any]],
              let rawName = raw["name"] as? String else { throw Failure(message: "Real file is not a motion document") }
        let rawSegments = raw["segments"] as? [[String: Any]] ?? []
        let rawSpanLower = rawSegments.compactMap { $0["startFrame"] as? Int }.min() ?? 0
        let rawSpanUpper = rawSegments.compactMap { $0["endFrame"] as? Int }.max() ?? rawFrames.count - 1

        // 1. Decode the real export.
        let decoded = try CapturedMotionImport.load(from: sourceURL)
        let model = decoded.model
        try require(decoded.notes.isEmpty, "A genuine app export needs no metadata repair; got \(decoded.notes)")
        try require(model.frameCount == rawFrames.count, "Frame count matches the file (\(model.frameCount) vs \(rawFrames.count))")
        try require(model.name == rawName, "Name preserved: \(model.name)")
        try require(model.report.frames.count == rawFrames.count, "No frame dropped or duplicated")
        for (index, frame) in model.report.frames.enumerated() {
            let rawFrame = rawFrames[index]
            guard frame.timestamp == rawFrame["timestamp"] as? Double,
                  Int64(rawFrame["timestampValue"] as? Int ?? -1) == frame.timestampValue,
                  Int32(rawFrame["timestampTimescale"] as? Int ?? -1) == frame.timestampTimescale,
                  frame.bodyCount == rawFrame["bodyCount"] as? Int,
                  frame.ambiguous == rawFrame["ambiguous"] as? Bool else {
                throw Failure(message: "Frame \(index) timing or detection metadata changed")
            }
            let rawJoints = rawFrame["joints"] as? [String: [String: Any]] ?? [:]
            try require(frame.joints.count == rawJoints.count, "Frame \(index) keeps all \(rawJoints.count) joints")
            for (name, joint) in frame.joints {
                guard let rawJoint = rawJoints[name],
                      joint.x == rawJoint["x"] as? Double,
                      joint.y == rawJoint["y"] as? Double,
                      joint.confidence == rawJoint["confidence"] as? Double else {
                    throw Failure(message: "Frame \(index) joint \(name) coordinates or confidence changed")
                }
            }
        }
        try require(model.segments.count == rawSegments.count, "Segment list preserved (\(model.segments.count))")
        for (index, segment) in model.segments.enumerated() {
            let rawSegment = rawSegments[index]
            try require(segment.startFrame == rawSegment["startFrame"] as? Int && segment.endFrame == rawSegment["endFrame"] as? Int
                        && segment.repeats == rawSegment["repeats"] as? Int && segment.name == rawSegment["name"] as? String,
                        "Segment \(index) range, repeats and name preserved")
        }
        try model.validate()
        try require(model.hasPlayableMotion, "Real file has a playable skeleton")
        print("Real file decoded: name=\(model.name) frames=\(model.frameCount) detected=\(model.report.detectedFrameCount) usable=\(model.usableFrameCount) segments=\(model.segments.map { "\($0.startFrame)-\($0.endFrame)x\($0.repeats)" }.joined(separator: ",")) practiceSeconds=\(String(format: "%.2f", model.segments.reduce(0) { $0 + model.duration(of: $1) * Double($1.repeats) }))")

        // 2. Import into 动作库 and 编排库.
        let library = CapturedLibraryStore(directory: directory)
        try await loaded(library)
        try require(library.actions.isEmpty && library.arrangements.isEmpty, "Library starts empty")
        let actionBatch = await library.importFiles([sourceURL], to: .actions)
        try require(actionBatch.count == 1 && actionBatch[0].succeeded, "Action import succeeded: \(actionBatch.first?.problem ?? "")")
        guard let action = actionBatch[0].published else { throw Failure(message: "No published action") }
        try require(action.id != model.id && action.sourceModelID == model.id, "Published action is an independent copy with provenance")
        try require(action.segments.count == 1 && action.segments[0].startFrame == rawSpanLower && action.segments[0].endFrame == rawSpanUpper,
                    "Action keeps the file's own practice span \(rawSpanLower)-\(rawSpanUpper), not every decoded frame")
        try require(action.frameCount == model.frameCount && action.report.frames.map(\.timestampValue) == model.report.frames.map(\.timestampValue),
                    "Action retains all original frames and PTS")
        try require(action.hasPlayableMotion, "Published action is playable")
        let arrangementBatch = await library.importFiles([sourceURL], to: .arrangements)
        guard let arrangement = arrangementBatch.first?.published else { throw Failure(message: "Arrangement import failed: \(arrangementBatch.first?.problem ?? "")") }
        try require(arrangement.segments.map(\.name) == model.segments.map(\.name) && arrangement.segments.map(\.repeats) == model.segments.map(\.repeats),
                    "Arrangement keeps segment order, names and repeats")
        try require(library.actions.count == 1 && library.arrangements.count == 1, "Both destinations hold one entry")
        let actionFile = directory.appendingPathComponent("Actions").appendingPathComponent(action.id.uuidString.lowercased() + ".json")
        let arrangementFile = directory.appendingPathComponent("Arrangements").appendingPathComponent(arrangement.id.uuidString.lowercased() + ".json")
        try require(FileManager.default.fileExists(atPath: actionFile.path) && FileManager.default.fileExists(atPath: arrangementFile.path),
                    "Both copies are written as UUID-named JSON")
        try require(hash(try Data(contentsOf: sourceURL)) == originalHash, "Source file bytes unchanged after import")

        // 3. Re-importing the same file is a new copy and says so.
        let repeatBatch = await library.importFiles([sourceURL], to: .actions)
        try require(repeatBatch.first?.succeeded == true, "Second import of the same file succeeds")
        try require(repeatBatch.first?.notes.contains { $0.contains("副本") } == true, "Repeat import reports the existing copy")
        try require(library.actions.count == 2 && library.actions[0].id != library.actions[1].id, "Repeat import is a separate entry")

        // 4. Restart reads both libraries back.
        let fresh = CapturedLibraryStore(directory: directory)
        try await loaded(fresh)
        try require(fresh.actions.count == 2 && fresh.arrangements.count == 1, "Reload finds every published copy")
        try require(fresh.arrangements.first?.id == arrangement.id && fresh.arrangements.first?.segments.count == model.segments.count,
                    "Reloaded arrangement keeps its segments")
        for restored in fresh.actions + fresh.arrangements { try restored.validate() }

        // 5. Lenient packaging, all derived from the real document.
        var noSegments = raw; noSegments.removeValue(forKey: "segments")
        let noSegmentsURL = variants.appendingPathComponent("variant-no-segments.json")
        try write(noSegments, to: noSegmentsURL)
        let noSegmentsResult = await fresh.importFiles([noSegmentsURL], to: .arrangements)
        guard let noSegmentsModel = noSegmentsResult.first?.published else { throw Failure(message: "Missing segments must fall back to the full range: \(noSegmentsResult.first?.problem ?? "")") }
        try require(noSegmentsModel.segments.count == 1 && noSegmentsModel.segments[0].startFrame == 0
                    && noSegmentsModel.segments[0].endFrame == model.frameCount - 1, "Absent segments become one full-range segment")

        let reportOnlyURL = variants.appendingPathComponent("variant-report-only.json")
        try write(rawReport, to: reportOnlyURL)
        let reportOnly = await fresh.importFiles([reportOnlyURL], to: .arrangements)
        guard let reportOnlyModel = reportOnly.first?.published else { throw Failure(message: "Bare PoseReport export must import: \(reportOnly.first?.problem ?? "")") }
        try require(reportOnly.frameCountCheck(model) && reportOnly.first?.notes.contains { $0.contains("PoseReport") } == true,
                    "Bare report import keeps every frame and says how it was read")
        try require(reportOnlyModel.name == (rawReport["sourceName"] as? String ?? ""), "Bare report falls back to its source name")

        let emptySegmentsURL = variants.appendingPathComponent("variant-empty-segments.json")
        var emptySegments = raw; emptySegments["segments"] = [[String: Any]]()
        try write(emptySegments, to: emptySegmentsURL)
        let emptySegmentsResult = await fresh.importFiles([emptySegmentsURL], to: .arrangements)
        try require(emptySegmentsResult.first?.published?.segments.first?.endFrame == model.frameCount - 1, "Empty segment array becomes the full range")
        try require(emptySegmentsResult.first?.notes.contains { $0.contains("空数组") } == true, "Empty segment array is reported")

        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let isoURL = variants.appendingPathComponent("variant-iso8601.json")
        try encoder.encode(model).write(to: isoURL, options: .atomic)
        // Published copies are new snapshots with their own createdAt, so the
        // date round trip is checked on the decoded file, not on the copy.
        let isoDecoded = try CapturedMotionImport.load(from: isoURL)
        try require(abs(isoDecoded.model.createdAt.timeIntervalSince(model.createdAt)) < 1
                    && abs(isoDecoded.model.report.createdAt.timeIntervalSince(model.report.createdAt)) < 1,
                    "ISO 8601 dates decode")
        let isoResult = await fresh.importFiles([isoURL], to: .arrangements)
        guard let isoModel = isoResult.first?.published else { throw Failure(message: "ISO 8601 pretty-printed export must import: \(isoResult.first?.problem ?? "")") }
        try require(isoModel.report.frames.map(\.timestamp) == model.report.frames.map(\.timestamp), "ISO 8601 variant keeps every PTS")

        var brokenMetadata = raw
        var brokenReport = rawReport
        brokenReport["decodedFrameCount"] = 999
        brokenReport["detectedFrameCount"] = 1
        brokenReport["coverage"] = 0.5
        brokenMetadata["report"] = brokenReport
        let brokenMetadataURL = variants.appendingPathComponent("variant-broken-metadata.json")
        try write(brokenMetadata, to: brokenMetadataURL)
        let brokenResult = await fresh.importFiles([brokenMetadataURL], to: .arrangements)
        guard let brokenModel = brokenResult.first?.published else { throw Failure(message: "Recomputable metadata must not block import: \(brokenResult.first?.problem ?? "")") }
        try require(brokenModel.report.decodedFrameCount == model.report.decodedFrameCount
                    && brokenModel.report.detectedFrameCount == model.report.detectedFrameCount
                    && abs(brokenModel.report.coverage - model.report.coverage) < 1e-9, "Derived counters recomputed from the retained frames")
        try require((brokenResult.first?.notes.count ?? 0) >= 3, "Each metadata repair is reported (\(brokenResult.first?.notes ?? [])")
        try require(brokenModel.arrangementMethod?.contains("import:") == true, "Published copy records the repairs")

        var strippedTiming = raw
        var strippedReport = rawReport
        var strippedFrames = rawFrames
        for index in 0..<min(3, strippedFrames.count) {
            strippedFrames[index].removeValue(forKey: "timestampValue")
            strippedFrames[index].removeValue(forKey: "timestampTimescale")
        }
        strippedReport["frames"] = strippedFrames
        strippedTiming["report"] = strippedReport
        let strippedURL = variants.appendingPathComponent("variant-stripped-pts.json")
        try write(strippedTiming, to: strippedURL)
        let strippedResult = await fresh.importFiles([strippedURL], to: .arrangements)
        guard let strippedModel = strippedResult.first?.published else { throw Failure(message: "Missing integer PTS must be rebuilt from timestamp: \(strippedResult.first?.problem ?? "")") }
        try require(strippedModel.report.frames.map(\.timestamp) == model.report.frames.map(\.timestamp), "Rebuilt integer PTS leaves timestamps untouched")
        try require(strippedResult.first?.notes.contains { $0.contains("PTS") } == true, "Rebuilt integer PTS is reported")

        var twoSegments = raw
        twoSegments["segments"] = [
            ["id": UUID().uuidString, "name": "前段", "startFrame": 0, "endFrame": max(0, rawSpanUpper / 2), "repeats": 2],
            ["id": UUID().uuidString, "name": "后段", "startFrame": max(0, rawSpanUpper / 2) + 1, "endFrame": rawSpanUpper, "repeats": 1]
        ]
        let twoSegmentsURL = variants.appendingPathComponent("variant-two-segments.json")
        try write(twoSegments, to: twoSegmentsURL)
        let twoActionBatch = await fresh.importFiles([twoSegmentsURL], to: .actions)
        try require(twoActionBatch.first?.published?.segments.count == 1
                    && twoActionBatch.first?.published?.segments.first?.startFrame == 0
                    && twoActionBatch.first?.published?.segments.first?.endFrame == rawSpanUpper,
                    "A multi-segment file becomes one continuous action spanning its own segments")
        let twoArrangementBatch = await fresh.importFiles([twoSegmentsURL], to: .arrangements)
        try require(twoArrangementBatch.first?.published?.segments.map(\.repeats) == [2, 1], "The same file keeps both segments and repeats in 编排库")

        // 6. Refusals: named, and nothing is written.
        let actionsBefore = fresh.actions.count
        let arrangementsBefore = fresh.arrangements.count
        func refuse(_ object: Any, named name: String, expecting fragment: String) async throws {
            let url = variants.appendingPathComponent(name)
            try write(object, to: url)
            let result = await fresh.importFiles([url], to: .arrangements)
            try require(result.first?.succeeded == false, "\(name) must be refused")
            let problem = result.first?.problem ?? ""
            try require(problem.contains(fragment), "\(name) must explain itself, got: \(problem)")
            try require(fresh.actions.count == actionsBefore && fresh.arrangements.count == arrangementsBefore, "\(name) writes nothing")
            try require(fresh.errorMessage?.contains(name) == true, "\(name) surfaces in the store error message")
        }
        var futureSchema = raw; futureSchema["schemaVersion"] = 2
        try await refuse(futureSchema, named: "reject-schema-2.json", expecting: "schemaVersion=2")
        var outOfRange = raw
        outOfRange["segments"] = [["id": UUID().uuidString, "name": "越界", "startFrame": 0, "endFrame": rawFrames.count + 999, "repeats": 1]]
        try await refuse(outOfRange, named: "reject-range.json", expecting: "超出")
        var badRepeats = raw
        badRepeats["segments"] = [["id": UUID().uuidString, "name": "重复越界", "startFrame": 0, "endFrame": 10, "repeats": 99]]
        try await refuse(badRepeats, named: "reject-repeats.json", expecting: "1–20")
        var brokenPTS = raw
        var brokenPTSReport = rawReport
        var brokenPTSFrames = rawFrames
        brokenPTSFrames[5]["timestampValue"] = 12345
        brokenPTSReport["frames"] = brokenPTSFrames
        brokenPTS["report"] = brokenPTSReport
        try await refuse(brokenPTS, named: "reject-pts.json", expecting: "timestampValue")
        var noSkeleton = raw
        var noSkeletonReport = rawReport
        var noSkeletonFrames = rawFrames
        for index in noSkeletonFrames.indices {
            var joints = noSkeletonFrames[index]["joints"] as? [String: [String: Any]] ?? [:]
            for (name, joint) in joints { var value = joint; value["confidence"] = 0; joints[name] = value }
            noSkeletonFrames[index]["joints"] = joints
        }
        noSkeletonReport["frames"] = noSkeletonFrames
        noSkeleton["report"] = noSkeletonReport
        try await refuse(noSkeleton, named: "reject-no-skeleton.json", expecting: "骨架")
        var noFrames = raw; var noFramesReport = rawReport; noFramesReport["frames"] = [[String: Any]](); noFrames["report"] = noFramesReport
        try await refuse(noFrames, named: "reject-no-frames.json", expecting: "frames")
        var noTiming = raw
        var noTimingReport = rawReport
        var noTimingFrames = rawFrames
        noTimingFrames[2].removeValue(forKey: "timestamp")
        noTimingFrames[2].removeValue(forKey: "timestampValue")
        noTimingReport["frames"] = noTimingFrames
        noTiming["report"] = noTimingReport
        try await refuse(noTiming, named: "reject-no-timing.json", expecting: "时间戳")

        let garbageURL = variants.appendingPathComponent("reject-garbage.json")
        try Data("not json at all".utf8).write(to: garbageURL, options: .atomic)
        let garbage = await fresh.importFiles([garbageURL], to: .arrangements)
        try require(garbage.first?.succeeded == false && (garbage.first?.problem ?? "").contains("JSON"), "Garbage is refused as unreadable JSON")
        let emptyURL = variants.appendingPathComponent("reject-empty.json")
        try Data().write(to: emptyURL, options: .atomic)
        let empty = await fresh.importFiles([emptyURL], to: .arrangements)
        try require(empty.first?.succeeded == false && (empty.first?.problem ?? "").contains("空"), "An empty file is refused")
        let unrelatedURL = variants.appendingPathComponent("reject-unrelated.json")
        try write(["hello": "world"], to: unrelatedURL)
        let unrelated = await fresh.importFiles([unrelatedURL], to: .arrangements)
        try require(unrelated.first?.succeeded == false && (unrelated.first?.problem ?? "").contains("report"), "An unrelated JSON document is refused")
        let missingJointFieldURL = variants.appendingPathComponent("reject-joint-field.json")
        var missingJointField = raw
        var missingJointReport = rawReport
        var missingJointFrames = rawFrames
        var firstJoints = missingJointFrames[0]["joints"] as? [String: [String: Any]] ?? [:]
        firstJoints["neck"]?.removeValue(forKey: "confidence")
        missingJointFrames[0]["joints"] = firstJoints
        missingJointReport["frames"] = missingJointFrames
        missingJointField["report"] = missingJointReport
        try write(missingJointField, to: missingJointFieldURL)
        let missingJointFieldResult = await fresh.importFiles([missingJointFieldURL], to: .arrangements)
        try require(missingJointFieldResult.first?.succeeded == false
                    && (missingJointFieldResult.first?.problem ?? "").contains("confidence"),
                    "A joint without confidence is refused by name, never defaulted: \(missingJointFieldResult.first?.problem ?? "")")

        // 7. A mixed batch imports the good files and reports the bad one.
        let mixed = await fresh.importFiles([sourceURL, garbageURL, sourceURL], to: .actions)
        try require(mixed.count == 3 && mixed[0].succeeded && !mixed[1].succeeded && mixed[2].succeeded, "Mixed batch keeps per-file results in order")
        try require(fresh.actions.count == actionsBefore + 2, "Only the valid files were published")
        try require(fresh.errorMessage?.contains(garbageURL.lastPathComponent) == true, "Batch failure stays visible")

        // 8. Every published copy still validates from disk.
        let reloaded = CapturedLibraryStore(directory: directory)
        try await loaded(reloaded)
        let onDisk = CapturedMotionPersistence.load(from: directory.appendingPathComponent("Actions")).models
            + CapturedMotionPersistence.load(from: directory.appendingPathComponent("Arrangements")).models
        try require(!onDisk.isEmpty && onDisk.allSatisfy { (try? $0.validate()) != nil }, "Every written copy reloads and validates")
        try require(onDisk.allSatisfy { $0.frameCount == model.frameCount }, "No copy lost or gained frames")
        try require(hash(try Data(contentsOf: sourceURL)) == originalHash, "Source file still byte-identical at the end")
        print("Library import QA passed on \(sourceURL.lastPathComponent): \(onDisk.count) published copies, real-file bit-exact frames/PTS/joints, action span \(rawSpanLower)-\(rawSpanUpper), arrangement segments preserved, lenient packaging (no/empty segments, bare report, ISO 8601, recomputed metadata, rebuilt integer PTS), named refusals (schema, range, repeats, PTS, no skeleton, no frames, no timing, garbage, empty, unrelated, missing confidence), mixed batch isolation, source bytes unchanged.")
    }
}

private extension Array where Element == LibraryFileImport {
    func frameCountCheck(_ model: CapturedMotion) -> Bool {
        first?.published?.frameCount == model.frameCount
    }
}
