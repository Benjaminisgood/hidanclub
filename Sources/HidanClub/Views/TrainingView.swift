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
    var onBack: () -> Void
    @AppStorage("training.displayMode") private var displayMode: TrainingDisplayMode = .sideBySide
    @AppStorage("training.cameraOnByDefault") private var cameraOnByDefault = false
    @AppStorage("aist.skeletonOverlay") private var skeletonOverlay = false
    @AppStorage("aist.showReferenceGrid") private var showReferenceGrid = false
    @AppStorage("aist.showJointNames") private var showJointNames = false
    @State private var overlayOpacity = 0.65
    @State private var overlayScale = 1.0
    @State private var overlayOffset = CGSize.zero
    @State private var dragStart = CGSize.zero
    @State private var showPlan = false
    @AppStorage("aist.visualStyle") private var visualStyle: AISTVisualStyle = .porcelain

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                selectedPractice
                trainingSurface
                if displayMode == .overlay {
                    HStack {
                        Text("示范透明度").font(.caption)
                        Slider(value: $overlayOpacity, in: 0.15...1).frame(width: 100)
                        Text("大小").font(.caption)
                        Slider(value: $overlayScale, in: 0.5...1.8).frame(width: 100)
                        Button("重置位置") { overlayScale = 1; overlayOffset = .zero; dragStart = .zero }
                        Text("拖动示范调整位置 · 手动视觉对照，尚未自动对齐").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if source == .aist { sessionControls }
                else if source == .generated { GeneratedSessionControls(training: store, practice: practice) }
                else if source == .captured { capturedControls }
                else { freePracticeControls }
                if displayMode != .demonstration { LivePoseCameraControls(camera: camera) }
                if source == .aist || source == .generated {
                    if source == .aist, let issue = demonstration.issue ?? store.demonstrationError {
                        HStack {
                            Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                            Spacer()
                            Button("重新载入") { demonstration.reload() }
                        }
                    }
                    DisclosureGroup("训练计划 · \(store.plan.blocks.count) 段 · \(clockText(Double(store.plan.totalSeconds)))", isExpanded: $showPlan) {
                        planList.padding(.top, 12)
                    }.font(.callout.weight(.medium))
                }
                Text("腾出能自由伸展的空间。相机检测在本机完成；二维关节、角度与入镜提示用于观察，不代表舞蹈质量评分。音乐尚未与示范动作自动对拍。")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(22)
        }
        .onAppear {
            guard cameraOnByDefault, displayMode != .demonstration, !camera.isRunning, !camera.isBusy else { return }
            camera.start()
        }
        .onDisappear {
            demonstration.pause(); captured.pause(); practice.pause(); camera.stop(); music.pause()
        }
    }
    private var header: some View {
        HStack {
            Button("返回", systemImage: "chevron.left", action: onBack)
            VStack(alignment: .leading, spacing: 5) {
                Eyebrow(text: source == .none ? "RECORD / 看着自己" : "PRACTICE / 跟练")
                Text(source == .none ? "看着自己，录下这一段。" : "看见动作，也看见自己。").font(.system(size: 25, weight: .bold))
            }
            Spacer()
        }
    }
    private var selectedPractice: some View {
        HStack {
            if source == .aist {
                Label(store.plan.title, systemImage: "figure.dance").font(.callout.weight(.medium))
            } else if source == .captured {
                Label(captured.selected?.name ?? "视频动作编排", systemImage: "square.stack.3d.up").font(.callout.weight(.medium))
                Text("视频库 · 2D 动作模型").font(.caption).foregroundStyle(.secondary)
            } else if source == .generated {
                Label(practice.title.isEmpty ? "基础练习" : practice.title, systemImage: "figure.walk").font(.callout.weight(.medium))
            } else {
                Label("自由观察 · 实时摄像头", systemImage: "web.camera").font(.callout.weight(.medium))
                Text("跟练请从动作、编排或视频进入").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
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
                    stagePanel.frame(maxWidth: .infinity)
                    cameraPanel.frame(maxWidth: .infinity)
                }
            case .demonstration: stagePanel
            case .camera: cameraPanel
            case .overlay:
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("摄像头 + 动作示范", systemImage: "square.3.layers.3d")
                        Spacer()
                        Text("示范半透明 · 自身关节高亮").foregroundStyle(.secondary)
                    }.font(.caption)
                    ZStack {
                        LivePoseCameraSurface(camera: camera)
                        if camera.isRunning && source != .none {
                            demonstrationSurface(transparent: true)
                                .opacity(overlayOpacity).scaleEffect(overlayScale).offset(overlayOffset)
                                .allowsHitTesting(false)
                            Color.clear.contentShape(Rectangle()).gesture(
                                DragGesture().onChanged { value in
                                    overlayOffset = CGSize(width: dragStart.width + value.translation.width, height: dragStart.height + value.translation.height)
                                }.onEnded { _ in dragStart = overlayOffset }
                            )
                        }
                    }.frame(height: 310).clipped().clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }
    private var stagePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(source == .aist ? (demonstration.reference?.name ?? "动作示范") : source == .captured ? (captured.selected?.name ?? "动作编排") : "动作示范", systemImage: "figure.dance")
                    .font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if source == .aist { Text(demonstration.stageLabel).font(.caption2).foregroundStyle(.secondary) }
            }
            demonstrationSurface(transparent: false).frame(height: 310).clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
    private var cameraPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("我的实时画面", systemImage: "web.camera").font(.callout.weight(.semibold))
                Spacer()
                Text("本机捕捉").font(.caption2).foregroundStyle(.secondary)
            }
            LivePoseCameraSurface(camera: camera).frame(height: 310).clipShape(RoundedRectangle(cornerRadius: 16))
        }
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
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 12) {
                    Text(store.active ? (store.snapshot.currentBlock?.title ?? "练习") : (store.clock.state == .completed ? "本次练习已完成" : "准备跟练"))
                        .font(.title3.weight(.semibold))
                    Text(clockText(store.snapshot.remainingSeconds)).font(.system(size: 28, weight: .medium, design: .rounded)).monospacedDigit()
                    if store.clock.state == .paused { Text("已暂停").font(.caption).foregroundStyle(.secondary) }
                }
                Text(store.snapshot.currentBlock?.cue ?? "先预览动作，再开始跟练。")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 8) {
                HStack {
                    Button(action: primaryAction) {
                        Label(store.clock.state == .running ? "暂停练习" : store.clock.state == .paused ? "继续练习" : "开始练习", systemImage: store.clock.state == .running ? "pause.fill" : "play.fill")
                    }.buttonStyle(.borderedProminent)
                        .disabled(store.clock.state != .running && !demonstration.isReady)
                    if store.active {
                        Button("下一段") { demonstration.advance(); if !store.active { music.stop() } }
                        Button("结束") { demonstration.stop(); music.stop() }
                    }
                }
                TrainingAISTTransport(demonstration: demonstration)
            }
        }.padding(15).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
    private var capturedControls: some View {
        CapturedTrainingControls(store: captured)
    }
    private func primaryAction() {
        if store.clock.state == .running { demonstration.pause(); music.pause() }
        else if demonstration.startOrResume(), !store.isCustomPlan { music.play() }
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
            if !demonstration.training.active {
                Button(playback.isPlaying ? "暂停预览" : "预览动作") { demonstration.togglePreview() }.disabled(!demonstration.isReady)
            }
            Picker("速度", selection: $player.speed) {
                Text("0.25×").tag(0.25); Text("0.5×").tag(0.5); Text("0.75×").tag(0.75); Text("1×").tag(1.0)
            }.labelsHidden().frame(width: 72)
            Toggle("镜像", isOn: $player.mirrored).toggleStyle(.checkbox)
            Button { player.resetCamera += 1 } label: { Image(systemName: "viewfinder") }.help("重置示范视角")
        }.controlSize(.small).font(.caption)
    }
}

