import SwiftUI
import HidanCore

struct MoveLibraryFilters {
    var query = ""
    var style: DanceStyle?
}

struct MoveLibraryView: View {
    @Binding var filters: MoveLibraryFilters
    @ObservedObject var motions: PracticeMotionStore
    @ObservedObject var music: MusicService
    var trainingActive: Bool
    var startPractice: (_ moves: [DanceMove], _ title: String) -> Void
    var offerMusicPractice: ((() -> Void)?) -> Void = { _ in }
    @AppStorage(CoordinateLayerPreference.key) private var coordinateLayer = "optimized"
    @AppStorage("aist.visualStyle") private var visualStyle: AISTVisualStyle = .porcelain
    @AppStorage("aist.skeletonOverlay") private var skeletonOverlay = false
    @AppStorage("aist.showReferenceGrid") private var showReferenceGrid = false
    @AppStorage("aist.showJointNames") private var showJointNames = false
    @State private var showingDetail = false
    @State private var comboSeed = 0
    @State private var notice: String?
    private var filtered: [DanceMove] {
        DanceCatalog.moves.filter {
            (filters.style == nil || $0.style == filters.style) &&
            (filters.query.isEmpty || ($0.name + $0.englishName + $0.summary).localizedCaseInsensitiveContains(filters.query))
        }
    }

    var body: some View {
        Group {
            if showingDetail { detail }
            else { gallery }
        }
        .onAppear { publishMusicPractice() }
        .onChange(of: coordinateLayer) { _, value in
            guard showingDetail, !motions.moves.isEmpty else { return }
            motions.open(motions.moves, title: motions.title, optimized: value != "raw")
        }
        .onChange(of: showingDetail) { _, _ in publishMusicPractice() }
        .onChange(of: motions.loading) { _, _ in publishMusicPractice() }
        .onChange(of: motions.motion == nil) { _, _ in publishMusicPractice() }
        .onChange(of: motions.speed) { _, speed in
            guard music.sourceURL == nil, let bpm = motions.beatBPM else { return }
            let locked = min(180, max(40, bpm * speed))
            if abs(music.bpm - locked) > 0.51 { music.bpm = locked }
        }
        .onDisappear { if !showingDetail { motions.pause() }; offerMusicPractice(nil) }
    }

