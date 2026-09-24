import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct VideoPracticeView: View {
    let video: VideoService
    @ObservedObject var analyzer: PoseAnalyzer
    @ObservedObject var store: CapturedMotionStore
    var onPractice: (() -> Void)? = nil
    var canPractice = true
    @State private var importing = false
    @State private var sourceAspectRatio = 1.0
    @State private var captureName = ""
    @State private var importToken = UUID()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow(text: "CAPTURE / 把舞蹈变成练习")
                        Text("上传一段舞，留下整套动作。").font(.system(size: 28, weight: .bold))
                        Text("看清原视频，再把想练的一段留在这台 Mac 上。").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("上传舞蹈视频", systemImage: "square.and.arrow.up") { importing = true }.buttonStyle(.borderedProminent)
                }
                ClubCard {
                    VStack(alignment: .leading, spacing: 14) {
                        SourceVideoPreviewCard(video: video)
                        if analyzer.isAnalyzing {
                            HStack {
                                ProgressView(value: analyzer.progress)
                                Text("逐帧捕捉 \(Int(analyzer.progress * 100))%").font(.caption.monospacedDigit())
                                Button("取消") { analyzer.cancel() }
                            }
                            Text("保留每一帧及其原始时间戳。完整视频的分析可能需要较长时间。").font(.caption).foregroundStyle(.secondary)
                        }
                        if let error = analyzer.errorMessage { Text(error).foregroundStyle(.red) }
                    }
                }
                ClubCard { CapturedMotionView(store: store, onPractice: onPractice, canPractice: canPractice) }
            }.padding(ClubTheme.pageInset)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .video]) { result in
            switch result {
            case .success(let url): importVideo(url)
            case .failure(let error): store.errorMessage = error.localizedDescription
            }
        }
        .onChange(of: analyzer.report?.createdAt, initial: true) { _, _ in
            guard let report = analyzer.report else { return }
            do { try store.acceptAnalysis(report) }
            catch { store.errorMessage = error.localizedDescription }
        }
    }

    private func importVideo(_ url: URL) {
        video.pause(); analyzer.cancel(); store.pause()
        let token = UUID(); importToken = token
        captureName = url.deletingPathExtension().lastPathComponent
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw PoseAnalysisError.noVideoTrack }
                let size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
                let oriented = size.applying(transform)
                let ratio = abs(oriented.width / oriented.height)
                guard ratio.isFinite, ratio > 0 else { throw PoseAnalysisError.unsupportedTransform }
                guard token == importToken else { return }
                sourceAspectRatio = ratio
                store.beginCapture(name: captureName, imageAspectRatio: ratio)
                video.load(url: url); analyzer.analyze(url: url)
            } catch { if token == importToken { store.errorMessage = error.localizedDescription } }
        }
    }
}

/// Source-video clock changes stay inside this card, so playing a reference does
/// not repeatedly recompute full-frame capture metrics and arrangement rows.
private struct SourceVideoPreviewCard: View {
    @ObservedObject var video: VideoService
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if video.name != nil {
                DisclosureGroup("原视频核对 · 镜像、慢放与 A–B 循环") {
                    CapturedSourceVideoView(video: video)
                }
            } else if video.errorMessage != nil {
                VideoPlaybackPlaceholder(message: video.errorMessage)
            } else {
                ContentUnavailableView("选择全身清晰的单人舞蹈视频", systemImage: "film", description: Text("MOV / MP4 · 视频和模型保留在这台 Mac · 不上传到服务器")).frame(height: 190)
            }
        }
    }
}

private struct CapturedSourceVideoView: View {
    @ObservedObject var video: VideoService
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VideoPlaybackPanel(video: video)
            Text(video.name ?? "").font(.caption).foregroundStyle(.secondary)
            Text("这里的慢放、镜像和 A–B 只用来核对原片，不改下面的动作。").font(.caption).foregroundStyle(.secondary)
        }.padding(.top, 12)
    }
}
