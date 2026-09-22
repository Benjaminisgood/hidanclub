import SwiftUI
import HidanCore

struct MoveLibraryFilters {
    var query = ""
    var style: DanceStyle?
}

struct MoveLibraryView: View {
    @Binding var filters: MoveLibraryFilters
    @ObservedObject var motions: PracticeMotionStore
    var trainingActive: Bool
    var startPractice: (_ moves: [DanceMove], _ title: String) -> Void
    @AppStorage(CoordinateLayerPreference.key) private var coordinateLayer = "optimized"
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
        .onChange(of: coordinateLayer) { _, value in
            guard showingDetail, !motions.moves.isEmpty else { return }
            motions.open(motions.moves, title: motions.title, optimized: value != "raw")
        }
        .onDisappear { if !showingDetail { motions.pause() } }
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
            VStack(alignment: .leading, spacing: 18) {
                Button("全部基础练习", systemImage: "chevron.left") {
                    motions.pause(); showingDetail = false
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                if let error = motions.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                Text(motions.title).font(.title2.bold())
                if motions.moves.count > 1 {
                    Text(motions.moves.map(\.name).joined(separator: " → "))
                        .font(.callout).foregroundStyle(.secondary)
                } else if let move = motions.moves.first {
                    Text("\(move.englishName) · \(move.style.displayName) · \(move.bpmLabel)")
                        .font(.callout).foregroundStyle(.secondary)
                    Text(move.summary)
                }
                Text(motions.optimized ? "时序平滑坐标" : "逐帧采样坐标")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                PracticeMotionStage(player: motions, visualStyle: .porcelain, showJointNames: false,
                                    showSkeletonOverlay: false, showReferenceGrid: false, transparent: false)
                    .frame(height: 420)
                PracticeMotionTransport(player: motions, trainingActive: trainingActive) {
                    startPractice(motions.moves, motions.title)
                }
                if let move = motions.moves.count == 1 ? motions.moves.first : nil {
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
            }.padding(32)
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

private struct PracticeMotionTransport: View {
    @ObservedObject var player: PracticeMotionStore
    @ObservedObject private var playback: AISTPlaybackState
    var trainingActive: Bool
    var startPractice: () -> Void

    init(player: PracticeMotionStore, trainingActive: Bool, startPractice: @escaping () -> Void) {
        self.player = player
        self.playback = player.playback
        self.trainingActive = trainingActive
        self.startPractice = startPractice
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(action: player.toggle) {
                    Label(playback.isPlaying ? "暂停动作" : "播放动作", systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
                }.buttonStyle(.borderedProminent).disabled(player.motion == nil)
                Button(trainingActive ? "继续练习" : "开始练习", action: startPractice)
                    .buttonStyle(.borderedProminent).disabled(!trainingActive && (player.motion == nil || player.loading))
                Spacer()
                Picker("速度", selection: $player.speed) {
                    ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                }.frame(width: 110)
                Toggle("镜像", isOn: $player.mirrored).toggleStyle(.checkbox)
            }
            Slider(value: Binding(get: { Double(playback.frameIndex) }, set: { player.pause(); player.seek(Int($0)) }),
                   in: 0...Double(max(1, player.frameCount - 1)), step: 1)
                .disabled(player.motion == nil)
        }
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
