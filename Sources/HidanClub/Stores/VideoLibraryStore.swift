import AVFoundation
import Foundation
import SwiftUI

@MainActor final class VideoLibraryStore: ObservableObject {
    @Published private(set) var items: [LibraryVideo] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var isLoading = false
    @Published private(set) var isImporting = false
    @Published private(set) var isAnalyzing = false
    @Published private(set) var analysisVideoID: UUID?
    @Published private(set) var progress = 0.0
    @Published private(set) var analysisStatus: String?
    @Published var errorMessage: String?
    let directory: URL

    private var importCount = 0
    private var activeRecordingPaths: Set<String> = []
    private var storageRevision = 0
    private var generation = UUID()
    private var worker: Task<PoseReport, Error>?
    private var completion: Task<Void, Never>?
    private var loadingTask: Task<Void, Never>?

    init(directory: URL? = nil) {
        self.directory = directory ?? ProcessInfo.processInfo.environment["HIDAN_VIDEO_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HidanClub/Videos", isDirectory: true)
        reload()
    }

    var selected: LibraryVideo? { items.first { $0.id == selectedID } }

    func reload() {
        loadingTask?.cancel()
        isLoading = true
        let folder = directory, startedRevision = storageRevision
        loadingTask = Task { [weak self] in
            let result = await Task.detached { VideoLibraryPersistence.load(from: folder) }.value
            guard let self, !Task.isCancelled else { return }
            guard storageRevision == startedRevision else { reload(); return }
            items = result.items
            if !items.contains(where: { $0.id == self.selectedID }) {
                selectedID = items.contains(where: { $0.id == result.selectedID }) ? result.selectedID : items.first?.id
            }
            isLoading = false
            if !result.errors.isEmpty { errorMessage = result.errors.joined(separator: "\n") }
        }
    }

    func select(_ id: UUID?) {
        guard id != selectedID, id == nil || items.contains(where: { $0.id == id }) else { return }
        cancelAnalysis()
        selectedID = id
        analysisStatus = nil
        do { try VideoLibraryPersistence.saveSelection(id, to: directory); storageRevision += 1 }
        catch { errorMessage = error.localizedDescription }
    }

    func url(for item: LibraryVideo) throws -> URL {
        try VideoLibraryPersistence.videoURL(for: item, in: directory)
    }

    @discardableResult func selectModel(id: UUID) -> Bool {
        guard let item = items.first(where: { $0.modelID == id }) else { return false }
        select(item.id)
        return true
    }

    /// Only the recorder's atomic completion marker makes a pending movie eligible.
    /// Unmarked files may still be open by AVFoundation and must never be imported.
    func recoverFinishedRecordings(from pendingDirectory: URL) async {
        let result = await Task.detached { VideoLibraryPersistence.finishedRecordings(in: pendingDirectory) }.value
        guard !Task.isCancelled else { return }
        if !result.errors.isEmpty {
            let messages = result.errors.joined(separator: "\n")
            errorMessage = errorMessage.map { $0 + "\n" + messages } ?? messages
        }
        while isLoading {
            do { try await Task.sleep(nanoseconds: 50_000_000) }
            catch { return }
        }
        for url in result.urls {
            guard !Task.isCancelled else { return }
            let sourcePath = url.standardizedFileURL.resolvingSymlinksInPath().path
            // A repeated startup scan must not change the user's restored selection.
            guard !items.contains(where: { $0.recordingSourcePath == sourcePath }) else { continue }
            await importVideo(url: url, source: .trainingRecording)
        }
    }

