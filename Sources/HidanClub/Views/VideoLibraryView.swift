import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct VideoLibraryView: View {
    @ObservedObject var library: VideoLibraryStore
    let video: VideoService
    @ObservedObject var captured: CapturedMotionStore
    @ObservedObject var published: CapturedLibraryStore
    let onRecord: () -> Void
    let onPractice: () -> Void
    let canPractice: Bool
    @State private var importing = false
    @State private var sendingClip = false
    @State private var clipMessage: String?
    @State private var previewVideoID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            if let error = library.errorMessage {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    Spacer()
                    Button { library.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("收起提示")
                }
            }
            if library.items.isEmpty {
                emptyLibrary
            } else {
                HStack(alignment: .top, spacing: 24) {
                    videoList.frame(width: 220)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if let selected = library.selected {
                                sourceCard(selected)
                                modelCard(selected)
                            } else {
                                ContentUnavailableView("选择一个视频", systemImage: "play.rectangle")
                            }
                        }.padding(.bottom, 24)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(28)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .video], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task { for url in urls { await library.importVideo(url: url) } }
            case .failure(let error): library.errorMessage = error.localizedDescription
            }
        }
        .onChange(of: library.selectedID, initial: true) { _, _ in synchronizeSelection() }
        .onChange(of: library.selected?.modelID) { _, _ in synchronizeModel() }
        .onChange(of: captured.saved.map(\.id)) { _, _ in synchronizeModel() }
        .onChange(of: captured.isLoading) { _, _ in synchronizeModel() }
        .onAppear { synchronizeSelection(forcePreview: true) }
        .onDisappear { video.pause(); captured.pause() }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                headerTitle.fixedSize(horizontal: true, vertical: false)
                Spacer()
                headerActions
            }
            VStack(alignment: .leading, spacing: 16) {
                headerTitle
                headerActions
            }
        }
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 7) {
            Eyebrow(text: "VIDEO LIBRARY")
            Text("视频库").font(.system(size: 30, weight: .bold))
            Text("收藏视频，在本页识别肢体。截出的一段可以收入动作库。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headerActions: some View {
        HStack(spacing: 12) {
            Button("录下练习", systemImage: "record.circle") { onRecord() }
            Button(library.isImporting ? "正在导入…" : "导入视频", systemImage: "plus") { importing = true }
                .buttonStyle(.borderedProminent)
        }.fixedSize()
    }

    private var emptyLibrary: some View {
        VStack(spacing: 20) {
            if library.isLoading { ProgressView("正在打开视频库") }
            else {
                ContentUnavailableView("从一段自己的舞蹈开始", systemImage: "play.rectangle.on.rectangle", description: Text("导入视频，或录下自己的练习。视频保存在这台 Mac，随时可回看。"))
                HStack {
                    Button("录下练习", systemImage: "record.circle") { onRecord() }
                    Button("选择视频", systemImage: "plus") { importing = true }.buttonStyle(.borderedProminent)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var videoList: some View {
        List(selection: Binding(get: { library.selectedID }, set: { library.select($0) })) {
            ForEach(library.items) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.source == .trainingRecording ? "record.circle" : "film").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.name).font(.callout.weight(.medium)).lineLimit(2)
                        Text("\(item.source.title) · \(clockText(item.duration))\(item.modelID == nil ? "" : " · 已识别")").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 5).tag(item.id)
            }
        }.listStyle(.sidebar)
    }

    private func sourceCard(_ item: LibraryVideo) -> some View {
        ClubCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Spacer()
                    Text(item.source.title).font(.caption).foregroundStyle(.secondary)
                }
                LibrarySourceVideoPreview(video: video, expectedURL: try? library.url(for: item))
                if library.isAnalyzing && library.analysisVideoID == item.id {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(library.analysisStatus ?? "正在识别").font(.callout.weight(.medium))
                            Spacer()
                            Text("\(Int(library.progress * 100))%").font(.caption.monospacedDigit())
                            Button("取消识别") { library.cancelAnalysis() }
                        }
                        ProgressView(value: library.progress)
                        Text("逐帧处理，保留完整动作。可以离开本页，完成后自动保存。").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) {
                            analysisPrompt(item).fixedSize(horizontal: true, vertical: false)
                            Spacer()
                            analysisButton(item)
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            analysisPrompt(item)
                            analysisButton(item)
                        }
                    }
                }
            }
        }
    }

    private func analysisPrompt(_ item: LibraryVideo) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.modelID == nil ? "识别会留在这条视频上" : "肢体已经附在这条视频上")
                .font(.callout.weight(.medium))
            Text("全身清晰的单人画面，识别效果更好。").font(.caption).foregroundStyle(.secondary)
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func analysisButton(_ item: LibraryVideo) -> some View {
        Button(item.modelID == nil ? "开始肢体识别" : "重新识别", systemImage: "figure.dance") {
            video.pause(); captured.pause(); library.analyzeSelected(captured: captured)
        }.buttonStyle(.borderedProminent).disabled(captured.isSaving || sendingClip).fixedSize()
    }

    @ViewBuilder private func modelCard(_ item: LibraryVideo) -> some View {
        if let modelID = item.modelID {
            if let model = captured.selected, model.id == modelID, captured.saved.contains(where: { $0.id == modelID }) {
                ClubCard {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("截进动作库").font(.headline)
                                Text("当前 A–B 会成为动作库里的一条动作。整段识别仍留在这条视频上。")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            HStack(spacing: 12) {
                                Button(sendingClip ? "正在收入…" : "收入动作库", systemImage: "square.stack") { saveClip() }
                                    .buttonStyle(.borderedProminent)
                                if let clipMessage { Text(clipMessage).font(.caption).foregroundStyle(.secondary) }
                            }
                        }.disabled(sendingClip || captured.isSaving || library.isAnalyzing || !model.hasPlayableMotion)
                        Divider()
                        CapturedMotionView(store: captured, onPractice: onPractice, canPractice: canPractice, allowsModelSelection: false)
                    }
                }
            } else if captured.isLoading {
                ProgressView("正在载入这段视频的动作模型").frame(maxWidth: .infinity).padding(28)
            } else if !library.isAnalyzing {
                ContentUnavailableView("动作模型暂时无法打开", systemImage: "figure.dance", description: Text("原视频仍可回看。请重新识别，或检查动作模型的保存位置。"))
            }
        }
    }

    private func synchronizeSelection(forcePreview: Bool = false) {
        guard let selected = library.selected else { video.pause(); previewVideoID = nil; clipMessage = nil; return }
        if forcePreview || previewVideoID != selected.id {
            do { video.load(url: try library.url(for: selected)); previewVideoID = selected.id }
            catch { library.errorMessage = error.localizedDescription }
        }
        synchronizeModel()
    }

    private func synchronizeModel() {
        guard let id = library.selected?.modelID, captured.selected?.id != id,
              let model = captured.saved.first(where: { $0.id == id }) else { return }
        captured.select(model)
    }

    private func saveClip() {
        guard let item = library.selected, let modelID = item.modelID,
              captured.selected?.id == modelID, !captured.isSaving, !sendingClip else { return }
        sendingClip = true
        clipMessage = nil
        let revision = captured.revision
        let range = captured.selectionA...captured.selectionB
        Task { @MainActor in
            defer { sendingClip = false }
            if captured.hasUnsavedChanges { await captured.saveSelected() }
            guard library.selectedID == item.id, library.selected?.modelID == modelID,
                  captured.selected?.id == modelID, captured.revision == revision,
                  !captured.hasUnsavedChanges,
                  let saved = captured.saved.first(where: { $0.id == modelID }), saved.hasPlayableMotion else { return }
            if await published.importModel(saved, to: .actions, range: range) != nil {
                clipMessage = "已收入动作库。"
            } else {
                library.errorMessage = published.errorMessage
            }
        }
    }
}

