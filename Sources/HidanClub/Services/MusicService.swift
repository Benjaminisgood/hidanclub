import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Local audio stays on this Mac. The built-in beat is synthesized without external assets.
@MainActor final class MusicService: ObservableObject {
    @Published var bpm: Double = 90 {
        didSet {
            let normalized = bpm.isFinite ? min(180, max(40, bpm)) : 90
            if bpm != normalized { bpm = normalized; return }
            guard bpm != oldValue, sourceURL == nil else { return }
            let wasPlaying = isPlaying
            stop(); prepareBeat()
            if wasPlaying { play() }
        }
    }
    @Published var rate: Float = 1 { didSet { timePitch.rate = rate } }
    @Published var volume: Float = 0.35 { didSet { engine.mainMixerNode.outputVolume = volume } }
    @Published var isPlaying = false
    @Published var trackName = "Club beat · 原创节拍"
    @Published var errorMessage: String?
    @Published var sourceURL: URL?
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var beat: AVAudioPCMBuffer?
    private var file: AVAudioFile?
    private var hasScheduledAudio = false
    private let fileLoop = FileLoopScheduler()

    var isPaused: Bool { hasScheduledAudio && !isPlaying }

    var currentBeat: Int? {
        guard isPlaying, sourceURL == nil,
              let renderTime = player.lastRenderTime, let time = player.playerTime(forNodeTime: renderTime),
              time.sampleRate > 0 else { return nil }
        let seconds = Double(time.sampleTime) / time.sampleRate
        return max(0, Int(seconds / (60 / bpm))) % 8
    }

    init() {
        engine.attach(player); engine.attach(timePitch)
        engine.mainMixerNode.outputVolume = volume
        prepareBeat()
    }

    func useBeat() {
        stop(); file = nil; sourceURL = nil; rate = 1
        trackName = "Club beat · 原创节拍"; errorMessage = nil; prepareBeat()
    }

    func load(url: URL) {
        do {
            let audio = try AVAudioFile(forReading: url)
            guard audio.length > 0, audio.processingFormat.sampleRate > 0,
                  audio.processingFormat.channelCount > 0 else { throw CocoaError(.fileReadCorruptFile) }
            stop()
            configureGraph(format: audio.processingFormat)
            file = audio; sourceURL = url; trackName = url.deletingPathExtension().lastPathComponent
            rate = 1; errorMessage = nil
        } catch { errorMessage = "无法读取音频：\(error.localizedDescription)" }
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard !isPlaying else { return }
        do {
            if !engine.isRunning { try engine.start() }
            if !hasScheduledAudio {
                if let file { fileLoop.start(file: file, player: player) }
                else if let beat { player.scheduleBuffer(beat, at: nil, options: .loops) }
                else { engine.pause(); return }
                hasScheduledAudio = true
            }
            player.play(); isPlaying = true; errorMessage = nil
        } catch { errorMessage = "音频输出不可用：\(error.localizedDescription)" }
    }

    /// Preserve the player's timeline and queued audio for a later play()/resume().
    func pause() {
        guard isPlaying else { return }
        player.pause(); engine.pause(); isPlaying = false
    }

    func resume() { play() }

    /// Stop, source changes and tempo changes intentionally reset the timeline.
    func stop() {
        fileLoop.invalidate()
        player.stop(); engine.pause(); hasScheduledAudio = false; isPlaying = false
    }

    private func configureGraph(format: AVAudioFormat) {
        engine.stop()
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(timePitch)
        // PCM buffers must match the player format. The main mixer handles conversion
        // from this explicit source format to the current audio device's format.
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        timePitch.rate = rate
        engine.mainMixerNode.outputVolume = volume
    }

    private func prepareBeat() {
        let sr = 44100.0
        let secondsPerBeat = 60 / min(180, max(40, bpm))
        let length = AVAudioFrameCount(sr * secondsPerBeat * 8)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = length
        // Eight beats: a soft kick, snare and half-beat hi-hat; deterministic procedural sound.
        for i in 0..<Int(length) {
            let t = Double(i) / sr
            let phase = t.truncatingRemainder(dividingBy: secondsPerBeat)
            let beatIndex = Int(t / secondsPerBeat)
            let half = t.truncatingRemainder(dividingBy: secondsPerBeat / 2)
            let kick = sin(2 * .pi * (52 * phase + 3 * (1 - exp(-35 * phase)))) * exp(-phase * 22)
            let noise = sin(Double(i) * 173.13) * sin(Double(i) * 91.73)
            let snare = beatIndex % 2 == 1 ? noise * exp(-phase * 34) * 0.42 : 0
            let hat = noise * exp(-half * 110) * 0.12
            let value = Float((kick * 0.55 + snare + hat) * 0.65)
            channels[0][i] = value; channels[1][i] = value
        }
        beat = buffer
        configureGraph(format: format)
    }
}

/// Keep file segments queued ahead without decoding a whole song into a PCM buffer.
/// Scheduling has its own serial queue so UI work cannot delay a loop boundary.
private final class FileLoopScheduler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "club.hidan.audio-file-loop", qos: .userInitiated)
    private var activeToken: UUID?

    private final class Loop: @unchecked Sendable {
        let token = UUID()
        let file: AVAudioFile
        let player: AVAudioPlayerNode
        init(file: AVAudioFile, player: AVAudioPlayerNode) { self.file = file; self.player = player }
    }

    func start(file: AVAudioFile, player: AVAudioPlayerNode) {
        let loop = Loop(file: file, player: player)
        queue.sync {
            activeToken = loop.token
            // One current and one following iteration are queued before playback starts.
            enqueue(loop); enqueue(loop)
        }
    }

    func invalidate() {
        // Finish any in-flight scheduling before the owner calls player.stop().
        queue.sync { activeToken = nil }
    }

    private func enqueue(_ loop: Loop) {
        guard activeToken == loop.token else { return }
        loop.player.scheduleFile(loop.file, at: nil, completionCallbackType: .dataConsumed) { [weak self] _ in
            guard let self else { return }
            self.queue.async { [weak self] in self?.enqueue(loop) }
        }
    }
}
