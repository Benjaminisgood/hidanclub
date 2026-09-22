import Foundation
import HidanCore
import SwiftUI

@MainActor final class AISTArrangementStore: ObservableObject {
    @Published private(set) var draft: [AISTPracticeReference] = []
    @Published private(set) var draftName = "新的动作编排"
    @Published private(set) var saved: [AISTArrangement] = []
    @Published private(set) var selected: AISTArrangement?
    @Published private(set) var canEditDraft = true
    @Published var errorMessage: String?
    let directory: URL
    private var editingID: UUID?

    init(directory: URL? = nil) {
        self.directory = directory ?? ProcessInfo.processInfo.environment["HIDAN_ARRANGEMENT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HidanClub/Arrangements", isDirectory: true)
        reload()
    }

    var sourceDuration: Double { draft.reduce(0) { $0 + $1.sourceDuration } }
    var duration: Double { draft.reduce(0) { $0 + $1.duration } }

    func reload() {
        let loaded = AISTArrangementPersistence.load(from: directory)
        saved = loaded.models
        draft = loaded.draft?.references ?? []
        draftName = loaded.draft?.name ?? "新的动作编排"
        editingID = loaded.draft?.editingID
        selected = saved.first { $0.id == editingID }
        canEditDraft = loaded.draftReadable
        errorMessage = loaded.errors.isEmpty ? nil : loaded.errors.joined(separator: "\n")
    }

    func add(reference: AISTPracticeReference) throws {
        try reference.validate()
        try replaceDraft(draft + [reference], name: draftName, editingID: editingID)
    }
    func renameDraft(_ name: String) throws { try replaceDraft(draft, name: name, editingID: editingID) }
    func newDraft() throws { try replaceDraft([], name: "新的动作编排", editingID: nil) }
    func loadDraft(_ arrangement: AISTArrangement) throws {
        try arrangement.validate()
        try replaceDraft(arrangement.references, name: arrangement.name, editingID: arrangement.id)
    }
    func moveDraft(at index: Int, by delta: Int) throws {
        let (target, overflow) = index.addingReportingOverflow(delta)
        guard !overflow, draft.indices.contains(index), draft.indices.contains(target) else { throw AISTArrangementError.invalidIndex }
        var updated = draft; updated.swapAt(index, target)
        try replaceDraft(updated, name: draftName, editingID: editingID)
    }
    func removeDraft(at index: Int) throws {
        guard draft.indices.contains(index) else { throw AISTArrangementError.invalidIndex }
        var updated = draft; updated.remove(at: index)
        try replaceDraft(updated, name: draftName, editingID: editingID)
    }
    @discardableResult func saveDraft(name: String) throws -> AISTArrangement {
        guard canEditDraft else { throw AISTArrangementError.corruptedFile }
        let existing = saved.first { $0.id == editingID }
        let model = try AISTArrangement(id: existing?.id ?? UUID(), name: name,
                                        createdAt: existing?.createdAt ?? Date(), references: draft)
        try AISTArrangementPersistence.validateDraftWrite(in: directory)
        try AISTArrangementPersistence.save(model, to: directory)
        saved.removeAll { $0.id == model.id }; saved.insert(model, at: 0)
        try replaceDraft(model.references, name: model.name, editingID: model.id)
        return model
    }

    private func replaceDraft(_ references: [AISTPracticeReference], name: String, editingID: UUID?) throws {
        guard canEditDraft else { throw AISTArrangementError.corruptedFile }
        let updated = AISTArrangementDraft(schemaVersion: 1, name: name, editingID: editingID, references: references)
        try AISTArrangementPersistence.saveDraft(updated, to: directory)
        draft = references; draftName = name; self.editingID = editingID
        selected = saved.first { $0.id == editingID }
    }
}

private struct AISTArrangementDraft: Codable {
    let schemaVersion: Int
    let name: String
    let editingID: UUID?
    let references: [AISTPracticeReference]
    func validate() throws {
        guard schemaVersion == 1 else { throw AISTArrangementError.corruptedFile }
        for reference in references { try reference.validate() }
        guard references.reduce(0.0, { $0 + $1.duration }).isFinite else { throw AISTArrangementError.invalidArrangement }
    }
}

private enum AISTArrangementPersistence {
    struct LoadResult {
        var models: [AISTArrangement] = []
        var draft: AISTArrangementDraft?
        var draftReadable = true
        var errors: [String] = []
    }
    static func load(from directory: URL) -> LoadResult {
        var result = LoadResult()
        guard FileManager.default.fileExists(atPath: directory.path) else { return result }
        do {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) where url.pathExtension == "json" {
                do {
                    try validateFile(url, directory: directory)
                    if url.lastPathComponent == "draft.json" {
                        let draft = try JSONDecoder().decode(AISTArrangementDraft.self, from: Data(contentsOf: url))
                        try draft.validate(); result.draft = draft
                    } else {
                        guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { throw AISTArrangementError.corruptedFile }
                        let model = try JSONDecoder().decode(AISTArrangement.self, from: Data(contentsOf: url))
                        try model.validate()
                        guard model.id == id else { throw AISTArrangementError.corruptedFile }
                        result.models.append(model)
                    }
                } catch {
                    if url.lastPathComponent == "draft.json" { result.draftReadable = false }
                    result.errors.append("\(url.lastPathComponent) 无法读取，原文件已保留：\(error.localizedDescription)")
                }
            }
        } catch { result.draftReadable = false; result.errors.append(error.localizedDescription) }
        result.models.sort { $0.updatedAt > $1.updatedAt }
        return result
    }
    static func save(_ model: AISTArrangement, to directory: URL) throws {
        try model.validate()
        let url = directory.appendingPathComponent(model.id.uuidString.lowercased()).appendingPathExtension("json")
        try prepareWrite(url, directory: directory)
        if FileManager.default.fileExists(atPath: url.path) {
            guard let old = try? JSONDecoder().decode(AISTArrangement.self, from: Data(contentsOf: url)),
                  old.id == model.id, (try? old.validate()) != nil else { throw AISTArrangementError.corruptedFile }
        }
        try encode(model).write(to: url, options: .atomic)
    }
    static func saveDraft(_ draft: AISTArrangementDraft, to directory: URL) throws {
        try draft.validate()
        let url = directory.appendingPathComponent("draft.json")
        try validateDraftWrite(in: directory)
        try encode(draft).write(to: url, options: .atomic)
    }
    static func validateDraftWrite(in directory: URL) throws {
        let url = directory.appendingPathComponent("draft.json")
        try prepareWrite(url, directory: directory)
        if FileManager.default.fileExists(atPath: url.path) {
            guard let old = try? JSONDecoder().decode(AISTArrangementDraft.self, from: Data(contentsOf: url)),
                  (try? old.validate()) != nil else { throw AISTArrangementError.corruptedFile }
        }
    }
    private static func prepareWrite(_ url: URL, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            try validateFile(url, directory: directory)
        }
    }
    private static func validateFile(_ url: URL, directory: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              url.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath() else { throw AISTArrangementError.corruptedFile }
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
}
