import HidanCore
import SwiftUI

struct CircularPlayButton: View {
    var playing: Bool
    var help: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 24, height: 24)
        }
        .buttonStyle(.borderedProminent)
        .clipShape(Circle())
        .help(help)
    }
}

struct MusicBar: View {
    @ObservedObject var music: MusicService
    @ObservedObject var library: MusicLibraryStore
    /// During practice this one button starts and stops the reference motion together with the music.
    var onPlayToggle: (() -> Void)? = nil
    /// BPM the motion on screen was recorded at, so the caption can say when 0.25–2× cannot reach the music.
    var motionBPM: Double? = nil
    var onOpenLibrary: () -> Void = {}
    @State private var bpmDraft = ""
    @FocusState private var bpmFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            if music.tempoMode == .beat {
                ViewThatFits(in: .horizontal) { beatWide; beatCompact }
            } else {
                ViewThatFits(in: .horizontal) { musicWide; musicCompact }
            }
            if let message = music.errorMessage ?? library.errorMessage {
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(music.tempoMode == .beat ? ClubTheme.lime.opacity(0.16) : ClubTheme.accent.opacity(0.12))
        .overlay(alignment: .top) {
            Rectangle().fill(music.tempoMode == .beat ? ClubTheme.lime : ClubTheme.accent).frame(height: 2)
        }
        .onAppear { restoreSavedTrack(); syncDraft() }
        .onChange(of: library.isLoading) { _, _ in restoreSavedTrack(); syncDraft() }
        .onChange(of: library.tracks) { _, _ in adoptLibraryTempo(); syncDraft() }
        .onChange(of: music.trackBPM) { _, _ in syncDraft() }
    }

    private var beatWide: some View {
        HStack(spacing: 14) {
            beatIdentity
            beatPlay
            beatTempo
            Spacer(minLength: 8)
            volumeControl
            libraryButton
        }
    }