    /// Copies original bytes. No export session, transcoding, resizing or sampling.
    func importVideo(url: URL, source: LibraryVideo.Source = .imported) async {
        importCount += 1; isImporting = true
        defer { importCount -= 1; isImporting = importCount > 0 }
        let recordingPath = source == .trainingRecording ? url.standardizedFileURL.resolvingSymlinksInPath().path : nil
        if let recordingPath {
            while activeRecordingPaths.contains(recordingPath) || isLoading {
                do { try await Task.sleep(nanoseconds: 50_000_000) }
                catch { return }
            }
            if let existing = items.first(where: { $0.recordingSourcePath == recordingPath }) {
                select(existing.id)
                return
            }
            activeRecordingPaths.insert(recordingPath)
        }
        defer { if let recordingPath { activeRecordingPaths.remove(recordingPath) } }
        let folder = directory
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let item = try await Task.detached(priority: .userInitiated) {
                try await VideoLibraryPersistence.importVideo(from: url, source: source, to: folder)
            }.value
            items.removeAll { $0.id == item.id }; items.insert(item, at: 0)
            storageRevision += 1
            select(item.id)
        } catch {
            let label = source == .trainingRecording ? url.path : url.lastPathComponent
            let message = "\(label)：\(error.localizedDescription)"
            errorMessage = errorMessage.map { $0 + "\n" + message } ?? message
        }
    }

    func analyzeSelected(captured: CapturedMotionStore) {
        guard let item = selected, !isAnalyzing else { return }
        do {
            let sourceURL = try url(for: item)
            cancelAnalysis()
            let token = UUID(); generation = token
            isAnalyzing = true; analysisVideoID = item.id; progress = 0
            analysisStatus = "正在逐帧识别肢体"; errorMessage = nil
            let progressHandler: @Sendable (Double) async -> Void = { [weak self] value in
                await self?.receiveProgress(value, token: token)
            }
            let analysis = Task.detached(priority: .userInitiated) {
                try await PoseVideoDecoder.analyze(url: sourceURL, onProgress: progressHandler)
            }
            worker = analysis
            // This task belongs to the store, so navigation does not discard results.
            completion = Task { [weak self] in
                do {
                    let report = try await analysis.value
                    guard let self, isCurrent(token, videoID: item.id) else { return }
                    analysisStatus = "正在保存动作模型"
                    // Construct and persist independently: finishing in the background
                    // must not replace a model currently playing on the training stage.
                    let model = CapturedMotion(schemaVersion: 1, id: UUID(), name: item.name, createdAt: Date(),
                                               imageAspectRatio: item.aspectRatio, report: report,
                                               segments: [CapturedMotionSegment(name: "完整舞蹈", startFrame: 0, endFrame: report.frames.count - 1)])
                    try model.validate()
                    let modelDirectory = captured.directory
                    try await Task.detached { try CapturedMotionPersistence.save(model, to: modelDirectory) }.value
                    guard isCurrent(token, videoID: item.id) else { return }
                    guard let index = items.firstIndex(where: { $0.id == item.id }) else { throw VideoLibraryError.invalidMetadata }
                    var linked = items[index]; linked.modelID = model.id
                    try VideoLibraryPersistence.save(linked, to: directory)
                    items[index] = linked; storageRevision += 1
                    captured.reload()
                    progress = 1; analysisStatus = "识别完成，动作模型已保存"
                    finishAnalysis()
                } catch {
                    guard let self, isCurrent(token, videoID: item.id) else { return }
                    if !(error is CancellationError) { errorMessage = error.localizedDescription }
                    analysisStatus = nil; progress = 0; finishAnalysis()
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func cancelAnalysis() {
        generation = UUID(); worker?.cancel(); completion?.cancel()
        worker = nil; completion = nil
        if isAnalyzing { analysisStatus = "识别已取消"; progress = 0 }
        isAnalyzing = false; analysisVideoID = nil
    }

    private func isCurrent(_ token: UUID, videoID: UUID) -> Bool {
        !Task.isCancelled && generation == token && selectedID == videoID
    }
    private func receiveProgress(_ value: Double, token: UUID) {
        guard generation == token, isAnalyzing else { return }
        progress = min(max(value, 0), 0.999)
    }
    private func finishAnalysis() { isAnalyzing = false; analysisVideoID = nil; worker = nil; completion = nil }

    deinit { worker?.cancel(); completion?.cancel(); loadingTask?.cancel() }
}

enum VideoLibraryPersistence {
    struct LoadResult: Sendable { let items: [LibraryVideo]; let selectedID: UUID?; let errors: [String] }
    struct RecordingRecoveryResult: Sendable { let urls: [URL]; let errors: [String] }
    private struct Selection: Codable { let schemaVersion: Int; let videoID: UUID? }

    static func finishedRecordings(in directory: URL) -> RecordingRecoveryResult {
        guard FileManager.default.fileExists(atPath: directory.path) else { return RecordingRecoveryResult(urls: [], errors: []) }
        let expectedMarker = Data("hidan-recording-ready-v1\n".utf8)
        let resolvedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        var urls: [URL] = [], errors: [String] = []
        do {
            let candidates = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            for marker in candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where marker.lastPathComponent.hasSuffix(".mov.ready") {
                let movie = marker.deletingPathExtension()
                do {
                    let markerInfo = try marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard markerInfo.isRegularFile == true, markerInfo.isSymbolicLink != true,
                          marker.resolvingSymlinksInPath().deletingLastPathComponent() == resolvedDirectory,
                          markerInfo.fileSize == expectedMarker.count,
                          try Data(contentsOf: marker) == expectedMarker else { throw VideoLibraryError.invalidMetadata }
                    let movieInfo = try movie.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard movieInfo.isRegularFile == true, movieInfo.isSymbolicLink != true,
                          movie.resolvingSymlinksInPath().deletingLastPathComponent() == resolvedDirectory else { throw VideoLibraryError.missingVideo }
                    urls.append(movie)
                } catch { errors.append("未能恢复录像 \(movie.path)：\(error.localizedDescription) 完成标记和原文件已保留。") }
            }
        } catch { errors.append("无法扫描待恢复录像 \(directory.path)：\(error.localizedDescription)") }
        return RecordingRecoveryResult(urls: urls, errors: errors)
    }

    static func load(from directory: URL) -> LoadResult {
        guard FileManager.default.fileExists(atPath: directory.path) else { return LoadResult(items: [], selectedID: nil, errors: []) }
        var items: [LibraryVideo] = [], errors: [String] = []
        var selectedID: UUID?
        do {
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) where file.pathExtension == "json" {
                do {
                    if file.lastPathComponent == "selection.json" {
                        selectedID = try readSelection(at: file, directory: directory).videoID
                    } else {
                        let item = try read(at: file, directory: directory)
                        _ = try videoURL(for: item, in: directory)
                        items.append(item)
                    }
                } catch { errors.append("\(file.lastPathComponent) 无法读取，文件已保留：\(error.localizedDescription)") }
            }
        } catch { errors.append(error.localizedDescription) }
        return LoadResult(items: items.sorted { $0.importedAt > $1.importedAt }, selectedID: selectedID, errors: errors)
    }

    static func importVideo(from sourceURL: URL, source: LibraryVideo.Source, to directory: URL) async throws -> LibraryVideo {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw PoseAnalysisError.noVideoTrack }
        let duration = try await asset.load(.duration).seconds
        let size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
        let orientation = try PoseVideoDecoder.imageOrientation(for: transform)
        let bounds = CGRect(origin: .zero, size: size).applying(transform).standardized
        let id = UUID()
        let sourceExtension = sourceURL.pathExtension.lowercased()
        let validExtension = !sourceExtension.isEmpty && sourceExtension.count <= 16 && sourceExtension.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
        let filename = id.uuidString.lowercased() + "." + (validExtension ? sourceExtension : "mov")
        let rawName = sourceURL.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = LibraryVideo(schemaVersion: 1, id: id, name: rawName.isEmpty ? "未命名视频" : rawName,
                                originalFilename: sourceURL.lastPathComponent, storedFilename: filename, source: source,
                                recordingSourcePath: source == .trainingRecording ? sourceURL.standardizedFileURL.resolvingSymlinksInPath().path : nil,
                                importedAt: Date(), duration: duration, displayWidth: bounds.width, displayHeight: bounds.height,
                                orientation: orientation.rawValue, modelID: nil)
        try item.validate()
        let originals = directory.appendingPathComponent("Originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        guard originals.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath() else { throw VideoLibraryError.invalidMetadata }
        let destination = originals.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        do { try save(item, to: directory) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        return item
    }

    static func videoURL(for item: LibraryVideo, in directory: URL) throws -> URL {
        try item.validate()
        let originals = directory.appendingPathComponent("Originals", isDirectory: true)
        let url = originals.appendingPathComponent(item.storedFilename)
        guard originals.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath(),
              url.resolvingSymlinksInPath().deletingLastPathComponent() == originals.resolvingSymlinksInPath(),
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              FileManager.default.isReadableFile(atPath: url.path) else { throw VideoLibraryError.missingVideo }
        return url
    }

    static func save(_ item: LibraryVideo, to directory: URL) throws {
        try item.validate()
        _ = try videoURL(for: item, in: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(item.id.uuidString.lowercased() + ".json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { _ = try read(at: file, directory: directory) }
            catch { throw VideoLibraryError.corruptedExistingFile }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(item).write(to: file, options: .atomic)
    }

    static func saveSelection(_ id: UUID?, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("selection.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { _ = try readSelection(at: file, directory: directory) }
            catch { throw VideoLibraryError.corruptedExistingFile }
        }
        try JSONEncoder().encode(Selection(schemaVersion: 1, videoID: id)).write(to: file, options: .atomic)
    }

    private static func read(at file: URL, directory: URL) throws -> LibraryVideo {
        guard UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
              file.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath() else { throw VideoLibraryError.invalidMetadata }
        let item = try JSONDecoder().decode(LibraryVideo.self, from: Data(contentsOf: file)); try item.validate()
        guard item.id.uuidString.lowercased() == file.deletingPathExtension().lastPathComponent.lowercased() else { throw VideoLibraryError.invalidMetadata }
        return item
    }
    private static func readSelection(at file: URL, directory: URL) throws -> Selection {
        guard file.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath() else { throw VideoLibraryError.invalidMetadata }
        let selection = try JSONDecoder().decode(Selection.self, from: Data(contentsOf: file))
        guard selection.schemaVersion == 1 else { throw VideoLibraryError.invalidMetadata }
        return selection
    }
}
