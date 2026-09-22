import Foundation
import HidanCore

/// Plays app-generated practice coordinates. Gallery previews stay on the raw
/// sample; opening a move or starting practice uses the smoothed layer by default.
@MainActor final class PracticeMotionStore: ObservableObject {
    @Published private(set) var ready = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var moves: [DanceMove] = []
    @Published private(set) var title = ""
    @Published private(set) var motion: AISTMotion?
    @Published private(set) var optimized = true
    @Published private(set) var loading = false
    /// Midpoint tempo of the clip now on screen. Playback at 1× matches this BPM.
    @Published private(set) var beatBPM: Double?
    @Published var speed: Double = 1 {
        didSet {
            let valid = speed.isFinite ? min(1, max(0.25, speed)) : 1
            if speed != valid { speed = valid }
            if playback.isPlaying { startTimer() }
        }
    }
    @Published var mirrored = false
    @Published var resetCamera = 0
    let playback = AISTPlaybackState()
    let directory: URL
    private var playlist: [DanceMove] = []
    private var playlistIndex = 0
    private var timer: Timer?
    private var prepareTask: Task<Void, Never>?

    var currentJoints: [SIMD3<Double>] { motion?.joints(at: playback.frameIndex) ?? [] }
    var frameCount: Int { motion?.frameCount ?? 1 }

    init() {
        if let path = ProcessInfo.processInfo.environment["HIDAN_PRACTICE_MOTION_DIR"] {
            directory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HidanClub/PracticeMotions", isDirectory: true)
        }
        prepare()
    }

    func prepare() {
        prepareTask?.cancel()
        let directory = directory
        prepareTask = Task {
            do {
                try await Task.detached(priority: .userInitiated) { try PracticeMotionLibrary.install(into: directory) }.value
                guard !Task.isCancelled else { return }
                ready = true
                errorMessage = nil
            } catch {
                ready = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func open(_ playlist: [DanceMove], title: String, optimized: Bool) {
        pause()
        let playable = playlist.filter { DanceCatalog.move(id: $0.id) != nil }
        guard let first = playable.first else {
            errorMessage = PracticeMotionError.unknownMove(playlist.first?.id ?? "").localizedDescription
            return
        }
        self.playlist = playable
        playlistIndex = 0
        self.title = title
        self.optimized = optimized
        moves = playable
        beatBPM = Self.tempo(of: first)
        load(first, resume: false)
    }

    func toggle() { playback.isPlaying ? pause() : play() }
    func play() {
        guard motion != nil else { return }
        playback.isPlaying = true
        startTimer()
    }
    func pause() { timer?.invalidate(); timer = nil; playback.isPlaying = false }
    func seek(_ frame: Int) {
        playback.frameIndex = min(max(0, frame), max(0, frameCount - 1))
    }
    func step(_ delta: Int) {
        pause()
        let result = playback.frameIndex.addingReportingOverflow(delta)
        seek(result.overflow ? (delta > 0 ? Int.max : 0) : result.partialValue)
    }

    private func load(_ move: DanceMove, resume: Bool) {
        pause()
        loading = true
        motion = nil
        playback.frameIndex = 0
        let directory = directory
        let optimized = optimized
        let id = move.id
        Task {
            do {
                let loaded = try await Task.detached { try PracticeMotionLibrary.load(in: directory, id: id, optimized: optimized) }.value
                guard playlist.indices.contains(playlistIndex), playlist[playlistIndex].id == id else { return }
                beatBPM = Self.tempo(of: move)
                motion = loaded
                loading = false
                errorMessage = nil
                resetCamera += 1
                if resume { play() }
            } catch {
                loading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer(timeInterval: 1 / (60 * min(1, max(0.25, speed))), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func tick() {
        guard playback.isPlaying, let motion else { return }
        if playback.frameIndex >= motion.frameCount - 1 {
            if playlist.count > 1 {
                playlistIndex = (playlistIndex + 1) % playlist.count
                load(playlist[playlistIndex], resume: true)
            } else {
                playback.frameIndex = 0
            }
        } else {
            playback.frameIndex += 1
        }
    }

    private static func tempo(of move: DanceMove) -> Double {
        Double(move.bpmMin + move.bpmMax) / 2
    }
}
