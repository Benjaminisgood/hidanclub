import Foundation
import SwiftUI

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