private struct GeneratedSessionControls: View {
    @ObservedObject var training: TrainingStore
    @ObservedObject var practice: PracticeMotionStore
    @ObservedObject private var playback: AISTPlaybackState

    init(training: TrainingStore, practice: PracticeMotionStore) {
        self.training = training
        self.practice = practice
        self.playback = practice.playback
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 12) {
                    Text(training.active ? (training.snapshot.currentBlock?.title ?? "练习") : (training.clock.state == .completed ? "本次练习已完成" : "准备跟练"))
                        .font(.title3.weight(.semibold))
                    Text(clockText(training.snapshot.remainingSeconds)).font(.system(size: 28, weight: .medium, design: .rounded)).monospacedDigit()
                }
                Text(training.snapshot.currentBlock?.cue ?? "先看动作，再开始跟练。")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 8) {
                HStack {
                    Button(action: primary) {
                        Label(training.clock.state == .running ? "暂停练习" : training.clock.state == .paused ? "继续练习" : "开始练习",
                              systemImage: training.clock.state == .running ? "pause.fill" : "play.fill")
                    }.buttonStyle(.borderedProminent).disabled(practice.motion == nil && training.clock.state != .running)
                    if training.active {
                        Button("下一段") { training.advance(); if !training.active { practice.pause() } }
                        Button("结束") { training.stop(); practice.pause() }
                    }
                }
                HStack(spacing: 9) {
                    if !training.active {
                        Button(playback.isPlaying ? "暂停预览" : "预览动作") { practice.toggle() }.disabled(practice.motion == nil)
                    }
                    Picker("速度", selection: $practice.speed) {
                        Text("0.25×").tag(0.25); Text("0.5×").tag(0.5); Text("0.75×").tag(0.75); Text("1×").tag(1.0)
                    }.labelsHidden().frame(width: 72)
                    Toggle("镜像", isOn: $practice.mirrored).toggleStyle(.checkbox)
                }.controlSize(.small).font(.caption)
            }
        }.padding(15).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func primary() {
        if training.clock.state == .running { training.pause(); practice.pause() }
        else if training.clock.state == .paused { training.resume(); practice.play() }
        else { training.start(); practice.play() }
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
