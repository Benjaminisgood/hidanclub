import SwiftUI
import HidanCore

enum TrainingDisplayMode: String, CaseIterable, Identifiable {
    case sideBySide = "并排", demonstration = "只看示范", camera = "只看摄像头", overlay = "叠加"
    var id: String { rawValue }
}
enum TrainingSource: String { case none, aist, captured, generated }

struct TrainingView: View {
    @ObservedObject var store: TrainingStore
    @ObservedObject var music: MusicService
    @ObservedObject var demonstration: TrainingDemonstrationStore
    @ObservedObject var camera: LivePoseCamera
    @ObservedObject var captured: CapturedMotionStore
    var practice: PracticeMotionStore
    @Binding var source: TrainingSource
    @Binding var fullscreen: Bool
    var onBack: () -> Void
    @AppStorage("training.displayMode") private var displayMode: TrainingDisplayMode = .sideBySide
    @AppStorage("training.cameraOnByDefault") private var cameraOnByDefault = false
    @AppStorage("aist.skeletonOverlay") private var skeletonOverlay = false
    @AppStorage("aist.showReferenceGrid") private var showReferenceGrid = false
    @AppStorage("aist.showJointNames") private var showJointNames = false
    @State private var overlayOpacity = 0.72
    @State private var overlayScale = 0.42
    @State private var overlayOffset = CGSize.zero
    @State private var dragStart = CGSize.zero
    @State private var showPlan = false
    @State private var lockingTempo = false
    @AppStorage("aist.visualStyle") private var visualStyle: AISTVisualStyle = .porcelain

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            trainingSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 320)
                .layoutPriority(1)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if source == .aist { sessionControls }
                    else if source == .generated { GeneratedSessionControls(training: store, practice: practice, music: music) }
                    else if source == .captured { capturedControls }
                    else { freePracticeControls }
                    if displayMode == .overlay { overlayAdjustments.controlSize(.small) }
                    if displayMode != .demonstration { LivePoseCameraControls(camera: camera, compact: true) }
                    if source == .aist, let issue = demonstration.issue ?? store.demonstrationError {
                        HStack {
                            Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(1)
                            Spacer()
                            Button("重新载入") { demonstration.reload() }.controlSize(.small)
                        }
                    }
                    if source == .aist || source == .generated {
                        DisclosureGroup("训练计划 · \(store.plan.blocks.count) 段 · \(clockText(Double(store.plan.totalSeconds)))", isExpanded: $showPlan) {
                            planList.padding(.top, 8)
                        }.font(.caption)
                    }
                }
            }
            .frame(maxHeight: showPlan ? 220 : 132)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            shareBeat()
            guard cameraOnByDefault, displayMode != .demonstration, !camera.isRunning, !camera.isBusy else { return }
            camera.start()
        }
        .onChange(of: demonstration.reference?.sequence.bpm) { _, _ in shareBeat() }
        .onChange(of: practice.beatBPM) { _, _ in if source == .generated { shareBeat() } }
        .onChange(of: music.bpm) { _, _ in followSharedBeat() }
        .onDisappear {
            demonstration.pause(); captured.pause(); practice.pause(); camera.stop(); music.pause()
        }
    }
    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) { Image(systemName: "chevron.left") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("返回")
            Text(headerTitle).font(.title3.weight(.semibold)).lineLimit(1)
            Text(headerDetail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Button(fullscreen ? "退出全屏" : "全屏", systemImage: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                fullscreen.toggle()
            }.controlSize(.small)
            .background {
                if fullscreen {
                    Button("退出全屏") { fullscreen = false }
                        .keyboardShortcut(.cancelAction)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }
        }
    }
    private var headerTitle: String {
        switch source {
        case .aist: return store.plan.title
        case .captured: return captured.selected?.name ?? "视频动作"
        case .generated: return practice.title.isEmpty ? "基础练习" : practice.title
        case .none: return "看着自己"
        }
    }
    private var headerDetail: String {
        switch source {
        case .aist: return demonstration.reference?.name ?? "跟练"
        case .captured: return "视频截取 · 二维"
        case .generated: return "练习坐标"
        case .none: return "实时摄像头"
        }
    }
    private var freePracticeControls: some View {
        HStack {
            Text("打开摄像头，观察自己的关节，或录下这一段。跟练请从动作、编排或视频进入。").font(.callout).foregroundStyle(.secondary)
            Spacer()
            if !camera.isRunning && !camera.isBusy {
                Button("开启摄像头") {
                    if displayMode == .demonstration { displayMode = .camera }
                    camera.start()
                }.buttonStyle(.borderedProminent)
            }
        }.padding(15).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
    private var trainingSurface: some View {
        Group {
            switch displayMode {
            case .sideBySide:
                HStack(spacing: 12) {
                    stagePanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                    cameraPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .demonstration: stagePanel
            case .camera: cameraPanel
            case .overlay:
                GeometryReader { geo in
                    ZStack {
                        LivePoseCameraSurface(camera: camera)
                            .frame(width: geo.size.width, height: geo.size.height)
                        if camera.isRunning && source != .none {
                            demonstrationSurface(transparent: true)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .scaleEffect(overlayScale, anchor: .center)
                                .offset(overlayOffset)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture().onChanged { value in
                            overlayOffset = CGSize(width: dragStart.width + value.translation.width, height: dragStart.height + value.translation.height)
                        }.onEnded { _ in dragStart = overlayOffset }
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
    }
    private var stagePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(source == .aist ? (demonstration.reference?.name ?? "动作示范") : source == .captured ? (captured.selected?.name ?? "动作编排") : source == .generated ? (practice.title.isEmpty ? "基础练习" : practice.title) : "动作示范", systemImage: "figure.dance")
                    .font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                if source == .aist { Text(demonstration.stageLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            demonstrationSurface(transparent: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var cameraPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("我的实时画面", systemImage: "web.camera").font(.callout.weight(.semibold))
                Spacer()
                Text("本机捕捉").font(.caption2).foregroundStyle(.secondary)
            }
            LivePoseCameraSurface(camera: camera)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    @ViewBuilder private func demonstrationSurface(transparent: Bool) -> some View {
        if source == .generated {
            PracticeMotionStage(player: practice, visualStyle: visualStyle, showJointNames: showJointNames,
                                showSkeletonOverlay: skeletonOverlay, showReferenceGrid: showReferenceGrid, transparent: transparent)
        } else if source == .aist {
            TrainingAISTStage(player: demonstration.player, visualStyle: visualStyle, showJointNames: showJointNames,
                              showSkeletonOverlay: skeletonOverlay, showReferenceGrid: showReferenceGrid, transparent: transparent)
        } else if source == .captured {
            CapturedMotionPlayerView(playback: captured.playback, transparentBackground: transparent)
        } else {
            ContentUnavailableView {
                Label("还没有动作示范", systemImage: "figure.dance")
            } description: { Text("从动作库选好内容后再开始跟练。这里也可以只用摄像头观察。") }
        }
    }
    private var sessionControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(store.active ? (store.snapshot.currentBlock?.title ?? "练习") : (store.clock.state == .completed ? "本次完成" : "准备跟练"))
                    .font(.callout.weight(.medium)).lineLimit(1)
                Text(clockText(store.snapshot.remainingSeconds)).font(.title3.monospacedDigit())
                if store.clock.state == .paused { Text("已暂停").font(.caption2).foregroundStyle(.secondary) }
                Spacer(minLength: 8)
            }
            HStack(spacing: 6) {
                Button(action: primaryAction) {
                    Label(store.clock.state == .running ? "暂停" : store.clock.state == .paused ? "继续" : "开始练习", systemImage: store.clock.state == .running ? "pause.fill" : "play.fill")
                }.disabled(store.clock.state != .running && !demonstration.isReady)
                if store.active {
                    Button("下一段") { demonstration.advance(); if !store.active { music.stop() } }
                    Button("结束") { demonstration.stop(); music.stop() }
                }
                TrainingAISTTransport(demonstration: demonstration)
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            Text(store.snapshot.currentBlock?.cue ?? "先看动作，再开始跟练。")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
    private var overlayAdjustments: some View {
        HStack(spacing: 6) {
            Text("透明").font(.caption2).foregroundStyle(.secondary)
            Slider(value: $overlayOpacity, in: 0.2...1).frame(width: 72)
            Text("大小").font(.caption2).foregroundStyle(.secondary)
            Slider(value: $overlayScale, in: 0.2...1).frame(width: 72)
            Button("重置位置") { overlayScale = 0.42; overlayOffset = .zero; dragStart = .zero }
                .help("示范叠在镜头上，可拖动。这是手动对照，不会自动对齐身体。")
        }
    }
    private var capturedControls: some View {
        CapturedTrainingControls(store: captured)
    }
    private func primaryAction() {
        if store.clock.state == .running { demonstration.pause(); music.pause() }
        else {
            if !music.isPaused { alignPracticeDownbeat() }
            if demonstration.startOrResume() {
                music.play()
                if music.isPlaying { demonstration.setReferencePlaying(true) }
            }
        }
    }

    /// The motion's recorded tempo and the metronome are one clock: BPM × playback speed.
    private func shareBeat() {
        guard !lockingTempo, let sourceBPM = sharedSourceBPM, sourceBPM > 0 else { return }
        lockingTempo = true
        guard music.sourceURL == nil else { lockingTempo = false; return }
        let locked = min(180, max(40, sourceBPM * motionSpeed))
        music.bpm = locked
        setMotionSpeed(min(1, max(0.25, locked / sourceBPM)))
        lockingTempo = false
    }

    private func followSharedBeat() {
        guard !lockingTempo, music.sourceURL == nil, let sourceBPM = sharedSourceBPM, sourceBPM > 0 else { return }
        let speed = min(1, max(0.25, music.bpm / sourceBPM))
        lockingTempo = true
        setMotionSpeed(speed)
        let locked = min(180, max(40, sourceBPM * speed))
        if abs(music.bpm - locked) > 0.51 { music.bpm = locked }
        lockingTempo = false
    }

    private func alignPracticeDownbeat() {
        guard !music.isPlaying, !music.isPaused else { return }
        switch source {
        case .aist: demonstration.player.seek(demonstration.player.loopStart)
        case .generated: practice.seek(0)
        case .captured, .none: break
        }
        if music.sourceURL == nil { music.stop() }
    }

    private var sharedSourceBPM: Double? {
        switch source {
        case .aist: return demonstration.reference?.sequence.bpm.map(Double.init) ?? demonstration.player.selected?.bpm.map(Double.init)
        case .generated: return practice.beatBPM
        case .captured, .none: return nil
        }
    }

    private var motionSpeed: Double {
        switch source {
        case .aist: return demonstration.player.speed
        case .generated: return practice.speed
        case .captured: return captured.playback.speed
        case .none: return 1
        }
    }

    private func setMotionSpeed(_ speed: Double) {
        switch source {
        case .aist: demonstration.player.speed = speed
        case .generated: practice.speed = speed
        case .captured: captured.playback.speed = speed
        case .none: break
        }
    }
    private var planList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(store.plan.blocks.enumerated()), id: \.element.id) { index, block in
                HStack(spacing: 12) {
                    Text(String(format: "%02d", index + 1)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 25)
                    Image(systemName: store.reference(for: block) != nil ? "figure.dance" : block.kind == .rest ? "cup.and.saucer" : "figure.walk")
                        .frame(width: 20).foregroundStyle(ClubTheme.accent)
                    Text(block.title).font(.callout.weight(store.active && store.snapshot.blockIndex == index ? .bold : .regular))
                    Text(block.kind.displayName).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(clockText(Double(block.durationSeconds))).font(.caption.monospacedDigit())
                }
            }
            Divider()
            HStack {
                Text("此刻的用力感").font(.caption)
                Slider(value: Binding(get: { Double(store.effort) }, set: { store.effort = Int($0) }), in: 1...10, step: 1).frame(width: 180)
                Text("\(store.effort) / 10 · 自我记录").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct TrainingAISTStage: View {
    @ObservedObject var player: AISTLibraryStore
    var visualStyle: AISTVisualStyle
    var showJointNames: Bool
    var showSkeletonOverlay: Bool
    var showReferenceGrid: Bool
    var transparent: Bool
    var body: some View {
        Group {
            if let sequence = player.selected, player.motion != nil {
                TrainingFrameObserver(playback: player.playback) {
                    AISTSkeletonView(joints: player.currentJoints, upAxis: player.upAxis, mirrored: player.mirrored,
                                     resetToken: player.resetCamera, showJointNames: showJointNames, style: visualStyle,
                                     showSkeletonOverlay: showSkeletonOverlay, showReferenceGrid: showReferenceGrid,
                                     transparentBackground: transparent)
                        .id(sequence.id + player.upAxis + String(player.optimized))
                }
            } else if player.loading {
                ProgressView("正在载入动作…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("动作示范尚未载入", systemImage: "figure.dance", description: Text(player.errorMessage ?? "请重新载入本地动作库。"))
            }
        }
    }
}
private struct TrainingFrameObserver<Content: View>: View {
    @ObservedObject var playback: AISTPlaybackState
    @ViewBuilder var content: () -> Content
    var body: some View { content() }
}
private struct TrainingAISTTransport: View {
    @ObservedObject var demonstration: TrainingDemonstrationStore
    @ObservedObject private var player: AISTLibraryStore
    @ObservedObject private var playback: AISTPlaybackState
    init(demonstration: TrainingDemonstrationStore) {
        self.demonstration = demonstration; self.player = demonstration.player
        self.playback = demonstration.player.playback
    }
    var body: some View {
        HStack(spacing: 9) {
            Button("镜像") { player.mirrored.toggle() }.help("镜像示范")
            Button { player.resetCamera += 1 } label: { Image(systemName: "arrow.counterclockwise") }.help("重置示范视角")
        }.controlSize(.small).font(.caption)
    }
}

private struct GeneratedSessionControls: View {
    @ObservedObject var training: TrainingStore
    @ObservedObject var practice: PracticeMotionStore
    @ObservedObject var music: MusicService
    @ObservedObject private var playback: AISTPlaybackState

    init(training: TrainingStore, practice: PracticeMotionStore, music: MusicService) {
        self.training = training
        self.practice = practice
        self.music = music
        self.playback = practice.playback
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(training.active ? (training.snapshot.currentBlock?.title ?? "练习") : (training.clock.state == .completed ? "本次完成" : "准备跟练"))
                    .font(.callout.weight(.medium)).lineLimit(1)
                Text(clockText(training.snapshot.remainingSeconds)).font(.title3.monospacedDigit())
                Spacer(minLength: 8)
            }
            HStack(spacing: 6) {
                Button(action: primary) {
                    Label(training.clock.state == .running ? "暂停" : training.clock.state == .paused ? "继续" : "开始练习",
                          systemImage: training.clock.state == .running ? "pause.fill" : "play.fill")
                }.disabled(practice.motion == nil && training.clock.state != .running)
                if training.active {
                    Button("下一段") { training.advance(); if !training.active { practice.pause() } }
                    Button("结束") { training.stop(); practice.pause(); music.pause() }
                }
                Button("镜像") { practice.mirrored.toggle() }.help("镜像示范")
                Button { practice.resetCamera += 1 } label: { Image(systemName: "arrow.counterclockwise") }.help("重置示范视角")
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            Text(training.snapshot.currentBlock?.cue ?? "先看动作，再开始跟练。")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func primary() {
        if training.clock.state == .running { training.pause(); practice.pause(); music.pause() }
        else if training.clock.state == .paused { training.resume(); music.play(); if music.isPlaying { practice.play() } }
        else { training.start(); music.play(); if music.isPlaying { practice.play() } }
    }
}

private struct CapturedTrainingControls: View {
    @ObservedObject var store: CapturedMotionStore
    @ObservedObject private var playback: CapturedMotionPlayback
    init(store: CapturedMotionStore) {
        self.store = store; self.playback = store.playback
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(playback.isCompleted ? (playback.hasSkippedSegments ? "这段动作已播放完 · 中途跳过了片段" : "这段动作已播放完") : playback.currentSegment?.name ?? "还没有可跟练的动作")
                        .font(.title3.weight(.semibold))
                    if let segment = playback.currentSegment {
                        Text("片段 \(playback.segmentIndex + 1) · 第 \(playback.repetitionIndex + 1) / \(segment.repeats) 次 · \(clockText(playback.elapsed)) / \(clockText(playback.planDuration))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    } else { Text("在视频里完成识别，或从动作库打开截出的动作。").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button(playback.isPlaying ? "暂停跟练" : playback.isCompleted ? "再练一轮" : "开始跟练", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
                    playback.toggle()
                }.buttonStyle(.borderedProminent).disabled(!playback.hasPlayableMotion)
                Button("下一片段") { playback.nextSegment() }.disabled(!playback.hasPlayableMotion)
                Button("结束") { playback.stop() }.disabled(!playback.hasPlayableMotion)
            }
            HStack {
                Picker("示范速度", selection: $playback.speed) {
                    Text("0.25×").tag(0.25); Text("0.5×").tag(0.5); Text("0.75×").tag(0.75); Text("1×").tag(1.0)
                }.frame(width: 155)
                Toggle("镜像示范", isOn: $playback.mirrored).toggleStyle(.checkbox)
                Toggle("整段循环", isOn: $playback.loop).toggleStyle(.checkbox)
                Spacer()
            }.controlSize(.small).font(.caption)
            Text("按原视频时间戳逐帧示范；缺失或多人帧保留并提示。当前计时是播放进度，尚未记入练习记录。")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(15).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
