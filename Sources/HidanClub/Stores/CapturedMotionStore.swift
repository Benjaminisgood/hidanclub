import Foundation
import SwiftUI

@MainActor final class CapturedMotionStore: ObservableObject {
    @Published private(set) var saved: [CapturedMotion] = []
    @Published private(set) var drafts: [CapturedMotion] = []
    @Published private(set) var selected: CapturedMotion?
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var isExporting = false
    @Published private(set) var isAutoArranging = false
    @Published private(set) var proposedArrangement: PoseArrangementProposal?
    @Published private(set) var hasUnsavedChanges = false
    @Published private(set) var selectionA = 0
    @Published private(set) var selectionB = 0
    @Published var errorMessage: String?
    let playback = CapturedMotionPlayback()
    let directory: URL
    private(set) var revision = 0
    private var draftRevisions: [UUID: Int] = [:]
    private var storageRevision = 0
    private var preparedReportDate: Date?
    private var pendingCaptureName = ""
    private var pendingAspectRatio = 1.0
    private var selectionTask: Task<Void, Never>?
    private var proposalModelID: UUID?
    private var proposalRevision: Int?

    init(directory: URL? = nil) {
        self.directory = directory ?? ProcessInfo.processInfo.environment["HIDAN_CAPTURE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HidanClub/CapturedMotions", isDirectory: true)
        reload()
    }
    var hasPlayableMotion: Bool { selected?.hasPlayableMotion ?? false }
    func beginCapture(name: String, imageAspectRatio: Double) { pendingCaptureName = name; pendingAspectRatio = imageAspectRatio }
    func acceptAnalysis(_ report: PoseReport) throws {
        guard report.createdAt != preparedReportDate else { return }
        try prepare(report: report, name: pendingCaptureName, imageAspectRatio: pendingAspectRatio)
    }
    func reload() {
        selectionTask?.cancel()
        isLoading = true; let folder = directory; let startedStorageRevision = storageRevision
        selectionTask = Task {
            let result = await Task.detached { CapturedMotionPersistence.load(from: folder) }.value
            guard !Task.isCancelled else { return }
            guard storageRevision == startedStorageRevision else { reload(); return }
            saved = result.models; isLoading = false
            if selected == nil, let first = saved.first { select(first) }
            if !result.errors.isEmpty { errorMessage = result.errors.joined(separator: "\n") }
        }
    }
    @discardableResult func prepare(report: PoseReport, name: String, imageAspectRatio: Double = 1) throws -> CapturedMotion {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = CapturedMotion(schemaVersion: 1, id: UUID(), name: cleanName.isEmpty ? report.sourceName : cleanName,
                                   createdAt: Date(), imageAspectRatio: imageAspectRatio, report: report,
                                   segments: [CapturedMotionSegment(name: "完整舞蹈", startFrame: 0, endFrame: report.frames.count - 1)])
        try model.validate(); discardAutoArrangement(); selected = model; hasUnsavedChanges = true; revision += 1; preparedReportDate = report.createdAt
        cacheDraft(model)
        selectionA = 0; selectionB = model.frameCount - 1; playback.prepare(model); errorMessage = nil
        return model
    }
    func select(_ model: CapturedMotion) {
        let choice = drafts.first { $0.id == model.id } ?? model
        do { try choice.validate(); discardAutoArrangement(); selected = choice; revision += 1; hasUnsavedChanges = draftRevisions[choice.id] != nil
            selectionA = 0; selectionB = choice.frameCount - 1; playback.prepare(choice); errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
    func rename(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, var model = selected, model.name != clean else { return }
        model.name = clean; update(model, repreparePlayback: false)
    }
    func setA() { try? setRange(start: min(playback.frameIndex, selectionB), end: selectionB) }
    func setB() { try? setRange(start: selectionA, end: max(playback.frameIndex, selectionA)) }
    func setRange(start: Int, end: Int) throws {
        guard let model = selected, start >= 0, end >= start, end < model.frameCount else { throw CapturedMotionError.invalidRange }
        if selectionA != start || selectionB != end { revision += 1; discardAutoArrangement() }
        selectionA = start; selectionB = end
    }
    func autoArrange(targetSeconds: Double = 8) async {
        guard !isAutoArranging else { return }
        guard let model = selected else { errorMessage = CapturedMotionError.noSelection.localizedDescription; return }
        let expectedID = model.id
        let expectedRevision = revision
        isAutoArranging = true; errorMessage = nil; discardAutoArrangement()
        defer { isAutoArranging = false }
        do {
            let worker = Task.detached(priority: .userInitiated) { try PoseArrangementPlanner.propose(for: model, targetSeconds: targetSeconds) }
            let proposal = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            guard selected?.id == expectedID, revision == expectedRevision else {
                errorMessage = "视频或编排已发生变化，已放弃这次分段建议，请重新生成。"; return
            }
            proposedArrangement = proposal; proposalModelID = expectedID; proposalRevision = expectedRevision
        } catch is CancellationError { }
        catch {
            guard selected?.id == expectedID, revision == expectedRevision else { return }
            errorMessage = error.localizedDescription
        }
    }
    func applyAutoArrangement() throws {
        guard var model = selected, let proposal = proposedArrangement,
              model.id == proposalModelID, revision == proposalRevision else { throw CapturedMotionError.noSelection }
        model.segments = proposal.segments; model.arrangementMethod = proposal.method
        try model.validate(); update(model); errorMessage = nil
    }
    func discardAutoArrangement() {
        proposedArrangement = nil; proposalModelID = nil; proposalRevision = nil
    }
    /// Move a shared boundary while preserving continuous coverage on both sides.
    func setSegmentBoundary(after id: UUID, endFrame: Int) throws {
        guard var model = selected, model.hasContinuousArrangement,
              let index = model.segments.firstIndex(where: { $0.id == id }), index + 1 < model.segments.count else { throw CapturedMotionError.invalidBoundary }
        let before = model.segments[index]
        let after = model.segments[index + 1]
        guard endFrame >= before.startFrame, endFrame < after.endFrame else { throw CapturedMotionError.invalidBoundary }
        guard endFrame != before.endFrame else { return }
        model.segments[index] = CapturedMotionSegment(id: before.id, name: before.name, startFrame: before.startFrame, endFrame: endFrame, repeats: before.repeats)
        model.segments[index + 1] = CapturedMotionSegment(id: after.id, name: after.name, startFrame: endFrame + 1, endFrame: after.endFrame, repeats: after.repeats)
        markManualEdit(&model)
        try model.validate(); update(model)
    }
    private func markManualEdit(_ model: inout CapturedMotion) {
        if let method = model.arrangementMethod, !method.hasSuffix(";manually-edited") { model.arrangementMethod = method + ";manually-edited" }
    }
    func addSegment(name: String) throws {
        guard var model = selected else { throw CapturedMotionError.noSelection }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        model.segments.append(CapturedMotionSegment(name: clean.isEmpty ? "片段 \(model.segments.count + 1)" : clean, startFrame: selectionA, endFrame: selectionB))
        markManualEdit(&model)
        try model.validate(); update(model)
    }
    func useSelectionAsArrangement(name: String) throws {
        guard var model = selected else { throw CapturedMotionError.noSelection }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        model.segments = [CapturedMotionSegment(name: clean.isEmpty ? "所选片段" : clean, startFrame: selectionA, endFrame: selectionB)]
        markManualEdit(&model)
        try model.validate(); update(model)
    }
    func moveSegment(_ id: UUID, by delta: Int) {
        guard var model = selected, let index = model.segments.firstIndex(where: { $0.id == id }) else { return }
        let (target, overflow) = index.addingReportingOverflow(delta); guard !overflow, model.segments.indices.contains(target) else { return }
        model.segments.swapAt(index, target); markManualEdit(&model); update(model)
    }
    func removeSegment(_ id: UUID) {
        guard var model = selected, model.segments.count > 1 else { return }
        model.segments.removeAll { $0.id == id }; markManualEdit(&model); update(model)
    }
    func setSegmentRepeats(_ id: UUID, count: Int) {
        guard (1...20).contains(count), var model = selected, let index = model.segments.firstIndex(where: { $0.id == id }) else { return }
        model.segments[index].repeats = count; markManualEdit(&model); update(model)
    }
    private func cacheDraft(_ model: CapturedMotion) {
        drafts.removeAll { $0.id == model.id }; drafts.insert(model, at: 0); draftRevisions[model.id] = revision
    }
    private func update(_ model: CapturedMotion, repreparePlayback: Bool = true) {
        discardAutoArrangement(); selected = model; hasUnsavedChanges = true; revision += 1; cacheDraft(model)
        if repreparePlayback { playback.prepare(model) }
    }
    func saveSelected() async {
        guard let model = selected, !isSaving else { return }
        let folder = directory; let savedDraftRevision = draftRevisions[model.id]; isSaving = true
        do {
            try await Task.detached { try CapturedMotionPersistence.save(model, to: folder) }.value
            storageRevision += 1
            saved.removeAll { $0.id == model.id }; saved.insert(model, at: 0)
            if draftRevisions[model.id] == savedDraftRevision {
                drafts.removeAll { $0.id == model.id }; draftRevisions.removeValue(forKey: model.id)
                if selected?.id == model.id { hasUnsavedChanges = false }
            }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
        isSaving = false
    }
    func exportSelected(to url: URL) async {
        guard let model = selected, !isExporting else { return }
        isExporting = true
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() }; isExporting = false }
        do {
            try await Task.detached { try CapturedMotionPersistence.export(model, to: url) }.value
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
    func start() { playback.start() }
    func pause() { playback.pause() }
    func stop() { playback.stop() }
    func toggle() { playback.toggle() }
    func seek(_ frame: Int) { playback.seek(frame) }
    func step(_ delta: Int) { playback.step(delta) }
}

enum CapturedMotionPersistence {
    struct LoadResult: Sendable { let models: [CapturedMotion]; let errors: [String] }
    static func load(from directory: URL) -> LoadResult {
        guard FileManager.default.fileExists(atPath: directory.path) else { return LoadResult(models: [], errors: []) }
        var models: [CapturedMotion] = []; var errors: [String] = []
        do {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) where url.pathExtension == "json" {
                do {
                    guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                          url.resolvingSymlinksInPath().deletingLastPathComponent().path == directory.resolvingSymlinksInPath().path else { throw CapturedMotionError.invalidModel }
                    let model = try JSONDecoder().decode(CapturedMotion.self, from: Data(contentsOf: url)); try model.validate()
                    guard model.id.uuidString.lowercased() == url.deletingPathExtension().lastPathComponent.lowercased() else { throw CapturedMotionError.invalidModel }
                    models.append(model)
                } catch { errors.append("\(url.lastPathComponent) 无法读取，文件已保留：\(error.localizedDescription)") }
            }
        } catch { errors.append(error.localizedDescription) }
        return LoadResult(models: models.sorted { $0.createdAt > $1.createdAt }, errors: errors)
    }
    static func save(_ model: CapturedMotion, to directory: URL) throws {
        try model.validate(); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(model.id.uuidString.lowercased()).appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: url.path) {
            guard url.resolvingSymlinksInPath().deletingLastPathComponent().path == directory.resolvingSymlinksInPath().path,
                  let existing = try? JSONDecoder().decode(CapturedMotion.self, from: Data(contentsOf: url)),
                  existing.id == model.id, (try? existing.validate()) != nil else { throw CapturedMotionError.corruptedExistingFile }
        }
        try export(model, to: url)
    }
    static func export(_ model: CapturedMotion, to url: URL) throws {
        try model.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(model).write(to: url, options: .atomic)
    }
}
