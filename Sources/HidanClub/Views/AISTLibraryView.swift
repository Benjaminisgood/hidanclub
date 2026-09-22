import SwiftUI
import HidanCore
import AppKit

struct AISTLibraryFilters {
    var search = ""
    var genre = "all"
    var category = "all"
}

struct AISTLibraryView: View {
    @ObservedObject var store: AISTLibraryStore
    @ObservedObject var training: TrainingStore
    @ObservedObject var music: MusicService
    @ObservedObject var arrangements: AISTArrangementStore
    @ObservedObject var clips: CapturedLibraryStore
    @Binding var filters: AISTLibraryFilters
    @Binding var showDetail: Bool
    var openTraining: () -> Void
    var offerMusicPractice: ((() -> Void)?) -> Void = { _ in }
    var practiceClip: (CapturedMotion) -> Void
    var canPracticeClip: Bool
    @AppStorage(CoordinateLayerPreference.key) private var coordinateLayer = "optimized"
    @AppStorage("training.defaultRounds") private var defaultRounds = 4
    @State private var results: [AISTSequence] = []
    @State private var showDataInfo = false
    @State private var message: String?
    @State private var exportURL: URL?
    @State private var showStylePlan = false
    @State private var openedClipID: UUID?
    @State private var importNotice: String?
    @State private var planStyle: DanceStyle = .hipHop
    @State private var planMinutes = 20
    @State private var planLevel = 1
    @AppStorage("aist.visualStyle") private var visualStyle: AISTVisualStyle = .porcelain
    @AppStorage("aist.skeletonOverlay") private var skeletonOverlay = false
    @AppStorage("aist.showReferenceGrid") private var showReferenceGrid = false
    @AppStorage("aist.showJointNames") private var showJointNames = false

    var body: some View {
        Group {
            if let clip = openedClip { clipDetail(clip) }
            else if showDetail { detail }
            else { gallery }
        }
        .onAppear { filter(); publishMusicPractice() }
        .onChange(of: filters.search) { _, _ in filter() }
        .onChange(of: filters.genre) { _, _ in filter() }
        .onChange(of: filters.category) { _, _ in filter() }
        .onChange(of: store.favorites) { _, _ in filter() }
        .onChange(of: store.manifest?.sourceSHA256) { _, _ in filter() }
        .onChange(of: coordinateLayer) { _, _ in
            guard showDetail, store.selected != nil else { return }
            store.optimized = coordinateLayer != "raw"
            store.switchSource()
        }
        .onChange(of: showDetail) { _, open in
            if !open { store.pause() }
            publishMusicPractice()
        }
        .onChange(of: store.loading) { _, _ in publishMusicPractice() }
        .onChange(of: store.motion == nil) { _, _ in publishMusicPractice() }
        .onChange(of: store.speed) { _, speed in
            guard music.sourceURL == nil, let bpm = store.selected?.bpm else { return }
            let locked = min(180, max(40, Double(bpm) * speed))
            if abs(music.bpm - locked) > 0.51 { music.bpm = locked }
        }
        .onDisappear { store.pause(); offerMusicPractice(nil) }
        .sheet(isPresented: $showDataInfo) { dataInfo }
        .sheet(isPresented: $showStylePlan) { stylePlan }
    }

