import Foundation
import SwiftUI
import HidanCore
import AppKit

/// High-frequency playback changes are observed only by the stage and transport.
/// They do not rebuild the 1,408-row library, navigation, or resource metadata.
@MainActor final class AISTPlaybackState: ObservableObject {
    @Published var frameIndex = 0
    @Published var isPlaying = false
}

@MainActor final class AISTLibraryStore: ObservableObject {
    @Published private(set) var manifest: AISTManifest?
    @Published private(set) var selected: AISTSequence?
    @Published private(set) var motion: AISTMotion?
    @Published private(set) var errorMessage: String?
    @Published private(set) var loading = false
    let playback = AISTPlaybackState()
    private(set) var frameIndex: Int {
        get { playback.frameIndex }
        set { playback.frameIndex = newValue }
    }
    private(set) var isPlaying: Bool {
        get { playback.isPlaying }
        set { playback.isPlaying = newValue }
    }
    @Published var speed: Double = 1 {
        didSet {
            let valid = MotionTempo.clampSpeed(speed)
            if speed != valid { speed = valid }
            if isPlaying { startTimer() }
        }
    }
    @Published var optimized = false
    @Published var loopEnabled = true
    @Published private(set) var loopStart = 0
    @Published private(set) var loopEnd = 0
    @Published var resetCamera = 0
    @Published var mirrored = false
    @Published var upAxis = "y"
    @Published var favorites: Set<String> = []
    private(set) var directory: URL
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var isReloading = false
    private var pendingReference: AISTPracticeReference?
    private var names: [String: String] = [:]
    private let preferences = UserDefaults.standard

