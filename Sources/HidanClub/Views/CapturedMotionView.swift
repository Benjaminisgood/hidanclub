import SwiftUI
import UniformTypeIdentifiers

struct CapturedMotionView: View {
    @ObservedObject var store: CapturedMotionStore
    var onPractice: (() -> Void)? = nil
    var canPractice = true
    var allowsModelSelection = true
    var showsSaveAction = true
    @State private var modelName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("这段视频的动作", systemImage: "figure.dance").font(.title2.weight(.semibold))
                Spacer()
                if store.isLoading { ProgressView().controlSize(.small) }
                if allowsModelSelection && (!store.saved.isEmpty || !store.drafts.isEmpty) {
                    Menu(store.drafts.isEmpty ? "已保存 \(store.saved.count) 个" : "切换模型 · \(store.drafts.count) 个草稿") {
                        if !store.drafts.isEmpty {
                            Section("未保存草稿 · 本次会话") {
                                ForEach(store.drafts) { model in Button(model.name) { store.select(model) } }
                            }
                        }
                        Section("已保存模型") {
                            ForEach(store.saved.filter { model in !store.drafts.contains { $0.id == model.id } }) { model in Button(model.name) { store.select(model) } }
                        }
                    }
                }
            }
            if let model = store.selected {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("给这段舞蹈命名", text: Binding(get: { modelName }, set: { modelName = $0; store.rename($0) }))
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 10) {
                        if showsSaveAction {
                            Button(store.isSaving ? "保存中…" : "保存完整模型") { store.rename(modelName); Task { await store.saveSelected() } }.disabled(store.isSaving)
                        }
                        Button(store.isExporting ? "导出中…" : "导出 JSON", systemImage: "square.and.arrow.up") { exportModel() }.disabled(store.isExporting)
                        if let onPractice {
                            Button("直接跟练", systemImage: "play.fill") {
                                store.rename(modelName)
                                let requestedID = store.selected?.id
                                let requestedRevision = store.revision
                                Task {
                                    if store.hasUnsavedChanges { await store.saveSelected() }
                                    if canPractice && store.selected?.id == requestedID && store.revision == requestedRevision && !store.hasUnsavedChanges && store.errorMessage == nil { onPractice() }
                                }
                            }.buttonStyle(.borderedProminent).disabled(!model.hasPlayableMotion || !canPractice || store.isSaving)
                        }
                        Spacer(minLength: 0)
                    }
                }
                if !canPractice { Text("先结束当前练习，再切换这段视频。").font(.caption).foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.flexible(minimum: 0), alignment: .leading), GridItem(.flexible(minimum: 0), alignment: .leading)], alignment: .leading, spacing: 8) {
                    Text("2D · \(model.frameCount) 个原始帧")
                    Text(String(format: "单人检测 %.1f%%", model.report.coverage * 100))
                    Text(String(format: "可用骨架 %.1f%%", model.usableCoverage * 100))
                    Text(store.hasUnsavedChanges ? "识别结果尚有未保存修改" : "识别结果附在这条视频上")
                }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                Text(model.qualityNotice).font(.callout).foregroundStyle(model.usableCoverage < 0.5 ? Color.orange : Color.secondary)
                CapturedMotionPlayerView(playback: store.playback).frame(minHeight: 280, maxHeight: 440)
                CapturedMotionPreviewControls(playback: store.playback)
                HStack {
                    Button("设 A：第 \(store.selectionA + 1) 帧") { store.setA() }
                    Button("设 B：第 \(store.selectionB + 1) 帧") { store.setB() }
                    Spacer(minLength: 0)
                    Text("第 \(store.selectionA + 1)–\(store.selectionB + 1) 帧").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text("A 是起点，B 是终点。把播放头移到要截的位置再设点，然后收入动作库。识别结果仍留在这条视频上。").font(.caption).foregroundStyle(.secondary)
                Text("可用骨架：该帧为单人，且至少 6 个身体关节置信度 ≥ 0.2。这是捕捉完整性提示，不是动作评分。模型保留完整二维坐标、置信度与原始 PTS；最后一帧使用剩余视频时长，否则延用相邻帧间隔。").font(.caption2).foregroundStyle(.secondary)
            } else {
                ContentUnavailableView("这段视频还没有动作", systemImage: "figure.dance", description: Text("开始肢体识别后，骨架会显示在这条视频上。"))
            }
            if let error = store.errorMessage { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        }
        .onAppear { modelName = store.selected?.name ?? "" }
        .onChange(of: store.selected?.id) { _, _ in modelName = store.selected?.name ?? "" }
    }
    private func exportModel() {
        store.rename(modelName)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "hidan-motion.json"
        panel.message = "导出完整二维模型、原始帧与时间戳、捕捉元数据和全部编排。导出不会代替模型库中的保存。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await store.exportSelected(to: url) }
    }
}

