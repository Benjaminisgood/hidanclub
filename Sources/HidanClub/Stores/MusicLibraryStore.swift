import AVFoundation
import Foundation
import HidanCore

/// Imported music stays on this Mac as unmodified copies, with one JSON record per
/// track that also carries the local tempo estimate and any manual BPM correction.
@MainActor final class MusicLibraryStore: ObservableObject {
    @Published private(set) var tracks: [LibraryTrack] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isImporting = false
    @Published private(set) var analyzing: Set<UUID> = []
    /// Track the music bar restores on the next launch; nil means the built-in beat.
    @Published private(set) var selectedTrackID: UUID?
    @Published private(set) var multiplier: BeatMultiplier = .single
    @Published var errorMessage: String?
    let directory: URL

    private struct Analysis { let work: Task<MusicBeatAnalysis, Error>; let completion: Task<Void, Never> }
    private var importCount = 0
    private var storageRevision = 0
    private var loadingTask: Task<Void, Never>?
    private var analyses: [UUID: Analysis] = [:]

    init(directory: URL? = nil) {
        self.directory = directory ?? ProcessInfo.processInfo.environment["HIDAN_MUSIC_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HidanClub/Music", isDirectory: true)
        reload()
    }

    var isBusy: Bool { isImporting || !analyzing.isEmpty }
    var selectedTrack: LibraryTrack? { track(selectedTrackID) }

    func track(_ id: UUID?) -> LibraryTrack? {
        guard let id else { return nil }
        return tracks.first { $0.id == id }
    }

    func url(for track: LibraryTrack) throws -> URL {
        try MusicLibraryPersistence.trackURL(for: track, in: directory)
    }

    func reload() {
        loadingTask?.cancel()
        isLoading = true
        let folder = directory, startedRevision = storageRevision
        loadingTask = Task { [weak self] in
            let result = await Task.detached { MusicLibraryPersistence.load(from: folder) }.value
            guard let self, !Task.isCancelled else { return }
            guard storageRevision == startedRevision else { reload(); return }
            tracks = result.tracks
            selectedTrackID = tracks.contains { $0.id == result.selection.trackID } ? result.selection.trackID : nil
            multiplier = BeatMultiplier(rawValue: result.selection.multiplier) ?? .single
            isLoading = false
            if !result.errors.isEmpty { errorMessage = result.errors.joined(separator: "\n") }
            for track in tracks where track.needsAnalysis { analyze(track.id) }
        }
    }