    static var defaultDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["HIDAN_AIST_DIR"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HidanClub/Datasets/AISTPlusPlus", isDirectory: true)
    }
    init() {
        directory = Self.defaultDirectory
        if ProcessInfo.processInfo.environment["HIDAN_AIST_DIR"] == nil, let path = preferences.string(forKey: "aist.datasetDirectory") {
            directory = URL(fileURLWithPath: path, isDirectory: true)
        }
        favorites = Set(preferences.stringArray(forKey: "aist.favorites") ?? [])
        loadNames(); reload()
    }
    var currentJoints: [SIMD3<Double>] { motion?.joints(at: frameIndex) ?? [] }
    var loopDuration: Double { Double(loopEnd - loopStart + 1) / (selected?.fps ?? 60) }
    var sourceLabel: String { optimized ? "官方优化关键点" : "逐帧重建关键点" }
    func name(for sequence: AISTSequence) -> String {
        if sequence.isBasic, let name = names[sequence.genreCode + "/" + sequence.choreographyCode] { return name }
        return sequence.category + " · " + sequence.choreographyCode
    }
    func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        preferences.set(favorites.sorted(), forKey: "aist.favorites")
    }
    func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "选择包含 manifest.json 的 AIST++ 数据目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        directory = url; preferences.set(url.path, forKey: "aist.datasetDirectory"); reload()
    }
    func reload() {
        pause(); task?.cancel(); generation = UUID(); loading = true; isReloading = true
        manifest = nil; selected = nil; motion = nil; errorMessage = nil
        frameIndex = 0; loopStart = 0; loopEnd = 0
        let token = generation
        let url = directory.appendingPathComponent("manifest.json")
        let root = directory
        task = Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let value = try JSONDecoder().decode(AISTManifest.self, from: Data(contentsOf: url))
                    try value.validate()
                    for sequence in value.sequences { try sequence.requireBothCoordinateFiles(in: root) }
                    return value
                }.value
                guard token == generation, !Task.isCancelled else { return }
                manifest = result; loading = false; isReloading = false; errorMessage = nil
                if let reference = pendingReference {
                    pendingReference = nil; restoreReference(reference); return
                }
                let initial = result.sequences.first { $0.genreCode == "gMH" && $0.isBasic && !$0.ignored }
                    ?? result.sequences.first { !$0.ignored } ?? result.sequences.first
                if let initial { select(initial) }
            } catch {
                guard token == generation else { return }
                manifest = nil; selected = nil; motion = nil; loading = false; isReloading = false
                errorMessage = "尚未读到完整动作库：\(error.localizedDescription)"
            }
        }
    }
    func select(_ sequence: AISTSequence, preserveRange: Bool = false) {
        guard !isReloading, manifest?.sequences.contains(sequence) == true else {
            errorMessage = "请等待索引读取完成，并选择当前数据目录中的动作。"; return
        }
        pause(); task?.cancel(); generation = UUID(); loading = true; motion = nil
        errorMessage = nil
        let retainRange = preserveRange && selected?.id == sequence.id
        selected = sequence
        if !retainRange { frameIndex = 0; loopStart = 0; loopEnd = sequence.frameCount - 1 }
        let token = generation
        let datasetDirectory = directory; let useOptimized = optimized
        task = Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try sequence.requireBothCoordinateFiles(in: datasetDirectory)
                    return try AISTMotion(directory: datasetDirectory, sequence: sequence, optimized: useOptimized)
                }.value
                guard token == generation, !Task.isCancelled else { return }
                motion = result; loading = false; errorMessage = nil
                resetCamera += 1
            } catch {
                guard token == generation else { return }
                loading = false; errorMessage = error.localizedDescription
            }
        }
    }
    func switchSource() { if let selected { select(selected, preserveRange: true) } }
    func restoreReference(_ reference: AISTPracticeReference) {
        if manifest == nil || isReloading {
            pendingReference = reference
            if !isReloading { reload() }
            return
        }
        guard manifest?.sequences.contains(reference.sequence) == true else {
            errorMessage = "当前数据目录不包含训练所用的原始序列，请选择对应数据目录。"; return
        }
        optimized = reference.optimized; speed = reference.speed; loopEnabled = true
        select(reference.sequence)
        // The load task retains these values because it only replaces the motion.
        loopStart = reference.startFrame; loopEnd = reference.endFrame; frameIndex = reference.startFrame
    }
    func practiceReference() throws -> AISTPracticeReference {
        guard let selected, motion != nil else { throw AISTDataError.invalidManifest }
        return try AISTPracticeReference(sequence: selected, name: name(for: selected), startFrame: loopStart,
                                         endFrame: loopEnd, optimized: optimized, speed: speed)
    }
    func exportSegment() throws -> URL? {
        guard let selected, let manifest, let motion else { throw AISTDataError.invalidManifest }
        pause()
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.prompt = "导出到此文件夹"
        panel.message = "将保存连续 A–B 全帧坐标及含来源、帧范围和许可的 JSON 说明。"
        guard panel.runModal() == .OK, let parent = panel.url else { return nil }
        let data = try motion.bytes(in: loopStart...loopEnd)
        let destination = parent.appendingPathComponent("\(selected.id)_\(loopStart)-\(loopEnd)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        let metadata: [String: Any] = [
            "schemaVersion": 1, "frameIndexBase": 0, "sequenceID": selected.id, "name": name(for: selected),
            "genre": selected.genreName, "startFrame": loopStart, "endFrameInclusive": loopEnd,
            "frameCount": loopEnd - loopStart + 1, "sourceFrameCount": selected.frameCount,
            "fps": selected.fps, "variant": optimized ? "keypoints3d_optim" : "keypoints3d",
            "coordinateType": "float64-little-endian", "arrayOrder": "frame,joint,xyz",
            "jointNamesCOCO": manifest.jointNamesCOCO, "coordinateFile": "keypoints.f64",
            "sourceURL": manifest.sourceURL, "sourceArchiveSHA256": manifest.sourceSHA256,
            "licenseURL": manifest.licenseURL, "sourceQualityFlag": selected.ignored,
            "attribution": "AIST++ annotations © Google LLC, CC BY 4.0. Li, Yang, Ross and Kanazawa, ICCV 2021. Source performances: AIST Dance Video Database, Tsuchida et al., ISMIR 2019.",
            "modifications": "Contiguous source frame range exported as original Float64 bytes. No smoothing, normalization, mirroring or frame reduction. Non-finite values retained."
        ]
        let json = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        do {
            try data.write(to: destination.appendingPathComponent("keypoints.f64"), options: .atomic)
            try json.write(to: destination.appendingPathComponent("metadata.json"), options: .atomic)
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
        return destination
    }
    func seek(_ frame: Int) { frameIndex = min(max(0, frame), max(0, (selected?.frameCount ?? 1) - 1)) }
    func step(_ delta: Int) {
        pause()
        let result = frameIndex.addingReportingOverflow(delta)
        seek(result.overflow ? (delta > 0 ? Int.max : 0) : result.partialValue)
    }
    func setA() { loopStart = min(frameIndex, loopEnd) }
    func setB() { loopEnd = max(frameIndex, loopStart) }
    func fullRange() { loopStart = 0; loopEnd = max(0, (selected?.frameCount ?? 1) - 1) }
    func eightBeats() {
        guard let sequence = selected, let bpm = sequence.bpm else { return }
        loopStart = frameIndex
        let count = max(1, Int((8 * 60 / Double(bpm) * sequence.fps).rounded()))
        loopEnd = min(sequence.frameCount - 1, loopStart + count - 1)
        loopEnabled = true
    }
    func toggle() { isPlaying ? pause() : play() }
    func play() {
        guard motion != nil else { return }
        if loopEnabled, frameIndex < loopStart || frameIndex >= loopEnd { seek(loopStart) }
        if !loopEnabled, frameIndex >= (selected?.frameCount ?? 1) - 1 { seek(0) }
        isPlaying = true; startTimer()
    }
    func pause() { timer?.invalidate(); timer = nil; isPlaying = false }
    private func startTimer() {
        timer?.invalidate()
        // Sequential source-frame progression. A delayed callback advances one frame,
        // never discards observations to catch up to wall time. Slow machines play slower.
        // Above 1× a 60 Hz display shows only some frames; the data order is unchanged.
        timer = Timer(timeInterval: 1 / (60 * MotionTempo.clampSpeed(speed)), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    private func tick() {
        guard isPlaying, let selected else { return }
        let end = loopEnabled ? loopEnd : selected.frameCount - 1
        if frameIndex >= end { if loopEnabled { frameIndex = loopStart } else { pause() } }
        else { frameIndex += 1 }
    }
    private func loadNames() {
        struct File: Decodable {
            struct Entry: Decodable { let genreCode: String; let choreographyCode: String; let sourceName: String }
            let entries: [Entry]
        }
        let bundle: Bundle
        if let url = Bundle.main.url(forResource: "HidanClub_HidanClub", withExtension: "bundle"), let packaged = Bundle(url: url) { bundle = packaged }
        else { bundle = .module }
        guard let url = bundle.url(forResource: "choreography-names", withExtension: "json", subdirectory: "Resources/AIST"),
              let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else { return }
        names = Dictionary(file.entries.map { ($0.genreCode + "/" + $0.choreographyCode, $0.sourceName) }, uniquingKeysWith: { first, _ in first })
    }
}
