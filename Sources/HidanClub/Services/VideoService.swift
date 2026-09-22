import AVFoundation
import SwiftUI

@MainActor final class VideoService: ObservableObject {
    let player = AVPlayer()
    @Published var name: String?
    @Published var currentTime = 0.0
    @Published var duration = 0.0
    @Published var rate: Float = 1
    @Published var mirrored = false
    @Published var loopEnabled = false
    @Published var loopStart = 0.0
    @Published var loopEnd = 0.0
    @Published var errorMessage: String?
    @Published var isPlaying = false
    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    private var loopSeeking = false
    private var playbackRequested = false
    private var generation = UUID()

    init() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                self.isPlaying = self.player.rate > 0
                if self.loopEnabled, self.playbackRequested, self.isPlaying, self.loopEnd - self.loopStart >= 0.25, self.currentTime >= self.loopEnd {
                    self.restartLoop()
                }
            }
        }
    }

    func load(url: URL) {
        player.pause(); isPlaying = false; loopSeeking = false; playbackRequested = false
        let token = UUID(); generation = token
        let asset = AVURLAsset(url: url)
        Task {
            do {
                let duration = try await asset.load(.duration).seconds
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard duration.isFinite, duration > 0, !tracks.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                guard generation == token else { return }
                let item = AVPlayerItem(asset: asset); item.audioTimePitchAlgorithm = .spectral
                if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
                player.replaceCurrentItem(with: item)
                endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self = self] _ in
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        if self.playbackRequested, self.loopEnabled, self.loopEnd - self.loopStart >= 0.25 { self.restartLoop() }
                        else { self.isPlaying = false; self.playbackRequested = false }
                    }
                }
                self.duration = duration; currentTime = 0; loopStart = 0; loopEnd = duration
                loopEnabled = false; name = url.lastPathComponent; errorMessage = nil
            } catch {
                guard generation == token else { return }
                errorMessage = "视频无法打开：\(error.localizedDescription)"
            }
        }
    }
    func toggle() {
        if player.rate > 0 || loopSeeking { pause() }
        else if name != nil {
            playbackRequested = true
            if currentTime >= duration - 0.1 { seek(loopEnabled ? loopStart : 0) }
            player.playImmediately(atRate: rate); isPlaying = true
        }
    }
    func pause() { playbackRequested = false; player.pause(); isPlaying = false; loopSeeking = false }
    func seek(_ seconds: Double) { player.seek(to: CMTime(seconds: max(0, min(duration, seconds)), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
    func setRate(_ value: Float) { rate = value; if isPlaying { player.rate = value } }

    private func restartLoop() {
        guard playbackRequested, !loopSeeking else { return }
        loopSeeking = true
        let token = generation
        player.seek(to: CMTime(seconds: loopStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.generation == token, self.loopSeeking else { return }
                self.loopSeeking = false
                if finished, self.playbackRequested, self.loopEnabled { self.player.playImmediately(atRate: self.rate); self.isPlaying = true }
            }
        }
    }
}