    private var gallery: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("动作库").font(.system(size: 28, weight: .bold))
                    Text("列表用原始逐帧重建自动播放。点开或练习时默认用官方时序优化，可在设置里更换。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                LibraryImportButton(title: "导入 JSON…", destination: .actions, store: clips, notice: $importNotice) { results in
                    // Reveal what was just published instead of leaving it hidden
                    // behind a category that does not list 我的动作.
                    if results.contains(where: \.succeeded), !showsMine { filters.category = "mine" }
                }
                .help("从动作模型 JSON 文件导入到「我的动作」")
                Button("风格练习…") {
                    planStyle = training.style; planMinutes = training.minutes; planLevel = training.level
                    showStylePlan = true
                }.disabled(training.active)
            }
            filterBar
            LibraryImportStatus(store: clips, notice: importNotice)
            if showsMine, !visibleClips.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("我的").font(.headline)
                        Text("视频截取或从 JSON 导入 · \(visibleClips.count) 条")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                        ForEach(visibleClips) { model in clipCard(model) }
                    }
                }
            } else if showsMine, clips.isLoading {
                ProgressView("正在读取截出的动作")
            }
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("选择数据文件夹") { store.chooseDirectory() }
            }
            if filters.category == "mine" && visibleClips.isEmpty && !clips.isLoading {
                ContentUnavailableView("我的动作还是空的", systemImage: "person.crop.rectangle", description: Text("在视频库里截出一段，或用「导入 JSON…」导入动作模型文件，就会出现在这里。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filters.category != "mine" && store.manifest == nil && store.loading {
                ProgressView("正在读取动作库…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filters.category != "mine" && store.manifest == nil {
                ContentUnavailableView("接入本地 AIST++ 动作库", systemImage: "figure.dance", description: Text("完成项目中的 script/aist_dataset.py 安装后，选择包含 manifest.json 的文件夹。"))
                Button("选择数据文件夹") { store.chooseDirectory() }
                Spacer()
            } else if filters.category != "mine" {
                if results.isEmpty {
                    ContentUnavailableView.search(text: filters.search)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    AISTGalleryGrid(directory: store.directory, reloadToken: store.manifest?.sourceSHA256 ?? "",
                                    sequences: results, name: store.name(for:),
                                    isFavorite: { store.favorites.contains($0.id) },
                                    toggleFavorite: { store.toggleFavorite($0.id) },
                                    open: open)
                        .accessibilityIdentifier("aist.gallery")
                }
            }
        }.padding(.horizontal, 26).padding(.vertical, 20)
        }
    }

    private var showsMine: Bool { filters.category == "all" || filters.category == "mine" }
    private var visibleClips: [CapturedMotion] {
        let query = filters.search.trimmingCharacters(in: .whitespacesAndNewlines)
        return clips.actions.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            TextField("搜索动作、舞者或音乐编号", text: $filters.search).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("aist.search")
            Picker("舞种", selection: $filters.genre) {
                Text("全部舞种").tag("all")
                ForEach(genres, id: \.0) { item in Text(item.1).tag(item.0) }
            }.frame(width: 150)
            Picker("分类", selection: $filters.category) {
                Text("全部").tag("all")
                Text("收藏").tag("favorite")
                Text("基础").tag("basic")
                Text("进阶").tag("advanced")
                Text("我的").tag("mine")
            }.frame(width: 120)
            Text(filters.category == "mine" ? "\(visibleClips.count)" : "\(results.count)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func open(_ sequence: AISTSequence) {
        store.optimized = coordinateLayer != "raw"
        store.select(sequence)
        message = nil
        openedClipID = nil
        showDetail = true
    }

    private var openedClip: CapturedMotion? {
        clips.actions.first { $0.id == openedClipID }
    }

    private func clipCard(_ model: CapturedMotion) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ClippedPoseThumbnail(model: model)
                .frame(height: 188)
                .frame(maxWidth: .infinity)
                .clipped()
            VStack(alignment: .leading, spacing: 5) {
                Text(model.name).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                Text("视频截取 · \(String(format: "%.1f", model.segments.first.map { model.duration(of: $0) } ?? 0)) 秒")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.07)))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture {
            store.pause()
            showDetail = false
            openedClipID = model.id
        }
        .accessibilityLabel(model.name)
        .accessibilityAddTraits(.isButton)
    }

    private func clipDetail(_ model: CapturedMotion) -> some View {
        ClippedMotionDetail(model: model, onBack: { openedClipID = nil }, onPractice: { practiceClip(model) }, canPractice: canPracticeClip)
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if let selected = store.selected {
                    sequenceHeader(selected)
                    AISTPlaybackObserver(playback: store.playback) {
                        VStack(spacing: 8) {
                            stage(selected)
                            transport(selected)
                        }
                    }
                } else if store.loading {
                    ProgressView("正在读取动作…").frame(maxWidth: .infinity, minHeight: 380)
                } else {
                    ContentUnavailableView("这个动作暂时打不开", systemImage: "figure.dance", description: Text("返回列表再选一次，或在设置里重新读取动作库。"))
                    Button("全部动作") { showDetail = false }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                if let exportURL { Button("查看已导出的片段") { NSWorkspace.shared.open(exportURL) } }
            }.padding(24)
        }
    }

    private func sequenceHeader(_ sequence: AISTSequence) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button { showDetail = false } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("全部动作")
                Text(store.name(for: sequence)).font(.title3.weight(.semibold)).lineLimit(1).textSelection(.enabled)
                Text("\(sequence.genreName) · \(sequence.category) · \(sequence.dancerID)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(sequence.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).textSelection(.enabled).layoutPriority(-1)
                Spacer(minLength: 8)
                Button { store.toggleFavorite(sequence.id) } label: {
                    Image(systemName: store.favorites.contains(sequence.id) ? "star.fill" : "star")
                }.help("收藏动作")
                Button("来源说明") { showDataInfo = true }
            }.controlSize(.small)
            if sequence.ignored {
                Label("官方标记此序列重建质量较低；所有帧仍保留。", systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    private func stage(_ sequence: AISTSequence) -> some View {
        MotionStageChrome(
            joints: store.currentJoints, upAxis: store.upAxis, mirrored: store.mirrored,
            resetToken: store.resetCamera, loading: store.loading,
            identity: sequence.id + store.upAxis + String(store.optimized),
            visualStyle: visualStyle, showJointNames: showJointNames,
            showSkeletonOverlay: skeletonOverlay, showReferenceGrid: showReferenceGrid)
    }

    private func transport(_ sequence: AISTSequence) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(format: "%.2f / %.2f 秒", Double(store.frameIndex) / sequence.fps, sequence.duration)).monospacedDigit()
                Spacer(minLength: 8)
                Text("帧 \(store.frameIndex + 1) / \(sequence.frameCount)").monospacedDigit()
            }.font(.caption2).foregroundStyle(.secondary)
            Slider(value: Binding(get: { Double(store.frameIndex) }, set: { store.pause(); store.seek(Int($0)) }),
                   in: 0...Double(max(1, sequence.frameCount - 1)), step: 1).controlSize(.small).accessibilityLabel("动作帧")
            HStack(spacing: 6) {
                Button { store.toggle() } label: {
                    Label(store.isPlaying ? "暂停预览" : "动作预览", systemImage: store.isPlaying ? "pause.fill" : "play.fill")
                }.disabled(store.motion == nil).accessibilityIdentifier("aist.stage.play")
                Button("镜像") { store.mirrored.toggle() }
                Button("重置视角", systemImage: "arrow.counterclockwise") { store.resetCamera += 1 }
                Button { store.step(-1) } label: { Image(systemName: "backward.frame") }.help("上一帧")
                Button { store.step(1) } label: { Image(systemName: "forward.frame") }.help("下一帧")
                Picker("速度", selection: $store.speed) {
                    ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                }.frame(width: 72).help("动作节拍速度。已导入的音乐仍按自己的播放速度。")
            }
            .controlSize(.small)
            .font(.caption)
            HStack(spacing: 6) {
                Button("设 A") { store.setA() }
                Button("设 B") { store.setB() }
                Text("\(store.loopStart + 1)–\(store.loopEnd + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Button("8 拍") { store.eightBeats() }.disabled(sequence.bpm == nil).help("从当前帧起，按音乐 BPM 取 8 拍长度")
                Button("全段") { store.fullRange() }
                Toggle("循环", isOn: $store.loopEnabled).toggleStyle(.checkbox)
                Button("节拍", systemImage: "metronome") {
                    guard let bpm = sequence.bpm else { return }
                    music.useBeat(); music.bpm = min(180, max(40, Double(bpm) * store.speed)); music.play()
                }.disabled(sequence.bpm == nil).help("按这段音乐的 BPM 播放原创节拍，尚未对齐第一拍")
                Button("加入编排", systemImage: "text.badge.plus") {
                    do {
                        try arrangements.add(reference: store.practiceReference())
                        message = "已加入“\(arrangements.draftName)”的第 \(arrangements.draft.count) 段。"
                    } catch { message = error.localizedDescription }
                }.disabled(store.motion == nil || store.loading || !arrangements.canEditDraft)
                    .accessibilityIdentifier("aist.addToArrangement")
                Button("导出", systemImage: "square.and.arrow.up") {
                    do { if let url = try store.exportSegment() { exportURL = url; message = "已导出全部连续坐标和来源说明。" } }
                    catch { message = "导出失败：\(error.localizedDescription)" }
                }.disabled(store.motion == nil).help("导出 A–B 连续坐标")
            }
            .controlSize(.small)
            .font(.caption)
        }
    }

    private var practiceRounds: Int { [2, 4, 6].contains(defaultRounds) ? defaultRounds : 4 }

    private func publishMusicPractice() {
        if showDetail, store.motion != nil, !store.loading {
            offerMusicPractice(startPractice)
        } else {
            offerMusicPractice(nil)
        }
    }

    private func startPractice() {
        guard store.motion != nil, !store.loading, store.optimized == (coordinateLayer != "raw") else { return }
        if training.active { training.stop() }
        do {
            try training.prepareReference(store.practiceReference(), rounds: practiceRounds)
            openTraining()
        } catch { message = error.localizedDescription }
    }

    private var stylePlan: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("风格练习").font(.title2.weight(.semibold))
            Text("按舞种生成一段练习，跟随动作库里的真实示范。包含热身、分段练习、休息和放松。")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                Picker("舞种", selection: $planStyle) {
                    ForEach(DanceStyle.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("练习时长", selection: $planMinutes) {
                    ForEach([10, 15, 20, 30, 45], id: \.self) { Text("\($0) 分钟").tag($0) }
                }
                Picker("起始速度", selection: $planLevel) {
                    Text("慢练 0.5×").tag(1); Text("进阶 0.75×").tag(2)
                }
            }
            HStack {
                Button("取消") { showStylePlan = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("开始练习") {
                    guard !training.active else { return }
                    training.style = planStyle; training.minutes = planMinutes; training.level = planLevel
                    training.rebuild(); showStylePlan = false; openTraining()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(training.active)
            }
        }.padding(28).frame(width: 450)
    }

    private var genres: [(String, String)] {
        Dictionary((store.manifest?.sequences ?? []).map { ($0.genreCode, $0.genreName) }, uniquingKeysWith: { first, _ in first })
            .sorted { $0.value < $1.value }.map { ($0.key, $0.value) }
    }
    private func filter() {
        let query = filters.search.trimmingCharacters(in: .whitespacesAndNewlines)
        results = (store.manifest?.sequences ?? []).filter { sequence in
            let categoryMatch: Bool
            switch filters.category {
            case "basic": categoryMatch = sequence.isBasic
            case "advanced": categoryMatch = !sequence.isBasic
            case "favorite": categoryMatch = store.favorites.contains(sequence.id)
            case "mine": categoryMatch = false
            default: categoryMatch = true
            }
            return categoryMatch &&
            (filters.genre == "all" || sequence.genreCode == filters.genre) &&
            (query.isEmpty || (store.name(for: sequence) + " " + sequence.id + " " + sequence.genreName).localizedCaseInsensitiveContains(query))
        }
    }
    private var dataInfo: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("AIST++ · 本地全帧动作库").font(.title2.bold())
            if let manifest = store.manifest {
                Text("\(manifest.sequenceCount.formatted()) 条序列 / \(manifest.totalFrames.formatted()) 个独立 3D 帧 / 60 FPS")
                Text("17 个 COCO 关节，原始与官方优化坐标均以 Float64 保存。原始序列不抽帧；播放速度只改变帧间等待时间。")
                Text("官方低质量标记：\(manifest.sequences.filter(\.ignored).count) 条，均已保留。")
            }
            Text(store.directory.path).font(.caption.monospaced()).textSelection(.enabled)
            HStack {
                Button("选择数据文件夹") { store.chooseDirectory() }
                Button("重新读取") { store.reload() }
                Button("在 Finder 中查看") { NSWorkspace.shared.open(store.directory) }
            }
            Divider()
            Text("页面上的 10,108,015 是多机位图像标注规模。图片和原视频不在 3D ZIP 中，本动作库尚未下载原视频及音乐。")
            Text("AIST++ annotations © Google LLC · CC BY 4.0\nLi, Yang, Ross & Kanazawa, ICCV 2021\nSource performances: AIST Dance Video Database, Tsuchida et al., ISMIR 2019.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Link("官方下载与说明", destination: URL(string: "https://google.github.io/aistplusplus_dataset/download.html")!)
                Link("CC BY 4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                Spacer()
                Button("完成") { showDataInfo = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 620)
    }
}

private struct AISTGalleryGrid: View {
    @StateObject private var playback = AISTGalleryPlayback()
    var directory: URL
    var reloadToken: String
    var sequences: [AISTSequence]
    var name: (AISTSequence) -> String
    var isFavorite: (AISTSequence) -> Bool
    var toggleFavorite: (AISTSequence) -> Void
    var open: (AISTSequence) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
            ForEach(sequences) { sequence in card(sequence) }
        }.padding(.bottom, 8)
        .onAppear { playback.use(directory: directory) }
        .onChange(of: directory) { _, directory in playback.use(directory: directory, reload: true) }
        .onChange(of: reloadToken) { _, _ in playback.use(directory: directory, reload: true) }
        .onDisappear { playback.stop() }
    }

    private func card(_ sequence: AISTSequence) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                thumbnail(playback.joints[sequence.id])
                    .frame(height: 188)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture { open(sequence) }
                Button { toggleFavorite(sequence) } label: {
                    Image(systemName: isFavorite(sequence) ? "star.fill" : "star")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isFavorite(sequence) ? Color.orange : Color.white)
                        .padding(7)
                        .background(.black.opacity(0.38), in: Circle())
                }.buttonStyle(.plain).padding(8).help("收藏动作")
                if sequence.ignored {
                    Image(systemName: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange)
                        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .allowsHitTesting(false)
                }
            }
            Button { open(sequence) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(name(sequence)).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    Text("\(sequence.genreName) · \(sequence.category)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text("\(sequence.dancerID) · \(clockText(sequence.duration))").font(.caption2.monospaced()).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.07)))
        .accessibilityElement(children: .contain)
        .onAppear { playback.pin(sequence) }
        .onDisappear { playback.unpin(sequence.id) }
    }

    @ViewBuilder private func thumbnail(_ joints: [SIMD3<Double>]?) -> some View {
        ZStack {
            Color(red: 0.055, green: 0.064, blue: 0.095)
            if let joints, joints.contains(where: { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) {
                AISTPoseThumbnail(joints: joints)
            } else if joints == nil {
                ProgressView().controlSize(.small).tint(.white)
            } else {
                Image(systemName: "figure.dance").font(.system(size: 28, weight: .light)).foregroundStyle(.white.opacity(0.45))
            }
        }
    }
}

private struct AISTPlaybackObserver<Content: View>: View {
    @ObservedObject var playback: AISTPlaybackState
    @ViewBuilder var content: () -> Content
    var body: some View { content() }
}
