// HidanClub MusicService runtime QA probe (macOS, active audio output required).
// Default output is silent: mainMixerNode volume is set to zero before playback.
// The probe reads a pre-mixer tap and examines every sample in each delivered buffer.
// It checks position-preserving pause/resume, BPM changes, format switches and looping.
// No empty buffer after the first signal is a buffer-level check; it does not establish
// sample-perfect splices or gapless playback for every compressed audio codec.
//
// Reproduce from the repository root without building the app:
//   hidan_music_qa_dir="$(mktemp -d)"
//   cat Sources/HidanClub/Services/MusicService.swift script/qa_music_probe.swift > "$hidan_music_qa_dir/MusicProbe.swift"
//   swiftc -parse-as-library -swift-version 5 "$hidan_music_qa_dir/MusicProbe.swift" -o "$hidan_music_qa_dir/music-probe"
//   "$hidan_music_qa_dir/music-probe"
//   rm "$hidan_music_qa_dir/MusicProbe.swift" "$hidan_music_qa_dir/music-probe"
//   rmdir "$hidan_music_qa_dir"
//
// Concatenation is deliberate: the probe extension accesses private audio nodes in the
// same Swift file, exercising the current implementation without shipping test APIs.
// Temporary WAV fixtures are generated locally and removed by the probe.

private final class SignalProbe: @unchecked Sendable {
    let lock = NSLock()
    var nonzero = 0
    var zeroAfterSignal = 0
    func accept(_ buffer: AVAudioPCMBuffer) {
        guard let p = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var peak: Float = 0
        for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(p[i])) }
        lock.lock(); defer { lock.unlock() }
        if peak > 0.0001 { nonzero += 1 }
        else if nonzero > 0 { zeroAfterSignal += 1 }
    }
    var values: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (nonzero, zeroAfterSignal) }
}

extension MusicService {
    fileprivate var sourceTime: Double {
        guard let render = player.lastRenderTime, let time = player.playerTime(forNodeTime: render) else { return 0 }
        return Double(time.sampleTime) / time.sampleRate
    }
    fileprivate var sourceFormat: AVAudioFormat { player.outputFormat(forBus: 0) }
    fileprivate func installProbe(_ probe: SignalProbe) {
        timePitch.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in probe.accept(buffer) }
    }
    fileprivate func removeProbe() { timePitch.removeTap(onBus: 0) }
}

@main struct MusicChecks {
    @MainActor static func main() async throws {
        func wait(_ seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw NSError(domain: message, code: 1) }
        }
        let music = MusicService()
        music.volume = 0
        try check(music.sourceFormat.sampleRate == 44100 && music.sourceFormat.channelCount == 2, "beat format mismatch")
        music.play(); try await wait(0.9)
        try check(music.isPlaying && music.errorMessage == nil, "beat did not play")
        music.pause()
        let pausedAt = music.sourceTime
        try await wait(0.15)
        try check(music.isPaused && abs(music.sourceTime - pausedAt) < 0.03, "pause did not freeze timeline")
        music.resume(); try await wait(0.15)
        try check(music.sourceTime > pausedAt && music.sourceTime > 0.8, "resume restarted audio")
        music.bpm = 120
        try check(music.isPlaying && music.bpm == 120, "BPM change stopped playback")
        music.bpm = -1
        try check(music.bpm == 40 && music.isPlaying, "BPM lower-bound normalization failed")
        music.bpm = .nan
        try check(music.bpm == 90 && music.isPlaying, "BPM non-finite normalization failed")
        music.stop()
        try check(!music.isPlaying && !music.isPaused, "stop did not reset state")
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hidan-music-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (sampleRate, channels) in [(44100.0, AVAudioChannelCount(1)), (48000.0, AVAudioChannelCount(2))] {
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
            let count = AVAudioFrameCount(sampleRate * 0.22)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
            buffer.frameLength = count
            for channel in 0..<Int(channels) {
                for index in 0..<Int(count) { buffer.floatChannelData![channel][index] = Float(sin(Double(index) / sampleRate * 2 * .pi * 300)) * 0.1 }
            }
            let url = directory.appendingPathComponent("test-\(Int(sampleRate))-\(channels).wav")
            do { let output = try AVAudioFile(forWriting: url, settings: format.settings); try output.write(from: buffer) }
            music.load(url: url)
            try check(music.errorMessage == nil && music.sourceURL == url, "file load failed")
            try check(music.sourceFormat.sampleRate == sampleRate && music.sourceFormat.channelCount == channels, "source format was not updated")
            let probe = SignalProbe(); music.installProbe(probe)
            music.play(); try await wait(1.25)
            try check(music.isPlaying && music.sourceTime > 1, "file loop stopped")
            let (nonzero, gaps) = probe.values
            music.pause()
            let filePausedAt = music.sourceTime
            try await wait(0.1)
            music.resume(); try await wait(0.1)
            try check(music.sourceTime > filePausedAt, "file resume lost progress")
            music.removeProbe(); music.stop()
            FileHandle.standardOutput.write(Data("PROBE \(Int(sampleRate)) nonzero=\(nonzero) empty=\(gaps)\n".utf8))
            try check(nonzero > 3 && gaps == 0, "file loop produced empty audio buffers")
            print("file loop \(Int(sampleRate)) Hz / \(channels) ch: \(nonzero) signal buffers, \(gaps) empty buffers after signal")
        }
        music.useBeat(); music.play(); try await wait(0.1)
        try check(music.errorMessage == nil && music.isPlaying && music.sourceFormat.sampleRate == 44100, "switch back to beat failed")
        music.stop()
        let trackURL = directory.appendingPathComponent("test-44100-1.wav")
        let trackID = UUID()
        music.loadTrack(id: trackID, name: "Probe track", url: trackURL, bpm: 100)
        try check(music.tempoMode == .music && music.trackID == trackID && music.trackName == "Probe track" && music.trackBPM == 100, "library track did not keep its tempo")
        music.beatMultiplier = .double
        music.rate = 0.75
        try check(music.motionBeatBPM == 150, "motion tempo is not track BPM × rate × multiple")
        music.beatMultiplier = .half
        try check(music.motionBeatBPM == 37.5, "half-time multiple did not halve the motion tempo")
        music.load(url: trackURL)
        try check(music.trackID == nil && music.trackBPM == nil && music.motionBeatBPM == nil, "a file without a library record kept a tempo")
        music.useBeat()
        try check(music.tempoMode == .beat && music.motionBeatBPM == music.bpm && music.trackID == nil, "beat mode did not clear the track")
        music.bpm = 200
        try check(music.bpm == 180, "beat upper bound changed")
        print("PASS: silent beat/file playback, pause/resume position, live BPM, stop/reset, format switches, repeated file loops, and music-mode tempo multiples")
    }
}
