import SwiftUI
import UniformTypeIdentifiers

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
    /// During practice this one button starts and stops the reference motion together with the music.
    var onPlayToggle: (() -> Void)? = nil
    @State private var importing = false
    private var musicCaption: String {
        if onPlayToggle != nil, music.sourceURL == nil { return "与练习同一节拍 · \(Int(music.bpm)) BPM" }
        if music.sourceURL == nil { return "8 拍循环 · \(Int(music.bpm)) BPM" }
        return onPlayToggle == nil ? "本地音频 · 保持音调变速" : "与练习同一速度"
    }
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(ClubTheme.accent.opacity(0.12)).frame(width: 44, height: 44)
                    Image(systemName: "waveform").foregroundStyle(ClubTheme.accent).font(.title3)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(music.trackName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(musicCaption).font(.caption2).foregroundStyle(.secondary)
                }.frame(width: 195, alignment: .leading)
                CircularPlayButton(playing: music.isPlaying, help: onPlayToggle == nil ? "播放或暂停音乐" : "播放或暂停动作和音乐", action: onPlayToggle ?? music.toggle)
                if music.sourceURL == nil {
                    Slider(value: $music.bpm, in: 40...180, step: 1).frame(minWidth: 80, maxWidth: 145)
                    Text("\(Int(music.bpm)) BPM").font(.caption.monospacedDigit()).frame(width: 64)
                } else {
                    Picker("速度", selection: $music.rate) {
                        Text("0.75×").tag(Float(0.75)); Text("1×").tag(Float(1)); Text("1.25×").tag(Float(1.25))
                    }.frame(width: 125)
                }
                Spacer(minLength: 4)
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                Slider(value: $music.volume, in: 0...1).frame(width: 76).help("音量")
                Menu {
                    Button("导入本地音乐…") { importing = true }
                    Button("使用原创节拍") { music.useBeat() }
                } label: { Image(systemName: "music.note.list") }.menuStyle(.borderlessButton).frame(width: 30)
            }
            if let message = music.errorMessage { Text(message).font(.caption).foregroundStyle(.red) }
        }.padding(.horizontal, 24).padding(.vertical, 14).background(.bar)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url): music.load(url: url)
            case .failure(let error): music.errorMessage = error.localizedDescription
            }
        }
    }
}