    /// Copies original bytes; no transcoding. Every file is attempted, failures are
    /// reported by name, and each stored track is analyzed right away.
    func importTracks(urls: [URL]) async -> [LibraryTrack] {
        importCount += 1; isImporting = true
        defer { importCount -= 1; isImporting = importCount > 0 }
        while isLoading {
            do { try await Task.sleep(nanoseconds: 50_000_000) }
            catch { return [] }
        }
        var imported: [LibraryTrack] = []
        let folder = directory
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let track = try await Task.detached(priority: .userInitiated) {
                    try MusicLibraryPersistence.importTrack(from: url, to: folder)
                }.value
                tracks.removeAll { $0.id == track.id }; tracks.insert(track, at: 0)
                storageRevision += 1
                imported.append(track)
                analyze(track.id)
            } catch {
                let message = "\(url.lastPathComponent)：\(error.localizedDescription)"
                errorMessage = errorMessage.map { $0 + "\n" + message } ?? message
            }
        }
        return imported
    }

    /// Runs the local tempo estimate for one stored copy and persists the outcome.
    /// A failed estimate is recorded so it is not retried on every launch.
    func analyze(_ id: UUID) {
        guard let track = track(id), analyses[id] == nil else { return }
        let sourceURL: URL
        do { sourceURL = try url(for: track) }
        catch { errorMessage = "\(track.name)：\(error.localizedDescription)"; return }
        analyzing.insert(id)
        let work = Task.detached(priority: .utility) { try MusicBeatAnalyzer.analyze(url: sourceURL) }
        let completion = Task { [weak self] in
            let outcome: Result<MusicBeatAnalysis, Error>
            do { outcome = .success(try await work.value) } catch { outcome = .failure(error) }
            guard let self, !Task.isCancelled, analyses[id]?.work == work else { return }
            analyses[id] = nil; analyzing.remove(id)
            guard var current = self.track(id) else { return }
            switch outcome {
            case .success(let analysis):
                current.tempo = LibraryTrack.Tempo(bpm: analysis.estimate.bpm, confidence: analysis.estimate.confidence,
                                                   analyzedSeconds: analysis.analyzedSeconds, method: analysis.method, analyzedAt: Date())
                current.analysisFailure = nil
            case .failure(let error):
                if error is CancellationError { return }
                current.tempo = nil
                current.analysisFailure = error.localizedDescription
            }
            store(current)
        }
        analyses[id] = Analysis(work: work, completion: completion)
    }

    func reanalyze(_ id: UUID) {
        cancelAnalysis(id)
        analyze(id)
    }

    func cancelAnalyses() {
        for id in Array(analyses.keys) { cancelAnalysis(id) }
    }

    private func cancelAnalysis(_ id: UUID) {
        guard let analysis = analyses.removeValue(forKey: id) else { return }
        analysis.work.cancel(); analysis.completion.cancel()
        analyzing.remove(id)
    }

    /// nil clears the correction and returns to the estimate.
    func setManualBPM(_ id: UUID, bpm: Double?) throws {
        guard var current = track(id) else { throw MusicLibraryError.missingAudio }
        if let bpm { guard MotionTempo.isValidTrackBPM(bpm) else { throw MusicLibraryError.invalidBPM } }
        current.manualBPM = bpm
        try MusicLibraryPersistence.save(current, to: directory)
        replace(current)
    }

    func select(_ id: UUID?) {
        guard id == nil || tracks.contains(where: { $0.id == id }) else { return }
        selectedTrackID = id
        persistSelection()
    }

    func setMultiplier(_ value: BeatMultiplier) {
        guard value != multiplier else { return }
        multiplier = value
        persistSelection()
    }

    private func persistSelection() {
        do {
            try MusicLibraryPersistence.saveSelection(.init(schemaVersion: 1, trackID: selectedTrackID, multiplier: multiplier.rawValue), to: directory)
            storageRevision += 1
        } catch { errorMessage = error.localizedDescription }
    }

    private func store(_ track: LibraryTrack) {
        do { try MusicLibraryPersistence.save(track, to: directory); replace(track) }
        catch { errorMessage = "\(track.name)：\(error.localizedDescription)" }
    }

    private func replace(_ track: LibraryTrack) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        tracks[index] = track
        storageRevision += 1
    }

    deinit {
        loadingTask?.cancel()
        for analysis in analyses.values { analysis.work.cancel(); analysis.completion.cancel() }
    }
}

enum MusicLibraryPersistence {
    struct Selection: Codable, Sendable, Equatable {
        var schemaVersion: Int
        var trackID: UUID?
        var multiplier: Double
    }
    struct LoadResult: Sendable { let tracks: [LibraryTrack]; let selection: Selection; let errors: [String] }

