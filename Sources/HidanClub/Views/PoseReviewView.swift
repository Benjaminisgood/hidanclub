import SwiftUI

/// Reviews every stored frame. The square plot shows normalized coordinates only;
/// it does not assume the original video's aspect ratio or superimpose a skeleton.
struct PoseReviewView: View {
    let report: PoseReport
    @State private var frameIndex: Double = 0
    @State private var showsJointValues = false

    private var selectedIndex: Int {
        min(max(Int(frameIndex.rounded()), 0), max(report.frames.count - 1, 0))
    }

    private var selectedFrame: PoseFrame? {
        guard !report.frames.isEmpty else { return nil }
        return report.frames[selectedIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
            HStack {
                Label("逐帧骨架观察", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Spacer()
                Text("全部 \(report.frames.count) 帧")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }

            if let frame = selectedFrame {
                frameControls(frame)
                HStack(alignment: .top, spacing: 24) {
                    PoseSkeletonCanvas(frame: frame)
                        .frame(width: 250, height: 250)
                    frameDetails(frame)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("方形归一化坐标图 · 未还原视频宽高比，不是视频叠加。用于检查关键点检测，不用于判断体型或舞蹈质量。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("关键点数值（\(frame.joints.count)）", isExpanded: $showsJointValues) {
                    jointValues(frame)
                        .padding(.top, 8)
                }
                .font(.caption)
            } else {
                Text("这份报告没有可供观察的帧。")
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: report.createdAt) { _, _ in frameIndex = 0 }
        .onChange(of: report.frames.count) { _, _ in frameIndex = 0 }
    }

    private func frameControls(_ frame: PoseFrame) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    frameIndex = Double(max(selectedIndex - 1, 0))
                } label: {
                    Image(systemName: "backward.frame")
                }
                .disabled(selectedIndex == 0)
                .help("上一帧").accessibilityLabel("上一帧")

                Slider(
                    value: Binding(
                        get: { Double(selectedIndex) },
                        set: { frameIndex = $0.rounded() }
                    ),
                    in: 0...Double(max(report.frames.count - 1, 1)),
                    step: 1
                )
                .disabled(report.frames.count <= 1)
                .accessibilityLabel("选择原始帧")
                .accessibilityValue("第 \(selectedIndex + 1) 帧，共 \(report.frames.count) 帧")

                Button {
                    frameIndex = Double(min(selectedIndex + 1, report.frames.count - 1))
                } label: {
                    Image(systemName: "forward.frame")
                }
                .disabled(selectedIndex >= report.frames.count - 1)
                .help("下一帧").accessibilityLabel("下一帧")
            }
            HStack {
                Text("第 \(selectedIndex + 1) / \(report.frames.count) 帧")
                Spacer()
                Text("PTS \(String(format: "%.6f", frame.timestamp)) s")
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func frameDetails(_ frame: PoseFrame) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(statusText(frame), systemImage: frame.hasDetectedBody ? "person.fill.checkmark" : "info.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(frame.ambiguous ? Color.orange : Color.primary)
            LabeledContent("检测到人体", value: "\(frame.bodyCount)")
            LabeledContent("有效关键点", value: "\(frame.joints.values.filter { $0.confidence > 0 }.count) / \(frame.joints.count)")
            LabeledContent("原始时间戳", value: "\(frame.timestampValue) / \(frame.timestampTimescale)")
            Text("点和连线的透明度反映检测置信度。零置信度的点保留在数据中，不绘制。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("检测覆盖率只表示有单人有效关键点的帧占比，不表示所有关节均可见，也不表示动作完成度。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption).monospacedDigit()
    }

    private func jointValues(_ frame: PoseFrame) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if frame.joints.isEmpty {
                Text(frame.ambiguous ? "本帧包含多个人体，未选择任何人的骨架。" : "本帧没有人体关键点，原始帧和时间戳仍保留。")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 7) {
                        GridRow {
                            Text("关键点")
                            Text("x")
                            Text("y")
                            Text("置信度")
                        }
                        .foregroundStyle(.secondary)
                        ForEach(frame.joints.keys.sorted(), id: \.self) { key in
                            if let point = frame.joints[key] {
                                GridRow {
                                    Text(key).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(String(format: "%.4f", point.x))
                                    Text(String(format: "%.4f", point.y))
                                    Text(String(format: "%.4f", point.confidence))
                                }
                                .foregroundStyle(point.confidence > 0 ? Color.primary : Color.secondary)
                            }
                        }
                    }
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.trailing, 8)
                }
                .frame(height: min(190, CGFloat(frame.joints.count + 1) * 23))
                Text("表格仅格式化显示；JSON 导出保留原始坐标与置信度。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusText(_ frame: PoseFrame) -> String {
        if frame.ambiguous { return "多人画面 · 已跳过骨架" }
        if frame.bodyCount == 0 { return "未检测到人体" }
        if !frame.hasDetectedBody { return "单人 · 无有效关键点" }
        return "单人关键点"
    }
}

private struct PoseSkeletonCanvas: View {
    let frame: PoseFrame

    private let connections: [(String, String)] = [
        ("nose", "neck"),
        ("nose", "leftEye"), ("leftEye", "leftEar"),
        ("nose", "rightEye"), ("rightEye", "rightEar"),
        ("neck", "leftShoulder"), ("leftShoulder", "leftElbow"), ("leftElbow", "leftWrist"),
        ("neck", "rightShoulder"), ("rightShoulder", "rightElbow"), ("rightElbow", "rightWrist"),
        ("neck", "root"), ("root", "leftHip"), ("root", "rightHip"),
        ("leftHip", "leftKnee"), ("leftKnee", "leftAnkle"),
        ("rightHip", "rightKnee"), ("rightKnee", "rightAnkle")
    ]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.035))
            Canvas { context, size in
                let side = min(size.width, size.height) - 28
                let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
                var grid = Path()
                for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
                    let offset = side * fraction
                    grid.move(to: CGPoint(x: origin.x + offset, y: origin.y))
                    grid.addLine(to: CGPoint(x: origin.x + offset, y: origin.y + side))
                    grid.move(to: CGPoint(x: origin.x, y: origin.y + offset))
                    grid.addLine(to: CGPoint(x: origin.x + side, y: origin.y + offset))
                }
                context.stroke(grid, with: .color(.secondary.opacity(0.14)), lineWidth: 0.7)

                func location(_ joint: PoseJoint) -> CGPoint {
                    CGPoint(x: origin.x + joint.x * side, y: origin.y + (1 - joint.y) * side)
                }

                for (startName, endName) in connections {
                    guard let start = frame.joints[startName], let end = frame.joints[endName],
                          start.confidence > 0, end.confidence > 0 else { continue }
                    var path = Path()
                    path.move(to: location(start))
                    path.addLine(to: location(end))
                    let opacity = min(max(min(start.confidence, end.confidence), 0), 1)
                    context.stroke(path, with: .color(.accentColor.opacity(opacity)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                }
                for joint in frame.joints.values where joint.confidence > 0 {
                    let point = location(joint)
                    let mark = CGRect(x: point.x - 3.1, y: point.y - 3.1, width: 6.2, height: 6.2)
                    let opacity = min(max(joint.confidence, 0), 1)
                    context.fill(Path(ellipseIn: mark), with: .color(.accentColor.opacity(opacity)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)

            if !frame.hasDetectedBody {
                VStack(spacing: 9) {
                    Image(systemName: frame.ambiguous ? "person.2" : "person.crop.rectangle")
                        .font(.system(size: 28, weight: .light))
                    Text(frame.ambiguous ? "多人 · 不选择骨架" : "本帧无有效骨架")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