    private var beatCompact: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                beatIdentity
                Spacer(minLength: 8)
                beatPlay
                volumeControl
                libraryButton
            }
            beatTempo
        }
    }

    private var musicWide: some View {
        HStack(spacing: 14) {
            musicIdentity
            musicPlay
            musicTempo
            Spacer(minLength: 8)
            volumeControl
            libraryButton
            sourceMenu
        }
    }

    private var musicCompact: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                musicIdentity
                Spacer(minLength: 8)
                musicPlay
                volumeControl
                libraryButton
                sourceMenu
            }
            musicTempo
        }
    }

    private var beatIdentity: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(ClubTheme.lime.opacity(0.22)).frame(width: 44, height: 44)
                Image(systemName: "metronome").foregroundStyle(ClubTheme.lime).font(.title3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("原创节拍").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.2).foregroundStyle(ClubTheme.lime)
                Text(library.selectedBeat?.name ?? "自由速度").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(beatCaption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(minWidth: 120, idealWidth: 180, maxWidth: 220, alignment: .leading)
        }
    }

    private var musicIdentity: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(ClubTheme.accent.opacity(0.18)).frame(width: 44, height: 44)
                Image(systemName: "waveform").foregroundStyle(ClubTheme.accent).font(.title3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("本地音乐").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.2).foregroundStyle(ClubTheme.accent)
                Text(music.trackName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(musicCaption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(minWidth: 120, idealWidth: 190, maxWidth: 240, alignment: .leading)
        }
    }

    private var beatPlay: some View {
        CircularPlayButton(playing: music.isPlaying, help: onPlayToggle == nil ? "播放或暂停原创节拍" : "播放或暂停动作和节拍", action: onPlayToggle ?? music.toggle)
            .tint(ClubTheme.lime)
    }

    private var musicPlay: some View {
        CircularPlayButton(playing: music.isPlaying, help: onPlayToggle == nil ? "播放或暂停音乐" : "播放或暂停动作和音乐", action: onPlayToggle ?? music.toggle)
            .tint(ClubTheme.accent)
    }

    private var beatTempo: some View {
        HStack(spacing: 10) {
            Text("\(Int(music.bpm.rounded()))").font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                .frame(width: 64, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text("BPM").font(.caption2.weight(.semibold)).foregroundStyle(ClubTheme.lime)
                Slider(value: Binding(get: { music.bpm }, set: { music.bpm = $0; library.rememberBeatTempo($0) }), in: MotionTempo.beatRange, step: 1)
                    .frame(minWidth: 110, maxWidth: 180)
                    .tint(ClubTheme.lime)
                    .accessibilityLabel("原创节拍 BPM")
            }
        }
    }

    private var musicTempo: some View {
        HStack(spacing: 10) {
            Picker("动作倍数", selection: Binding(get: { music.beatMultiplier }, set: { setMultiplier($0) })) {
                ForEach(BeatMultiplier.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 168)
            .controlSize(.small)
            .tint(ClubTheme.accent)
            .help("动作相对音乐节拍的倍数：\(music.beatMultiplier.summary)。音乐本身的速度不变。")
            .accessibilityIdentifier("music.multiplier")
            Text(music.beatMultiplier.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            TextField("BPM", text: bpmField)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospacedDigit())
                .frame(width: 52)
                .focused($bpmFocused)
                .onSubmit { commitBPM() }
                .onChange(of: bpmFocused) { _, focused in if !focused { commitBPM() } }
                .help("识别出的节拍。不对就改成听到的 BPM，30 到 300。")
                .accessibilityIdentifier("music.bpm")
            Text("BPM").font(.caption).foregroundStyle(.secondary)
            if let motion = music.motionBeatBPM {
                Text("动作 \(Int(motion.rounded()))").font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            Picker("播放", selection: $music.rate) {
                Text("0.75×").tag(Float(0.75)); Text("1×").tag(Float(1)); Text("1.25×").tag(Float(1.25))
            }
            .frame(width: 108)
            .help("音乐播放速度，保持音调。动作节拍按同样比例变化。")
        }
    }

    private var libraryButton: some View {
        Button(action: onOpenLibrary) {
            Image(systemName: "music.note.list")
        }
        .buttonStyle(.borderless)
        .help("打开音乐库")
        .accessibilityIdentifier("music.openLibrary")
    }

    private var volumeControl: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
            Slider(value: $music.volume, in: 0...1).frame(width: 76).help("音量")
        }
    }

    private var sourceMenu: some View {
        Menu {
            if let id = music.trackID {
                Button("重新识别节拍") { reanalyze(id) }
                if library.track(id)?.manualBPM != nil, library.track(id)?.tempo != nil {
                    Button("改用识别结果") { clearManual(id) }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 28)
        .help("重新识别，或改回识别结果")
        .disabled(music.trackID == nil)
    }

    private var beatCaption: String {
        let memory = library.selectedBeat == nil ? "还没存成一套" : "滑杆会记住这一套的速度"
        if onPlayToggle != nil { return "8 拍循环 · 与练习同一节拍" }
        return "8 拍循环 · \(memory)"
    }

    private var musicCaption: String {
        guard let id = music.trackID, let track = library.track(id) else { return "从音乐库选择一首" }
        if library.analyzing.contains(id), track.effectiveBPM == nil { return "正在识别节拍" }
        guard track.effectiveBPM != nil else {
            return track.analysisFailure ?? "未识别到节拍，可填写 BPM"
        }
        var text = track.manualBPM != nil ? "手动节拍" : "置信度\(track.tempo?.level.label ?? "")"
        if let motionBPM, let motion = music.motionBeatBPM, !MotionTempo.canReach(motionBPM: motionBPM, targetBPM: motion) {
            text += " · 已到速度上限"
        }
        if library.analyzing.contains(id) { text += " · 正在重新识别" }
        return text
    }

    private var bpmField: Binding<String> {
        Binding(get: {
            if bpmFocused || !bpmDraft.isEmpty { return bpmDraft }
            return music.trackBPM.map { String(Int($0.rounded())) } ?? ""
        }, set: { bpmDraft = $0 })
    }

    private func syncDraft() {
        guard !bpmFocused else { return }
        let shown = music.trackBPM.map { String(Int($0.rounded())) } ?? ""
        if bpmDraft != shown { bpmDraft = shown }
    }

    private func restoreSavedTrack() {
        guard let saved = library.consumeSavedSelection() else { return }
        music.beatMultiplier = saved.multiplier
        if let track = saved.track {
            use(track, resume: false)
        } else if let beat = saved.beat {
            library.selectBeat(beat.id)
            music.useNamedBeat(name: beat.name, bpm: beat.bpm, resume: false)
        }
    }

    private func adoptLibraryTempo() {
        guard let id = music.trackID, let track = library.track(id) else { return }
        if music.trackBPM != track.effectiveBPM { music.trackBPM = track.effectiveBPM }
        if music.trackName != track.name { music.trackName = track.name }
    }

    private func use(_ track: LibraryTrack, resume: Bool) {
        library.select(track.id)
        do {
            music.loadTrack(id: track.id, name: track.name, url: try library.url(for: track), bpm: track.effectiveBPM)
            if resume { music.play() }
        } catch {
            music.errorMessage = error.localizedDescription
        }
    }

    private func setMultiplier(_ value: BeatMultiplier) {
        music.beatMultiplier = value
        library.setMultiplier(value)
    }

    private func commitBPM() {
        guard music.tempoMode == .music, let id = music.trackID else { return }
        let trimmed = bpmDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard let bpm = Double(trimmed.replacingOccurrences(of: ",", with: ".")), MotionTempo.isValidTrackBPM(bpm) else {
            music.errorMessage = MusicLibraryError.invalidBPM.localizedDescription
            bpmDraft = music.trackBPM.map { String(Int($0.rounded())) } ?? ""
            return
        }
        let rounded = (bpm * 10).rounded() / 10
        if let current = music.trackBPM, abs(current - rounded) < 0.51 { return }
        do {
            try library.setManualBPM(id, bpm: rounded)
            music.trackBPM = rounded
            music.errorMessage = nil
            bpmDraft = String(Int(rounded.rounded()))
        } catch {
            music.errorMessage = error.localizedDescription
        }
    }

    private func reanalyze(_ id: UUID) {
        try? library.setManualBPM(id, bpm: nil)
        music.trackBPM = library.track(id)?.tempo?.bpm
        library.reanalyze(id)
    }

    private func clearManual(_ id: UUID) {
        guard let tempo = library.track(id)?.tempo?.bpm else { return }
        do {
            try library.setManualBPM(id, bpm: nil)
            music.trackBPM = tempo
            music.errorMessage = nil
        } catch {
            music.errorMessage = error.localizedDescription
        }
    }
}