    static func load(from directory: URL) -> LoadResult {
        var selection = Selection(schemaVersion: 1, trackID: nil, multiplier: 1)
        guard FileManager.default.fileExists(atPath: directory.path) else { return LoadResult(tracks: [], selection: selection, errors: []) }
        var tracks: [LibraryTrack] = [], errors: [String] = []
        do {
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) where file.pathExtension == "json" {
                do {
                    if file.lastPathComponent == "selection.json" {
                        selection = try readSelection(at: file, directory: directory)
                    } else {
                        let track = try read(at: file, directory: directory)
                        _ = try trackURL(for: track, in: directory)
                        tracks.append(track)
                    }
                } catch { errors.append("\(file.lastPathComponent) 无法读取，文件已保留：\(error.localizedDescription)") }
            }
        } catch { errors.append(error.localizedDescription) }
        return LoadResult(tracks: tracks.sorted { $0.importedAt > $1.importedAt }, selection: selection, errors: errors)
    }

    /// Verifies the source decodes, copies its bytes unchanged and verifies the copy.
    static func importTrack(from sourceURL: URL, to directory: URL) throws -> LibraryTrack {
        let audio: AVAudioFile
        do { audio = try AVAudioFile(forReading: sourceURL) }
        catch { throw MusicLibraryError.unreadableAudio(error.localizedDescription) }
        let format = audio.fileFormat
        guard audio.length > 0, format.sampleRate > 0, format.channelCount > 0 else { throw MusicLibraryError.unreadableAudio("文件里没有音频数据。") }
        let id = UUID()
        let sourceExtension = sourceURL.pathExtension.lowercased()
        let validExtension = !sourceExtension.isEmpty && sourceExtension.count <= 16 && sourceExtension.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
        let filename = id.uuidString.lowercased() + "." + (validExtension ? sourceExtension : "audio")
        let rawName = sourceURL.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let track = LibraryTrack(schemaVersion: 1, id: id, name: rawName.isEmpty ? "未命名音乐" : rawName,
                                 originalFilename: sourceURL.lastPathComponent, storedFilename: filename, importedAt: Date(),
                                 duration: Double(audio.length) / format.sampleRate, sampleRate: format.sampleRate,
                                 channelCount: Int(format.channelCount), tempo: nil, manualBPM: nil, analysisFailure: nil)
        try track.validate()
        let originals = directory.appendingPathComponent("Originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        guard originals.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath() else { throw MusicLibraryError.invalidMetadata }
        let destination = originals.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        do {
            let copy = try AVAudioFile(forReading: destination)
            guard copy.length == audio.length else { throw MusicLibraryError.unreadableAudio("副本长度与原文件不一致。") }
            try save(track, to: directory)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return track
    }

    static func trackURL(for track: LibraryTrack, in directory: URL) throws -> URL {
        try track.validate()
        let originals = directory.appendingPathComponent("Originals", isDirectory: true)
        let url = originals.appendingPathComponent(track.storedFilename)
        guard originals.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath(),
              url.resolvingSymlinksInPath().deletingLastPathComponent() == originals.resolvingSymlinksInPath(),
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              FileManager.default.isReadableFile(atPath: url.path) else { throw MusicLibraryError.missingAudio }
        return url
    }

    static func save(_ track: LibraryTrack, to directory: URL) throws {
        try track.validate()
        _ = try trackURL(for: track, in: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(track.id.uuidString.lowercased() + ".json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { _ = try read(at: file, directory: directory) }
            catch { throw MusicLibraryError.corruptedExistingFile }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(track).write(to: file, options: .atomic)
    }

    static func saveSelection(_ selection: Selection, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("selection.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { _ = try readSelection(at: file, directory: directory) }
            catch { throw MusicLibraryError.corruptedExistingFile }
        }
        try JSONEncoder().encode(selection).write(to: file, options: .atomic)
    }

    private static func read(at file: URL, directory: URL) throws -> LibraryTrack {
        guard UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
              file.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath() else { throw MusicLibraryError.invalidMetadata }
        let track = try JSONDecoder().decode(LibraryTrack.self, from: Data(contentsOf: file)); try track.validate()
        guard track.id.uuidString.lowercased() == file.deletingPathExtension().lastPathComponent.lowercased() else { throw MusicLibraryError.invalidMetadata }
        return track
    }

    private static func readSelection(at file: URL, directory: URL) throws -> Selection {
        guard file.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath() else { throw MusicLibraryError.invalidMetadata }
        let selection = try JSONDecoder().decode(Selection.self, from: Data(contentsOf: file))
        guard selection.schemaVersion == 1, BeatMultiplier(rawValue: selection.multiplier) != nil else { throw MusicLibraryError.invalidMetadata }
        return selection
    }
}
