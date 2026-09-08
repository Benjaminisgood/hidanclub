import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct VideoPracticeView: View {
    @ObservedObject var video: VideoService
    @ObservedObject var analyzer: PoseAnalyzer
    @State private var importing = false
    @State private var analysisURL: URL?
    @State private var isAnalysisImport = false
    @State private var exportError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow(text: "VIDEO LAB / 视频练习")
                        Text("把一个动作，慢慢看清。").font(.system(size: 30, weight: .bold))
                        Text("导入本地示范，镜像、慢放与循环；再分析自己的练习视频。").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("导入示范", systemImage: "film") { isAnalysisImport = false; importing = true }
                        .buttonStyle(.borderedProminent)
                }
                ClubCard {
                    VStack(alignment: .leading, spacing: 16) {
                        if video.name != nil {
                            VideoPlayer(player: video.player)
                                .scaleEffect(x: video.mirrored ? -1 : 1, y: 1)
                                .frame(height: 360).clipShape(RoundedRectangle(cornerRadius: 14))
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 16).fill(.primary.opacity(0.04))
                                VStack(spacing: 15) {
                                    Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 46, weight: .ultraLight)).foregroundStyle(ClubTheme.accent)
                                    Text("你的第一段示范，从这里开始").font(.title3.weight(.semibold))
                                    Text("支持本地 MOV / MP4 · 不附带第三方教学视频").foregroundStyle(.secondary)
                                    Button("选择视频…") { isAnalysisImport = false; importing = true }
                                }
                            }.frame(height: 300)
                        }
                        HStack(spacing: 18) {
                            Button(action: video.toggle) { Label(video.isPlaying ? "暂停" : "播放", systemImage: video.isPlaying ? "pause.fill" : "play.fill") }
                                .disabled(video.name == nil)
                            Text(clockText(video.currentTime) + " / " + clockText(video.duration)).monospacedDigit().foregroundStyle(.secondary)
                            Spacer()
                            Toggle("镜像画面", isOn: $video.mirrored).toggleStyle(.switch).fixedSize()
                            Picker("速度", selection: Binding(get: { video.rate }, set: video.setRate)) {
                                Text("0.5×").tag(Float(0.5)); Text("0.75×").tag(Float(0.75)); Text("1×").tag(Float(1))
                            }.frame(width: 135)
                        }
                        if video.duration > 0 {
                            Slider(value: Binding(get: { video.currentTime }, set: video.seek), in: 0...max(video.duration, 1))
                            HStack {
                                Toggle("A–B 循环", isOn: $video.loopEnabled).toggleStyle(.checkbox)
                                Button("设 A：\(clockText(video.loopStart))") { video.loopStart = min(video.currentTime, max(0, video.loopEnd - 0.25)) }
                                Button("设 B：\(clockText(video.loopEnd))") { video.loopEnd = max(video.currentTime, min(video.duration, video.loopStart + 0.25)) }
                                Spacer()
                                Text(video.name ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        if let message = video.errorMessage { Text(message).foregroundStyle(.red) }
                    }
                }
                analysisCard
            }.padding(32)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .video]) { result in
            switch result {
            case .success(let url):
                if isAnalysisImport { analysisURL = url; analyzer.analyze(url: url) }
                else { video.load(url: url) }
            case .failure(let error): exportError = error.localizedDescription
            }
        }
        .alert("文件操作失败", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) { Button("好") {} } message: { Text(exportError ?? "") }
    }

    private var analysisCard: some View {
        ClubCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("动作观察室", systemImage: "figure.dance").font(.title2.weight(.semibold))
                    Spacer()
                    if analyzer.isAnalyzing {
                        Button("取消分析", role: .cancel) { analyzer.cancel() }
                    } else {
                        Button("分析练习视频…") { isAnalysisImport = true; importing = true }
                    }
                }
                Text("在这台 Mac 上识别身体关键点，保留每一帧及其时间戳。适合观察身体轨迹，暂不识别舞步名称或给舞蹈质量打分。")
                    .foregroundStyle(.secondary)
                if analyzer.isAnalyzing {
                    ProgressView(value: analyzer.progress)
                    Text("正在逐帧分析 · \(Int(analyzer.progress * 100))%　长视频可能需要较长时间").font(.caption).foregroundStyle(.secondary)
                }
                if let report = analyzer.report {
                    HStack(spacing: 36) {
                        metric("解码帧数", "\(report.decodedFrameCount)")
                        metric("检测到单人", "\(report.detectedFrameCount)")
                        metric("检测覆盖率", String(format: "%.1f%%", report.coverage * 100))
                        Spacer()
                        Button("导出骨架 JSON", systemImage: "square.and.arrow.up") { export() }
                    }
                    Text(report.sourceName).font(.caption).foregroundStyle(.secondary)
                    PoseReviewView(report: report)
                    Text("检测覆盖率表示可用关键点的覆盖情况，不代表舞蹈水平。多人、遮挡、脚部出画或快速转身会影响检测。").font(.caption).foregroundStyle(.secondary)
                }
                if let error = analyzer.errorMessage { Text(error).foregroundStyle(.red) }
            }
        }
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)); Text(title).font(.caption).foregroundStyle(.secondary) }
    }
    private func export() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "dance-pose.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try analyzer.export(to: url) } catch { exportError = error.localizedDescription }
    }
}
