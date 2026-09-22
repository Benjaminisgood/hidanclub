import Foundation
import SwiftUI

/// One file offered to a library: either the published copy or the reason the
/// file was refused. A refusal never touches the library or the source file.
struct LibraryFileImport: Identifiable, Sendable {
    let id = UUID()
    let fileName: String
    let published: CapturedMotion?
    let notes: [String]
    let problem: String?

    init(fileName: String, published: CapturedMotion? = nil, notes: [String] = [], problem: String? = nil) {
        self.fileName = fileName; self.published = published; self.notes = notes; self.problem = problem
    }

    var succeeded: Bool { published != nil }
    /// Frames, segments and played duration of what actually got published.
    var detail: String? {
        guard let published else { return nil }
        let seconds = published.segments.reduce(0.0) { $0 + published.duration(of: $1) * Double($1.repeats) }
        return "\(published.frameCount) 帧 · \(published.segments.count) 个片段 · \(String(format: "%.1f", seconds)) 秒"
    }
}

/// Published copies live separately from analysis/editor drafts. Importing never
/// changes an existing source model or its complete original frame report.
@MainActor final class CapturedLibraryStore: ObservableObject {
    enum Destination { case actions, arrangements }
    @Published private(set) var actions: [CapturedMotion] = []
    @Published private(set) var arrangements: [CapturedMotion] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isImporting = false
    @Published var errorMessage: String?
    let directory: URL
    private var loadTask: Task<Void, Never>?
    private var storageRevision = 0
    private var pendingWrites = 0
    private var writeInProgress = false

    init(directory: URL? = nil) {
        self.directory = directory ?? ProcessInfo.processInfo.environment["HIDAN_PUBLISHED_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HidanClub/VideoMotionLibrary", isDirectory: true)
        reload()
    }

    func reload() {
        loadTask?.cancel(); isLoading = true
        let base = directory, revision = storageRevision
        loadTask = Task {
            let loaded = await Task.detached {
                (CapturedMotionPersistence.load(from: base.appendingPathComponent("Actions")),
                 CapturedMotionPersistence.load(from: base.appendingPathComponent("Arrangements")))
            }.value
            guard !Task.isCancelled else { return }
            guard revision == storageRevision else { reload(); return }
            actions = loaded.0.models; arrangements = loaded.1.models; isLoading = false
            let errors = loaded.0.errors + loaded.1.errors
            if !errors.isEmpty { errorMessage = errors.joined(separator: "\n") }
        }
    }

    @discardableResult
    func importModel(_ model: CapturedMotion, to destination: Destination,
                     range: ClosedRange<Int>? = nil) async -> CapturedMotion? {
        beginWriteRequest()
        defer { endWriteRequest() }
        while writeInProgress {
            do { try await Task.sleep(for: .milliseconds(25)) }
            catch { return nil }
        }
        writeInProgress = true
        defer { writeInProgress = false }
        do {
            try model.validate()
            var segments = model.segments
            if destination == .actions {
                let selected = range ?? 0...(model.frameCount - 1)
                guard selected.lowerBound >= 0, selected.upperBound < model.frameCount else { throw CapturedMotionError.invalidRange }
                segments = [CapturedMotionSegment(name: model.name, startFrame: selected.lowerBound, endFrame: selected.upperBound)]
            }
            let copy = model.libraryCopy(segments: segments)
            try copy.validate()
            guard copy.hasPlayableMotion else { throw CapturedMotionError.notPlayable }
            let folder = directory.appendingPathComponent(destination == .actions ? "Actions" : "Arrangements", isDirectory: true)
            try await Task.detached { try CapturedMotionPersistence.save(copy, to: folder) }.value
            storageRevision += 1
            if destination == .actions { actions.insert(copy, at: 0) }
            else { arrangements.insert(copy, at: 0) }
            errorMessage = nil
            return copy
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    /// Publish motion-library JSON files (for example `*.hidanclub.json`).
    ///
    /// Each file is decoded and validated on its own; one bad file never blocks
    /// the others and never modifies the source. 动作库 receives one continuous
    /// action spanning the file's own segments, 编排库 receives the complete
    /// segment list with its order and repeats. Both keep every original frame.
    @discardableResult
    func importFiles(_ urls: [URL], to destination: Destination) async -> [LibraryFileImport] {
        guard !urls.isEmpty else { return [] }
        beginWriteRequest()
        defer { endWriteRequest() }
        var results: [LibraryFileImport] = []
        for url in urls {
            let fileName = url.lastPathComponent
            let decoded: CapturedMotionImport.Decoded
            do { decoded = try await Task.detached { try CapturedMotionImport.load(from: url) }.value }
            catch {
                results.append(LibraryFileImport(fileName: fileName, problem: error.localizedDescription))
                continue
            }
            var notes = decoded.notes
            let duplicates = (destination == .actions ? actions : arrangements)
                .filter { $0.sourceModelID == decoded.model.id }.count
            if duplicates > 0 {
                notes.append("库里已有 \(duplicates) 条来自同一文件的副本；本次仍保存为新的独立副本。")
            }
            let range = destination == .actions ? Self.actionRange(of: decoded.model) : nil
            guard let copy = await importModel(decoded.model, to: destination, range: range) else {
                results.append(LibraryFileImport(fileName: fileName, notes: notes,
                                                 problem: errorMessage ?? CapturedMotionError.invalidModel.localizedDescription))
                continue
            }
            results.append(LibraryFileImport(fileName: fileName, published: copy, notes: notes))
        }
        let failures = results.filter { !$0.succeeded }
        errorMessage = failures.isEmpty ? nil
            : failures.map { "\($0.fileName)：\($0.problem ?? "导入失败")" }.joined(separator: "\n")
        return results
    }

    /// The file's own practice span, so an author's trimmed range survives an
    /// import into 动作库 instead of being widened to every decoded frame.
    private static func actionRange(of model: CapturedMotion) -> ClosedRange<Int>? {
        guard !model.segments.isEmpty else { return nil }
        let lower = model.segments.map(\.startFrame).min() ?? 0
        let upper = model.segments.map(\.endFrame).max() ?? 0
        guard lower >= 0, upper < model.frameCount, lower <= upper else { return nil }
        return lower...upper
    }

    /// Update an explicitly opened published arrangement after its editor saves.
    func updateArrangement(_ model: CapturedMotion) async -> Bool {
        guard arrangements.contains(where: { $0.id == model.id }) else { return false }
        beginWriteRequest()
        defer { endWriteRequest() }
        while writeInProgress {
            do { try await Task.sleep(for: .milliseconds(25)) }
            catch { return false }
        }
        writeInProgress = true
        defer { writeInProgress = false }
        do {
            let folder = directory.appendingPathComponent("Arrangements", isDirectory: true)
            try await Task.detached { try CapturedMotionPersistence.save(model, to: folder) }.value
            storageRevision += 1
            if let index = arrangements.firstIndex(where: { $0.id == model.id }) { arrangements[index] = model }
            errorMessage = nil; return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    /// Keep queued requests visible to the app's termination wait. The serial
    /// writer may be idle briefly between tasks while accepted work remains.
    private func beginWriteRequest() {
        pendingWrites += 1
        if !isImporting { isImporting = true }
    }

    private func endWriteRequest() {
        pendingWrites -= 1
        if pendingWrites == 0 { isImporting = false }
    }
}