/// Frame updates are isolated from the library/editor hierarchy.
struct CapturedMotionPlayerView: View {
    @ObservedObject var playback: CapturedMotionPlayback
    var transparentBackground = false
    private let links: [(String, String)] = [
        ("nose", "neck"), ("nose", "leftEye"), ("leftEye", "leftEar"), ("nose", "rightEye"), ("rightEye", "rightEar"),
        ("neck", "leftShoulder"), ("leftShoulder", "leftElbow"), ("leftElbow", "leftWrist"),
        ("neck", "rightShoulder"), ("rightShoulder", "rightElbow"), ("rightElbow", "rightWrist"),
        ("neck", "root"), ("root", "leftHip"), ("root", "rightHip"), ("leftHip", "rightHip"),
        ("leftHip", "leftKnee"), ("leftKnee", "leftAnkle"), ("rightHip", "rightKnee"), ("rightKnee", "rightAnkle")]
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if !transparentBackground { RoundedRectangle(cornerRadius: 18).fill(Color(red: 0.055, green: 0.065, blue: 0.09)) }
                if playback.model == nil {
                    Text("识别完成后，这里显示这段视频的肢体。").font(.callout).foregroundStyle(transparentBackground ? Color.primary : Color.white.opacity(0.8))
                } else {
                Canvas { context, size in
                    guard let frame = playback.currentFrame else { return }
                    let ratio = playback.imageAspectRatio
                    let mirrored = playback.mirrored
                    let width = max(0, min(size.width - 24, (size.height - 24) * ratio)), height = width / ratio
                    let left = (size.width - width) / 2, top = (size.height - height) / 2
                    func point(_ joint: PoseJoint) -> CGPoint { CGPoint(x: left + (mirrored ? 1 - joint.x : joint.x) * width, y: top + (1 - joint.y) * height) }
                    for (a, b) in links {
                        guard let first = frame.joints[a], let second = frame.joints[b], first.confidence > 0, second.confidence > 0 else { continue }
                        var path = Path(); path.move(to: point(first)); path.addLine(to: point(second))
                        context.stroke(path, with: .color(Color.mint.opacity(max(0.15, min(first.confidence, second.confidence)))), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    }
                    for (name, joint) in frame.joints where joint.confidence > 0 {
                        let p = point(joint)
                        context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color((name.hasPrefix("right") ? Color.purple : Color.mint).opacity(max(0.15, joint.confidence))))
                    }
                }.clipped()
                if playback.currentFrame?.hasDetectedBody != true {
                    Text(playback.currentFrame?.ambiguous == true ? "多人画面 · 本帧未选择骨架" : "本帧未捕捉到有效骨架").font(.caption).foregroundStyle(transparentBackground ? Color.primary : Color.white.opacity(0.8))
                }
                VStack {
                    HStack { Text("2D 动作模型").font(.caption.weight(.medium)); Spacer(); Text("\(playback.frameIndex + 1) / \(playback.frameCount)").font(.caption.monospacedDigit()) }
                    Spacer()
                    if let frame = playback.currentFrame { HStack { Text("PTS \(frame.timestampValue)/\(frame.timestampTimescale)").font(.caption2.monospaced()); Spacer() } }
                }.foregroundStyle(transparentBackground ? Color.primary : Color.white.opacity(0.72)).padding(16)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.accessibilityLabel("二维动作模型，保留视频原始时间戳；不包含真实深度。")
    }
}

struct CapturedMotionPreviewControls: View {
    @ObservedObject var playback: CapturedMotionPlayback
    var practice: (() -> Void)? = nil
    var canPractice = true
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button(action: playback.toggle) { Label(playback.isPlaying ? "暂停" : "播放动作", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!playback.hasPlayableMotion)
                if let practice {
                    Button("开始练习", action: practice).buttonStyle(.borderedProminent)
                        .disabled(!canPractice || !playback.hasPlayableMotion)
                }
                Button("上一帧") { playback.step(-1) }; Button("下一帧") { playback.step(1) }
                Spacer(minLength: 0)
            }
            HStack {
                Toggle("循环", isOn: $playback.loop).toggleStyle(.checkbox)
                Toggle("镜像", isOn: $playback.mirrored).toggleStyle(.checkbox)
                Spacer(minLength: 0)
                Picker("速度", selection: $playback.speed) { Text("0.25×").tag(0.25); Text("0.5×").tag(0.5); Text("0.75×").tag(0.75); Text("1×").tag(1.0) }.frame(width: 120)
            }
            Slider(value: Binding(get: { Double(playback.frameIndex) }, set: { playback.seek(Int($0)) }), in: 0...Double(max(1, playback.frameCount - 1)), step: 1).disabled(playback.frameCount < 2)
            Text(String(format: "%.2f / %.2f 秒", playback.elapsed, playback.planDuration))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
