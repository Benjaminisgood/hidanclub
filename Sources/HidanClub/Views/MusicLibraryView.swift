import HidanCore
import SwiftUI
import UniformTypeIdentifiers

struct MusicLibraryView: View {
    @ObservedObject var music: MusicService
    @ObservedObject var library: MusicLibraryStore
    @State private var importing = false
    @State private var naming = false
    @State private var renaming: BeatPreset?
    @State private var draftName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                beats
                tracks
                if let error = library.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(4)
                }
            }
            .padding(ClubTheme.pageInset)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task {
                    let imported = await library.importTracks(urls: urls)
                    if let first = imported.first { play(first) }
                }
            case .failure(let error): library.errorMessage = error.localizedDescription
            }
        }
        .alert("存一套节拍", isPresented: $naming) {
            TextField("名称", text: $draftName)
            Button("保存") { saveNamedBeat() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("记住 \(Int(beatBPMToSave.rounded())) BPM。鼓点还是原来的八拍。")
        }
        .alert("给这套节拍改名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名称", text: $draftName)
            Button("保存") { commitRename() }
            Button("取消", role: .cancel) { renaming = nil }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: "MUSIC")
                Text("音乐库").font(.system(size: 28, weight: .bold))
                Text("选择一套原创节拍，或用喜欢的音乐开始练习。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("存一套节拍", systemImage: "metronome") {
                draftName = ""
                naming = true
            }
            .fixedSize()
            Button("导入音乐…", systemImage: "square.and.arrow.down") { importing = true }
                .buttonStyle(.borderedProminent)
                .fixedSize()
        }
    }

    private var beats: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("原创节拍").font(.headline)
            Text("每一套都是同一个八拍鼓点，只是速度不同。选中之后，播放器上的滑杆会把新速度写回去。")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
                ForEach(library.presets) { preset in
                    beatCard(preset)
                }
            }
        }
    }

    private var tracks: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本地音乐").font(.headline)
            Text("导入后保存在这台 Mac 上，并估计一个整体 BPM。动作用倍数去跟，不改音乐本身。")
                .font(.caption).foregroundStyle(.secondary)
            if library.tracks.isEmpty {
                ContentUnavailableView("还没有导入音乐", systemImage: "waveform", description: Text("可以一次选多首。文件按原样保存。"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
            } else {
                VStack(spacing: 8) {
                    ForEach(library.tracks) { track in
                        trackRow(track)
                    }
                }
            }
        }
    }

    private func beatCard(_ preset: BeatPreset) -> some View {
        let selected = music.tempoMode == .beat && library.selectedBeatID == preset.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "metronome").foregroundStyle(ClubTheme.accent)
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(ClubTheme.accent) }
            }
            Text(preset.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
            Text("\(Int(preset.bpm.rounded())) BPM · 8 拍").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            HStack {
                Button(selected ? "正在用" : "用这套") { play(preset) }
                    .disabled(selected && abs(music.bpm - preset.bpm) < 0.5)
                Spacer()
                Button { draftName = preset.name; renaming = preset } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).accessibilityLabel("改名").help("改名")
                Button { library.deleteBeat(preset.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).accessibilityLabel("删除这一套").help("删除这一套")
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? ClubTheme.accent.opacity(0.14) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(selected ? ClubTheme.accent.opacity(0.7) : Color.primary.opacity(0.06), lineWidth: 1))
    }

    private func trackRow(_ track: LibraryTrack) -> some View {
        let selected = music.trackID == track.id
        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(ClubTheme.accent.opacity(selected ? 0.22 : 0.10)).frame(width: 40, height: 40)
                Image(systemName: "waveform").foregroundStyle(ClubTheme.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(track.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(trackDetail(track)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(ClubTheme.accent) }
            Button(selected ? (music.isPlaying ? "正在播放" : "已选择") : "选择") { play(track) }
                .disabled(selected)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(selected ? ClubTheme.accent.opacity(0.10) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: ClubTheme.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: ClubTheme.cornerRadius).strokeBorder(selected ? ClubTheme.accent.opacity(0.55) : Color.primary.opacity(0.06), lineWidth: 1))
    }

    private func trackDetail(_ track: LibraryTrack) -> String {
        let minutes = Int(track.duration) / 60
        let seconds = Int(track.duration) % 60
        let length = String(format: "%d:%02d", minutes, seconds)
        if library.analyzing.contains(track.id), track.effectiveBPM == nil { return "\(length) · 正在识别节拍" }
        if let bpm = track.effectiveBPM {
            let origin = track.manualBPM != nil ? "手动" : "识别\(track.tempo?.level.label ?? "")"
            return "\(length) · \(origin) \(Int(bpm.rounded())) BPM"
        }
        return "\(length) · \(track.analysisFailure ?? "还没有节拍")"
    }

    private var beatBPMToSave: Double {
        if music.tempoMode == .music, let bpm = library.track(music.trackID)?.effectiveBPM {
            return MotionTempo.clampBeat(bpm)
        }
        return music.bpm
    }

    private func play(_ preset: BeatPreset) {
        let resume = music.isPlaying
        library.selectBeat(preset.id)
        music.useNamedBeat(name: preset.name, bpm: preset.bpm, resume: resume)
    }

    private func play(_ track: LibraryTrack) {
        let resume = music.isPlaying
        library.select(track.id)
        do {
            music.loadTrack(id: track.id, name: track.name, url: try library.url(for: track), bpm: track.effectiveBPM)
            if resume { music.play() }
        } catch { music.errorMessage = error.localizedDescription }
    }

    private func saveNamedBeat() {
        do {
            let preset = try library.addBeat(name: draftName, bpm: beatBPMToSave)
            music.useNamedBeat(name: preset.name, bpm: preset.bpm, resume: music.isPlaying)
        } catch { library.errorMessage = error.localizedDescription }
    }

    private func commitRename() {
        guard let preset = renaming else { return }
        do { try library.renameBeat(preset.id, to: draftName) }
        catch { library.errorMessage = error.localizedDescription }
        if library.selectedBeatID == preset.id, music.tempoMode == .beat {
            music.trackName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        renaming = nil
    }
}