/// Keep the source player's frequent clock updates outside the library hierarchy.
private struct LibrarySourceVideoPreview: View {
    @ObservedObject var video: VideoService
    let expectedURL: URL?

    private var hasCurrentVideo: Bool {
        guard let expectedURL, let asset = video.player.currentItem?.asset as? AVURLAsset else { return false }
        return asset.url == expectedURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasCurrentVideo {
                NativeVideoPlayer(player: video.player)
                    .scaleEffect(x: video.mirrored ? -1 : 1, y: 1)
                    .frame(height: 270).clipShape(RoundedRectangle(cornerRadius: 16))
                HStack {
                    Button(action: video.toggle) { Label(video.isPlaying ? "暂停" : "播放视频", systemImage: video.isPlaying ? "pause.fill" : "play.fill") }
                    Text("\(clockText(video.currentTime)) / \(clockText(video.duration))").font(.caption.monospacedDigit())
                    Spacer()
                    Toggle("镜像", isOn: $video.mirrored).toggleStyle(.checkbox)
                    Picker("速度", selection: Binding(get: { video.rate }, set: video.setRate)) {
                        Text("0.25×").tag(Float(0.25)); Text("0.5×").tag(Float(0.5)); Text("0.75×").tag(Float(0.75)); Text("1×").tag(Float(1))
                    }.frame(width: 125)
                }
                Slider(value: Binding(get: { video.currentTime }, set: video.seek), in: 0...max(video.duration, 0.001))
            } else if video.errorMessage == nil {
                ProgressView("正在打开原视频").frame(maxWidth: .infinity).frame(height: 270)
            }
            if let error = video.errorMessage { Text(error).font(.callout).foregroundStyle(.red) }
        }
    }
}
