import Foundation

/// Reads motion-library files from disk so they can be published to 动作库 or 编排库.
///
/// Accepted packaging:
/// - a complete `CapturedMotion` export, i.e. exactly the bytes
///   `CapturedMotionPersistence.export` writes (`*.hidanclub.json`, `*.json`);
/// - a bare `PoseReport` export, which becomes one full-range segment.
///
/// Dates may be Foundation reference-date numbers (the app's own export) or
/// ISO 8601 strings; pretty-printed, key-sorted and reordered keys all decode
/// the same way, and unknown extra keys are ignored.
///
/// Tolerance is limited to derived or descriptive metadata. Coordinates,
/// confidences, frame order and original PTS are never edited, smoothed,
/// interpolated, resampled or reordered — an inconsistent original PTS is
/// refused instead of repaired. Every metadata repair is reported so the UI can
/// show it and the published copy keeps a written record.
enum CapturedMotionImport {
    /// A decoded file plus the metadata repairs it needed, if any.
    struct Decoded: Sendable {
        let model: CapturedMotion
        let notes: [String]
    }

    enum ImportError: LocalizedError {
        case unreadable(String), unrecognized(String), unsupportedSchema(Int), invalid(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let reason): return "文件无法读取：\(reason)"
            case .unrecognized(let reason): return "不是可识别的动作模型 JSON：\(reason)"
            case .unsupportedSchema(let version): return "文件声明 schemaVersion=\(version)，当前只接受 1；原文件未被修改。"
            case .invalid(let reason): return "动作模型不完整：\(reason)"
            }
        }
    }

    /// Refuse absurd inputs before decoding; a picker can select any file.
    private static let maximumBytes = 512 * 1024 * 1024
    /// Time base used only when a file states `timestamp` without the integer
    /// PTS pair. 1e7 keeps the round trip inside the model's 1e-7 tolerance.
    private static let derivedTimescale: Int32 = 10_000_000

    static func load(from url: URL) throws -> Decoded {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw ImportError.unreadable(error.localizedDescription) }
        guard !data.isEmpty else { throw ImportError.unreadable("文件是空的。") }
        guard data.count <= maximumBytes else { throw ImportError.unreadable("文件超过 \(maximumBytes / 1024 / 1024) MB。") }
        return try decode(data, fallbackName: url.deletingPathExtension().lastPathComponent)
    }

    static func decode(_ data: Data, fallbackName: String) throws -> Decoded {
        var diagnostics: [String] = []
        // The app writes reference-date numbers; ISO 8601 is accepted as well.
        for iso8601 in [false, true] {
            let decoder = JSONDecoder()
            if iso8601 { decoder.dateDecodingStrategy = .iso8601 }
            do { return try build(try decoder.decode(FileDocument.self, from: data),
                                   decoder: decoder, data: data, fallbackName: fallbackName) }
            catch { diagnostics.append(describe(error)) }
        }
        throw ImportError.unrecognized(diagnostics.first ?? "无法解析。")
    }

    // MARK: - Packaging

    /// Every field is optional so a hand-edited file reports *what* is missing
    /// or inconsistent instead of failing on the first absent key.
    private struct FileDocument: Decodable {
        let schemaVersion: Int?
        let id: UUID?
        let name: String?
        let createdAt: Date?
        let imageAspectRatio: Double?
        let report: FileReport?
        let segments: [FileSegment]?
        let arrangementMethod: String?
        let sourceModelID: UUID?
    }

    private struct FileReport: Decodable {
        let sourceName: String?
        let frames: [FileFrame]?
        let duration: Double?
        let decodedFrameCount: Int?
        let detectedFrameCount: Int?
        let coverage: Double?
        let createdAt: Date?
        let coordinateSystem: String?
        let modelName: String?
        let modelRevision: Int?
    }

    private struct FileFrame: Decodable {
        let timestamp: Double?
        let timestampValue: Int64?
        let timestampTimescale: Int32?
        /// Joint coordinates and confidences stay exactly as written.
        let joints: [String: PoseJoint]?
        let bodyCount: Int?
        let ambiguous: Bool?
    }

    private struct FileSegment: Decodable {
        let id: UUID?
        let name: String?
        let startFrame: Int?
        let endFrame: Int?
        let repeats: Int?
    }

    // MARK: - Building

    private static func build(_ document: FileDocument, decoder: JSONDecoder, data: Data, fallbackName: String) throws -> Decoded {
        var notes: [String] = []
        let report: FileReport
        if let embedded = document.report { report = embedded }
        else if let standalone = try? decoder.decode(FileReport.self, from: data), standalone.frames != nil {
            report = standalone
            notes.append("文件只包含识别报告（PoseReport），已按完整帧范围作为一个片段导入。")
        } else {
            throw ImportError.unrecognized("找不到 report 帧数据。\(describeMissingReport(document))")
        }
        if let version = document.schemaVersion, version != 1 { throw ImportError.unsupportedSchema(version) }

        let (frames, frameNotes) = try rebuildFrames(report.frames ?? [])
        notes += frameNotes
        let (builtReport, reportNotes) = try rebuildReport(report, frames: frames, fallbackName: fallbackName,
                                                           createdAt: report.createdAt ?? document.createdAt)
        notes += reportNotes

        let (segments, segmentNotes) = rebuildSegments(document.segments, frameCount: frames.count)
        notes += segmentNotes

        // The ratio only drives letterboxing on screen; it never rescales data.
        let ratio: Double
        if let stated = document.imageAspectRatio, stated.isFinite, stated > 0 { ratio = stated }
        else {
            notes.append(document.imageAspectRatio == nil ? "文件没有 imageAspectRatio，已按 1:1 显示；坐标本身未改变。"
                                                          : "imageAspectRatio 无效，已按 1:1 显示；坐标本身未改变。")
            ratio = 1
        }
        return try finish(document, report: builtReport, segments: segments, notes: notes, ratio: ratio, fallbackName: fallbackName)
    }

    private static func finish(_ document: FileDocument, report: PoseReport, segments: [CapturedMotionSegment],
                               notes: [String], ratio: Double, fallbackName: String) throws -> Decoded {
        let name = cleaned(document.name) ?? cleaned(report.sourceName) ?? cleaned(fallbackName) ?? "导入的动作"
        var model = CapturedMotion(schemaVersion: 1, id: document.id ?? UUID(), name: name,
                                   createdAt: document.createdAt ?? report.createdAt, imageAspectRatio: ratio,
                                   report: report, segments: segments,
                                   arrangementMethod: document.arrangementMethod, sourceModelID: document.sourceModelID)
        // Keep a durable record of metadata the importer had to derive.
        if !notes.isEmpty {
            let record = "import: " + notes.joined(separator: " ")
            model.arrangementMethod = [model.arrangementMethod, record].compactMap { $0 }.joined(separator: " | ")
        }
        do { try model.validate() }
        catch { throw ImportError.invalid(problem(with: model) ?? error.localizedDescription) }
        return Decoded(model: model, notes: notes)
    }

    private static func describeMissingReport(_ document: FileDocument) -> String {
        document.schemaVersion == nil && document.name == nil && document.segments == nil
            ? "文件顶层没有 report、frames 或动作模型字段。" : ""
    }

    /// Frames are copied through unchanged except for metadata the file left
    /// out. A frame with no timing at all is refused, never re-timed.
    private static func rebuildFrames(_ files: [FileFrame]) throws -> ([PoseFrame], [String]) {
        guard !files.isEmpty else { throw ImportError.invalid("report.frames 是空的，没有可跟练的原始帧。") }
        var frames: [PoseFrame] = []
        frames.reserveCapacity(files.count)
        var rebuiltTiming: [Int] = []
        var derivedJoints: [Int] = []
        var derivedCounts: [Int] = []
        for (index, file) in files.enumerated() {
            let position = index + 1
            let timestamp: Double
            let timestampValue: Int64
            let timestampTimescale: Int32
            if let stated = file.timestamp, stated.isFinite {
                timestamp = stated
                if let value = file.timestampValue, let scale = file.timestampTimescale {
                    timestampValue = value; timestampTimescale = scale
                } else {
                    // Only the integer PTS representation is derived, from the
                    // stated timestamp; the timestamp itself is never altered.
                    let scaled = stated * Double(derivedTimescale)
                    guard abs(scaled) < 9.2e18 else { throw ImportError.invalid("第 \(position) 帧时间戳超出可表示范围。") }
                    timestampValue = Int64(scaled.rounded()); timestampTimescale = derivedTimescale
                    rebuiltTiming.append(position)
                }
            } else if let value = file.timestampValue, let scale = file.timestampTimescale, scale > 0 {
                timestampValue = value; timestampTimescale = scale; timestamp = Double(value) / Double(scale)
                rebuiltTiming.append(position)
            } else {
                throw ImportError.invalid("第 \(position) 帧缺少时间戳（需要 timestamp，或 timestampValue 与 timestampTimescale）。")
            }
            let joints = file.joints ?? [:]
            if file.joints == nil { derivedJoints.append(position) }
            let bodyCount = file.bodyCount ?? (joints.values.contains { $0.confidence > 0 } ? 1 : 0)
            let ambiguous = file.ambiguous ?? (bodyCount > 1)
            if file.bodyCount == nil || file.ambiguous == nil { derivedCounts.append(position) }
            frames.append(PoseFrame(timestamp: timestamp, timestampValue: timestampValue, timestampTimescale: timestampTimescale,
                                    joints: joints, bodyCount: bodyCount, ambiguous: ambiguous))
        }
        var notes: [String] = []
        if !rebuiltTiming.isEmpty {
            notes.append("有 \(rebuiltTiming.count) 帧的整数 PTS 表示由文件里的 timestamp 重建（时基 \(derivedTimescale)）：\(preview(rebuiltTiming))。")
        }
        if !derivedJoints.isEmpty {
            notes.append("有 \(derivedJoints.count) 帧没有 joints 字段，按空骨架保留：\(preview(derivedJoints))。")
        }
        if !derivedCounts.isEmpty {
            notes.append("有 \(derivedCounts.count) 帧的 bodyCount/ambiguous 由关节置信度推得：\(preview(derivedCounts))。")
        }
        return (frames, notes)
    }

    /// Derived counters and descriptive strings are recomputed from the frames
    /// that are actually present; the frames themselves are the only source.
    private static func rebuildReport(_ file: FileReport, frames: [PoseFrame], fallbackName: String, createdAt: Date?) throws -> (PoseReport, [String]) {
        var notes: [String] = []
        let detected = frames.filter(\.hasDetectedBody).count
        let decoded = frames.count
        if let stated = file.decodedFrameCount, stated != decoded {
            notes.append("decodedFrameCount=\(stated) 与实际帧数不符，已按保留的 \(decoded) 帧重算。")
        }
        if let stated = file.detectedFrameCount, stated != detected {
            notes.append("detectedFrameCount=\(stated) 与实际检测帧数不符，已按保留帧重算为 \(detected)。")
        }
        let coverage = Double(detected) / Double(decoded)
        if let stated = file.coverage, !stated.isFinite || abs(stated - coverage) >= 0.0000001 {
            notes.append(String(format: "coverage 与 detectedFrameCount/decodedFrameCount 不一致，已重算为 %.6f。", coverage))
        }
        var duration = file.duration ?? 0
        if !duration.isFinite || duration <= 0 {
            duration = derivedDuration(frames)
            notes.append(String(format: "文件没有有效的 duration，已按最后一帧时间戳与相邻帧间隔推得 %.6f 秒。", duration))
        }
        let report = PoseReport(sourceName: cleaned(file.sourceName) ?? cleaned(fallbackName) ?? "导入文件",
                                frames: frames, duration: duration, decodedFrameCount: decoded, detectedFrameCount: detected,
                                coverage: coverage, createdAt: createdAt ?? Date(),
                                coordinateSystem: file.coordinateSystem ?? "unspecified-imported",
                                modelName: file.modelName ?? "imported-file", modelRevision: file.modelRevision ?? 1)
        if file.coordinateSystem == nil { notes.append("文件没有 coordinateSystem，已标记为 unspecified-imported；坐标值未改变。") }
        if file.modelName == nil { notes.append("文件没有 modelName，已标记为 imported-file。") }
        return (report, notes)
    }

    /// Presentation duration: the last PTS plus one trailing frame interval.
    private static func derivedDuration(_ frames: [PoseFrame]) -> Double {
        guard let last = frames.last else { return 0 }
        var interval = 0.0
        for index in stride(from: frames.count - 1, to: 0, by: -1) {
            let delta = frames[index].timestamp - frames[index - 1].timestamp
            if delta > 0 { interval = delta; break }
        }
        if interval <= 0 { interval = 1.0 / 30.0 }
        return last.timestamp + interval
    }

    /// A missing or empty segment list means "the whole clip", which is what the
    /// video-library editor creates before any A–B trimming.
    private static func rebuildSegments(_ files: [FileSegment]?, frameCount: Int) -> ([CapturedMotionSegment], [String]) {
        var notes: [String] = []
        guard let files, !files.isEmpty else {
            if files != nil { notes.append("文件的 segments 是空数组，已按完整帧范围 0–\(frameCount - 1) 建立一个片段。") }
            return ([CapturedMotionSegment(name: "完整片段", startFrame: 0, endFrame: frameCount - 1)], notes)
        }
        var segments: [CapturedMotionSegment] = []
        var renamed: [Int] = []
        var defaulted: [Int] = []
        for (index, file) in files.enumerated() {
            let position = index + 1
            guard let start = file.startFrame, start >= 0 else {
                return ([], ["第 \(position) 个片段缺少有效的 startFrame，无法确定范围；原文件未被修改。"])
            }
            let end = file.endFrame ?? start
            if file.endFrame == nil { defaulted.append(position) }
            let name = cleaned(file.name) ?? ""
            if name.isEmpty { renamed.append(position) }
            segments.append(CapturedMotionSegment(id: file.id ?? UUID(), name: name.isEmpty ? "片段 \(position)" : name,
                                                  startFrame: start, endFrame: end, repeats: file.repeats ?? 1))
        }
        if !renamed.isEmpty { notes.append("有 \(renamed.count) 个片段没有名称，已命名为「片段 N」：\(preview(renamed))。") }
        if !defaulted.isEmpty { notes.append("有 \(defaulted.count) 个片段没有 endFrame，已按单帧处理：\(preview(defaulted))。") }
        return (segments, notes)
    }

    // MARK: - Diagnostics

    private static func preview(_ positions: [Int]) -> String {
        let shown = positions.prefix(6).map(String.init).joined(separator: "、")
        return positions.count > 6 ? "第 \(shown) 帧等" : "第 \(shown) 帧"
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Name the exact offending field so a hand-edited file can be fixed.
    private static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { key in
                key.intValue.map { "第 \($0 + 1) 项" } ?? key.stringValue
            }
            return keys.isEmpty ? "顶层" : keys.joined(separator: ".")
        }
        switch decoding {
        case .keyNotFound(let key, let context): return "\(path(context)) 缺少字段 \(key.stringValue)。"
        case .typeMismatch(let type, let context): return "\(path(context)) 类型不符，期望 \(type)。"
        case .valueNotFound(let type, let context): return "\(path(context)) 没有值，期望 \(type)。"
        case .dataCorrupted(let context): return "\(path(context)) JSON 损坏：\(context.debugDescription)"
        @unknown default: return decoding.localizedDescription
        }
    }

    /// Mirror `CapturedMotion.validate()` with per-field messages. Called only
    /// after validation failed, so it explains a refusal instead of guessing.
    static func problem(with model: CapturedMotion) -> String? {
        let frames = model.report.frames
        if cleaned(model.name) == nil { return "名称为空。" }
        if !model.imageAspectRatio.isFinite || model.imageAspectRatio <= 0 { return "imageAspectRatio 必须是正数。" }
        if !model.report.duration.isFinite || model.report.duration <= 0 { return "report.duration 必须是正数（秒）。" }
        if frames.isEmpty { return "没有原始帧。" }
        if model.report.decodedFrameCount != frames.count { return "decodedFrameCount=\(model.report.decodedFrameCount) 与实际帧数 \(frames.count) 不一致。" }
        let detected = frames.filter(\.hasDetectedBody).count
        if model.report.detectedFrameCount != detected { return "detectedFrameCount=\(model.report.detectedFrameCount) 与实际检测帧数 \(detected) 不一致。" }
        let expected = Double(detected) / Double(frames.count)
        if !model.report.coverage.isFinite || abs(model.report.coverage - expected) >= 0.0000001 {
            return String(format: "coverage=%.10f 与 detectedFrameCount/decodedFrameCount=%.10f 不一致。", model.report.coverage, expected)
        }
        var previous = -Double.infinity
        for (index, frame) in frames.enumerated() {
            let position = index + 1
            if !frame.timestamp.isFinite || frame.timestamp < previous { return "第 \(position) 帧时间戳无效或没有单调递增。" }
            if frame.timestampTimescale <= 0 { return "第 \(position) 帧 timestampTimescale 必须是正数。" }
            if abs(Double(frame.timestampValue) / Double(frame.timestampTimescale) - frame.timestamp) >= 0.0000001 {
                return "第 \(position) 帧的 timestampValue/timestampTimescale 与 timestamp 不一致；原始 PTS 不会被改写，请修正文件。"
            }
            if frame.bodyCount < 0 { return "第 \(position) 帧 bodyCount 不能为负数。" }
            if frame.ambiguous != (frame.bodyCount > 1) { return "第 \(position) 帧 ambiguous 与 bodyCount 不一致（bodyCount>1 时必须为 true）。" }
            for (joint, value) in frame.joints {
                guard value.x.isFinite, value.y.isFinite, value.confidence.isFinite, (0...1).contains(value.confidence) else {
                    return "第 \(position) 帧关节 \(joint) 的坐标或置信度无效（需为有限数，置信度 0–1）。"
                }
            }
            previous = frame.timestamp
        }
        if model.segments.isEmpty { return "没有片段。" }
        if Set(model.segments.map(\.id)).count != model.segments.count { return "片段 id 重复。" }
        for segment in model.segments {
            if cleaned(segment.name) == nil { return "片段名称不能为空。" }
            guard segment.startFrame >= 0, segment.endFrame >= segment.startFrame, segment.endFrame < frames.count else {
                return "片段「\(segment.name)」范围 \(segment.startFrame)–\(segment.endFrame) 超出 0–\(frames.count - 1)。"
            }
            if !(1...20).contains(segment.repeats) { return "片段「\(segment.name)」重复次数 \(segment.repeats) 需在 1–20。" }
        }
        return nil
    }
}