    private var gallery: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(text: "PRACTICE")
                    Text("基础练习").font(.system(size: 28, weight: .bold))
                    Text("每张卡片都有两套练习坐标。列表自动播放逐帧采样；点开和练习默认使用时序平滑。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    TextField("搜索基础练习 / English name", text: $filters.query)
                        .textFieldStyle(.roundedBorder).frame(width: 300)
                        .accessibilityIdentifier("motionLibrary.practice.search")
                    Spacer()
                    Picker("舞种", selection: $filters.style) {
                        Text("全部舞种").tag(Optional<DanceStyle>.none)
                        ForEach(DanceStyle.allCases) { Text($0.displayName).tag(Optional($0)) }
                    }.frame(width: 220)
                    Button("连播四段", systemImage: "square.stack.3d.up") { playCombo() }
                        .disabled(!motions.ready || trainingActive)
                }
                if let error = motions.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if !motions.ready && motions.errorMessage == nil {
                    ProgressView("正在生成练习坐标…")
                }
                PracticeMotionGallery(directory: motions.directory, ready: motions.ready, moves: filtered, open: open)
                if filtered.isEmpty { ContentUnavailableView.search(text: filters.query) }
                if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                Text("这些坐标由应用按站立练习生成，格式与动作库相同：60 FPS、17 个关节、原始采样和时序平滑成对保存。不是 AIST++ 测量，也不是经过教练验证的课程。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(32)
        }
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let error = motions.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    Button { motions.pause(); showingDetail = false } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("全部基础练习")
                    Text(motions.title).font(.title3.weight(.semibold)).lineLimit(1)
                    if motions.moves.count > 1 {
                        Text(motions.moves.map(\.name).joined(separator: " → "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else if let move = motions.moves.first {
                        Text("\(move.style.displayName) · \(move.englishName) · \(move.bpmLabel)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }.controlSize(.small)
                MotionPlaybackReader(playback: motions.playback) {
                    VStack(alignment: .leading, spacing: 12) {
                        MotionStageChrome(
                            joints: motions.currentJoints, upAxis: "y", mirrored: motions.mirrored,
                            resetToken: motions.resetCamera, loading: motions.loading,
                            identity: (motions.moves.first?.id ?? motions.title) + String(motions.optimized),
                            visualStyle: visualStyle, showJointNames: showJointNames,
                            showSkeletonOverlay: skeletonOverlay, showReferenceGrid: showReferenceGrid)
                        practiceTransport
                    }
                }
                if let move = motions.moves.count == 1 ? motions.moves.first : nil {
                    Text(move.summary)
                    Text("练习提示").font(.headline)
                    ForEach(Array(move.cues.enumerated()), id: \.offset) { index, cue in
                        HStack(alignment: .top, spacing: 14) {
                            Text("\(index + 1)").font(.caption.bold()).frame(width: 24, height: 24)
                                .background(ClubTheme.accent.opacity(0.12), in: Circle()).foregroundStyle(ClubTheme.accent)
                            Text(cue).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !move.commonMistakes.isEmpty {
                        Text("留意这些习惯").font(.headline)
                        ForEach(move.commonMistakes, id: \.self) { Text("•  " + $0).foregroundStyle(.secondary) }
                    }
                }
                Text(DanceCatalog.contentNotice).font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
    }

    private var practiceTransport: some View {
        let frame = motions.playback.frameIndex
        let count = motions.frameCount
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(format: "%.2f / %.2f 秒", Double(frame) / 60, Double(count) / 60)).monospacedDigit()
                Spacer(minLength: 8)
                Text("帧 \(frame + 1) / \(count)").monospacedDigit()
            }.font(.caption2).foregroundStyle(.secondary)
            Slider(value: Binding(get: { Double(frame) }, set: { motions.pause(); motions.seek(Int($0)) }),
                   in: 0...Double(max(1, count - 1)), step: 1).controlSize(.small).accessibilityLabel("动作帧")
            HStack(spacing: 6) {
                Button { motions.toggle() } label: {
                    Label(motions.playback.isPlaying ? "暂停预览" : "动作预览", systemImage: motions.playback.isPlaying ? "pause.fill" : "play.fill")
                }.disabled(motions.motion == nil).accessibilityIdentifier("practice.stage.play")
                Button("镜像") { motions.mirrored.toggle() }
                Button("重置视角", systemImage: "arrow.counterclockwise") { motions.resetCamera += 1 }
                Button { motions.step(-1) } label: { Image(systemName: "backward.frame") }.help("上一帧")
                Button { motions.step(1) } label: { Image(systemName: "forward.frame") }.help("下一帧")
                Picker("速度", selection: $motions.speed) {
                    ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                }.frame(width: 72).help("动作节拍速度。已导入的音乐仍按自己的播放速度。")
            }
            .controlSize(.small)
            .font(.caption)
        }
    }

    private func publishMusicPractice() {
        if showingDetail, motions.motion != nil, !motions.loading {
            offerMusicPractice { startPractice(motions.moves, motions.title) }
        } else {
            offerMusicPractice(nil)
        }
    }

    private func open(_ move: DanceMove) {
        motions.open([move], title: move.name, optimized: coordinateLayer != "raw")
        notice = nil
        showingDetail = true
    }

    private func playCombo() {
        let style = filters.style ?? .hipHop
        let ids = DanceCatalog.moves.filter { $0.style == style && $0.impact == .low && $0.suitableForStandingPractice }.map(\.id)
        do {
            let sequence = try SequenceBuilder.make(moveIDs: ids, bpm: 90, seed: comboSeed)
            comboSeed += 1
            let playlist = sequence.slots.compactMap { DanceCatalog.move(id: $0.moveID) }
            guard !playlist.isEmpty else { notice = "这个舞种还没有可连播的基础动作。"; return }
            motions.open(playlist, title: "\(style.displayName) · 四段基础组合", optimized: coordinateLayer != "raw")
            notice = sequence.warnings.joined(separator: " ")
            showingDetail = true
        } catch {
            notice = error.localizedDescription
        }
    }
}

struct PracticeMotionStage: View {
    @ObservedObject var player: PracticeMotionStore
    @ObservedObject private var playback: AISTPlaybackState
    var visualStyle: AISTVisualStyle
    var showJointNames: Bool
    var showSkeletonOverlay: Bool
    var showReferenceGrid: Bool
    var transparent: Bool

    init(player: PracticeMotionStore, visualStyle: AISTVisualStyle, showJointNames: Bool,
         showSkeletonOverlay: Bool, showReferenceGrid: Bool, transparent: Bool) {
        self.player = player
        self.playback = player.playback
        self.visualStyle = visualStyle
        self.showJointNames = showJointNames
        self.showSkeletonOverlay = showSkeletonOverlay
        self.showReferenceGrid = showReferenceGrid
        self.transparent = transparent
    }

    var body: some View {
        Group {
            if player.motion != nil {
                let _ = playback.frameIndex
                AISTSkeletonView(joints: player.currentJoints, upAxis: "y", mirrored: player.mirrored,
                                 resetToken: player.resetCamera, showJointNames: showJointNames, style: visualStyle,
                                 showSkeletonOverlay: showSkeletonOverlay, showReferenceGrid: showReferenceGrid,
                                 transparentBackground: transparent)
                    .id((player.moves.first?.id ?? "") + String(player.optimized) + String(player.resetCamera))
            } else if player.loading {
                ProgressView("正在读取练习动作…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("练习动作还没准备好", systemImage: "figure.dance", description: Text(player.errorMessage ?? "请稍后再打开。"))
            }
        }
        .background(transparent ? Color.clear : Color(red: 0.055, green: 0.064, blue: 0.095))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct PracticeMotionGallery: View {
    @StateObject private var playback = PracticeGalleryPlayback()
    var directory: URL
    var ready: Bool
    var moves: [DanceMove]
    var open: (DanceMove) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 18, alignment: .top)], spacing: 18) {
            ForEach(moves) { move in
                Button { open(move) } label: { card(move) }
                    .buttonStyle(.plain)
                    .onAppear { playback.pin(move, directory: directory, ready: ready) }
                    .onDisappear { playback.unpin(move.id) }
            }
        }
        .onChange(of: ready) { _, ready in playback.refresh(moves: moves, directory: directory, ready: ready) }
        .onDisappear { playback.stop() }
    }

    private func card(_ move: DanceMove) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            thumbnail(playback.joints[move.id]).frame(height: 160).clipShape(RoundedRectangle(cornerRadius: 14))
            Text(move.englishName).font(.system(size: 18, weight: .semibold)).lineLimit(1)
            Text(move.name).foregroundStyle(.secondary)
            Text(move.summary).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            HStack { Text(move.style.displayName); Spacer(); Text(move.bpmLabel) }
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.07)))
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

