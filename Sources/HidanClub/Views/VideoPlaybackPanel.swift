import SwiftUI

/// Shared by the video library and source comparison. AVKit owns the picture;
/// VideoService remains the only playback clock and A–B loop owner.
struct VideoPlaybackPanel: View {
    @ObservedObject var video: VideoService

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                NativeVideoPlayer(player: video.player)
                    .scaleEffect(x: video.mirrored ? -1 : 1, y: 1)
                if video.duration <= 0 {
                    VideoStageStatus(message: video.errorMessage)
                }
            }
            .aspectRatio(16.0 / 9, contentMode: .fit)
            .frame(minHeight: 220, maxHeight: 320)
            .frame(maxWidth: .infinity)
            .background(ClubTheme.stage)
            .overlay(alignment: .topLeading) {
                if video.duration > 0 {
                    HStack(spacing: 8) {
                        Label("原视频", systemImage: "film")
                        if video.mirrored { Text("镜像") }
                        if video.rate != 1 { Text(String(format: "%g×", video.rate)) }
                    }
                    .font(.caption.weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(12).allowsHitTesting(false)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                if video.duration > 0, let error = video.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                PlaybackTimeline(value: Binding(get: { video.currentTime }, set: video.seek),
                                 upperBound: video.duration, step: 0.01,
                                 elapsed: playbackTime(video.currentTime), total: playbackTime(video.duration),
                                 label: "原视频进度", detail: video.loopEnabled ? "A–B 循环" : nil)
                ControlFlow {
                    CircularPlayButton(playing: video.isPlaying, help: "播放或暂停原视频", action: video.toggle)
                        .disabled(video.duration <= 0)
                    PlayerToggle(title: "镜像", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", isOn: $video.mirrored)
                    Picker("速度", selection: Binding(get: { video.rate }, set: video.setRate)) {
                        Text("0.25×").tag(Float(0.25)); Text("0.5×").tag(Float(0.5))
                        Text("0.75×").tag(Float(0.75)); Text("1×").tag(Float(1))
                    }.frame(width: 132).disabled(video.duration <= 0)
                }
                Divider()
                ControlFlow {
                    PlayerToggle(title: "A–B 循环", symbol: "repeat", isOn: $video.loopEnabled)
                    Button("设 A · " + playbackTime(video.loopStart)) {
                        video.loopStart = min(video.currentTime, max(0, video.loopEnd - 0.25))
                    }.help("将当前位置设为循环起点")
                    Button("设 B · " + playbackTime(video.loopEnd)) {
                        video.loopEnd = max(video.currentTime, min(video.duration, video.loopStart + 0.25))
                    }.help("将当前位置设为循环终点")
                    Button("全段") { video.loopStart = 0; video.loopEnd = video.duration }
                }.disabled(video.duration < 0.25)
            }.padding(18)
        }
        .modifier(VideoPanelChrome())
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }
}

/// Same stage frame while the asset is opening, or when it cannot be opened.
struct VideoPlaybackPlaceholder: View {
    var message: String?

    var body: some View {
        VideoStageStatus(message: message)
            .aspectRatio(16.0 / 9, contentMode: .fit)
            .frame(minHeight: 220, maxHeight: 320)
            .frame(maxWidth: .infinity)
            .background(ClubTheme.stage)
            .modifier(VideoPanelChrome())
    }
}

private struct VideoStageStatus: View {
    var message: String?

    var body: some View {
        Group {
            if let message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(18)
            } else {
                ProgressView("正在打开原视频")
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct VideoPanelChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: ClubTheme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: ClubTheme.cornerRadius).strokeBorder(.primary.opacity(0.1)))
    }
}