@MainActor private final class PracticeGalleryPlayback: ObservableObject {
    @Published private(set) var joints: [String: [SIMD3<Double>]] = [:]
    private var motions: [String: AISTMotion] = [:]
    private var cursors: [String: Int] = [:]
    private var pins: [String: Int] = [:]
    private var timer: Timer?

    func pin(_ move: DanceMove, directory: URL, ready: Bool) {
        pins[move.id, default: 0] += 1
        load(move, directory: directory, ready: ready)
    }

    func refresh(moves: [DanceMove], directory: URL, ready: Bool) {
        guard ready else { return }
        for move in moves where pins[move.id, default: 0] > 0 { load(move, directory: directory, ready: true) }
    }

    private func load(_ move: DanceMove, directory: URL, ready: Bool) {
        guard ready, motions[move.id] == nil else { return }
        let id = move.id
        Task {
            let loaded = try? await Task.detached { try PracticeMotionLibrary.load(in: directory, id: id, optimized: false) }.value
            guard pins[id, default: 0] > 0, motions[id] == nil, let loaded else { return }
            motions[id] = loaded
            cursors[id] = 0
            joints[id] = loaded.joints(at: 0)
            start()
        }
    }

    func unpin(_ id: String) {
        let remaining = (pins[id] ?? 1) - 1
        guard remaining <= 0 else { pins[id] = remaining; return }
        pins[id] = nil
        motions[id] = nil
        cursors[id] = nil
        joints[id] = nil
        if motions.isEmpty { timer?.invalidate(); timer = nil }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        motions = [:]
        cursors = [:]
        pins = [:]
        joints = [:]
    }

    private func start() {
        guard timer == nil else { return }
        timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func tick() {
        guard !motions.isEmpty else { return }
        var next = joints
        for (id, motion) in motions {
            let frame = ((cursors[id] ?? 0) + 1) % max(motion.frameCount, 1)
            cursors[id] = frame
            next[id] = motion.joints(at: frame)
        }
        joints = next
    }
}
