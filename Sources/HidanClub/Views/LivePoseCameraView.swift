import AppKit
import HidanCore
import SwiftUI

/// The training host can place a reference-pose overlay above this surface.
/// Its imageRect helper exposes the exact aspect-fit rectangle used by both
/// the captured image and the same-frame Vision skeleton.
@MainActor struct LivePoseCameraSurface: View {
    @ObservedObject var camera: LivePoseCamera
    @ObservedObject private var frames: LivePoseCameraFrames
    init(camera: LivePoseCamera) { self.camera = camera; self.frames = camera.frames }

    static func imageRect(in size: CGSize, aspectRatio: CGFloat) -> CGRect {
        guard size.width > 0, size.height > 0, aspectRatio.isFinite, aspectRatio > 0 else { return .zero }
        let width = min(size.width, size.height * aspectRatio)
        let height = width / aspectRatio
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    var body: some View {
        GeometryReader { proxy in
            let rect = Self.imageRect(in: proxy.size, aspectRatio: camera.aspectRatio)
            ZStack {
                Color(red: 0.045, green: 0.055, blue: 0.075)
                if let snapshot = camera.snapshot, let image = snapshot.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .scaleEffect(x: camera.mirrored ? -1 : 1, y: 1)
                        .position(x: rect.midX, y: rect.midY)
                    LivePoseCameraSkeleton(observation: snapshot.observation, mirrored: camera.mirrored, imageRect: rect)
                    VStack {
                        HStack(spacing: 6) {
                            Circle().fill(camera.isRecording ? Color.red : Color.green).frame(width: 6, height: 6)
                            Text(camera.isRecording ? "正在录制" : "实时关节检测")
                                .font(.system(size: 10, weight: .medium))
                            Spacer()
                        }
                        Spacer()
                        if let feedback = camera.feedback {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feedback.headline + " · " + feedback.guidance)
                                    .font(.system(size: 10, weight: .medium)).lineLimit(1)
                                Text("肘  L \(compactAngle(feedback.leftElbow))  R \(compactAngle(feedback.rightElbow))    膝  L \(compactAngle(feedback.leftKnee))  R \(compactAngle(feedback.rightKnee))  ·  二维观察")
                                    .font(.system(size: 10, design: .monospaced)).lineLimit(1)
                                    .foregroundStyle(.white.opacity(0.80))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(.black.opacity(0.57), in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                    .padding(10).foregroundStyle(.white)
                } else {
                    VStack(spacing: 9) {
                        Image(systemName: camera.isBusy ? "camera.aperture" : "person.crop.rectangle")
                            .font(.system(size: 30, weight: .light))
                        Text(camera.statusText).font(.subheadline.weight(.medium))
                        Text(camera.isBusy ? "连接完成后，将显示你的画面与关节。" : "启用后，实时查看自己的关节与入镜情况。")
                            .font(.caption).foregroundStyle(.white.opacity(0.65))
                            .multilineTextAlignment(.center)
                        if !camera.isBusy {
                            Button("启用摄像头", systemImage: "camera.fill") { camera.start() }
                                .buttonStyle(.borderedProminent)
                                .disabled(camera.isFinishingRecording)
                        } else { ProgressView().controlSize(.small) }
                    }
                    .padding(18).foregroundStyle(.white)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityLabel("实时摄像头取景；绿色表示左侧关节，紫色表示右侧关节。")
    }

    private func compactAngle(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))°" } ?? "—"
    }
}

@MainActor struct LivePoseCameraControls: View {
    @ObservedObject var camera: LivePoseCamera
    @ObservedObject private var frames: LivePoseCameraFrames
    init(camera: LivePoseCamera) { self.camera = camera; self.frames = camera.frames }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                if camera.isRunning || camera.isBusy {
                    Button("停用", systemImage: "camera.fill") { camera.stop() }
                } else {
                    Button("启用摄像头", systemImage: "camera") { camera.start() }
                        .disabled(camera.isFinishingRecording)
                }
                Toggle("镜像", isOn: $camera.mirrored).toggleStyle(.switch).controlSize(.small)
                    .fixedSize()
                Spacer(minLength: 0)
                if camera.isRunning {
                    Text("输入 \(Int(camera.statistics.captureFramesPerSecond.rounded())) fps")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
            HStack(spacing: 9) {
                if camera.isFinishingRecording {
                    ProgressView().controlSize(.small)
                    Text("正在保存录像…").font(.caption.weight(.medium))
                } else if camera.isRecording {
                    Button("停止并保存", systemImage: "stop.circle.fill") { camera.stopRecording() }
                        .tint(.red)
                    if camera.recordingState == .starting {
                        ProgressView().controlSize(.small)
                        Text("准备录像…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("录制中", systemImage: "record.circle")
                            .font(.caption.weight(.medium)).foregroundStyle(.red)
                    }
                } else {
                    Button("开始录像", systemImage: "record.circle") { camera.startRecording() }
                        .disabled(!camera.isRunning)
                    Text("保存到视频库").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            if let error = camera.recordingError {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if camera.state == .denied {
                Text("请在系统设置 → 隐私与安全性 → 相机中允许 Hidan Club，然后重新启用。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("打开相机权限设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") { NSWorkspace.shared.open(url) }
                }.controlSize(.small)
            }
            if let feedback = camera.feedback {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: feedback.fullBodyVisible ? "person.fill.checkmark" : "viewfinder")
                        .foregroundStyle(feedback.fullBodyVisible ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(feedback.headline).font(.caption.weight(.semibold))
                        Text(feedback.guidance).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Text("\(feedback.visibleJointCount)/19")
                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    angle("左肘", feedback.leftElbow)
                    angle("右肘", feedback.rightElbow)
                    angle("左膝", feedback.leftKnee)
                    angle("右膝", feedback.rightKnee)
                }
                Text("二维投影角度 · — 表示关节不够清楚 · 不是动作评分")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Text(camera.isBusy ? "等待实时画面…" : "请站在镜头前，让肩、髋、膝和双脚入镜。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if camera.statistics.captured > 0 || camera.statistics.systemDropped > 0 {
                Text("捕获 \(camera.statistics.captured) · 分析 \(camera.statistics.analyzed) · 错误 \(camera.statistics.analysisErrors) · 系统丢帧 \(camera.statistics.systemDropped)")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if camera.statistics.systemDropped > 0 {
                    Text("系统报告输入丢帧；设备当前未能完整跟上相机输入。应用逐帧处理收到的缓冲区。")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("本机肢体检测 · 点击开始录像后保存原画面 · 不收录声音")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func angle(_ title: String, _ value: Double?) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value.map { "\(Int($0.rounded()))°" } ?? "—")
                .font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(maxWidth: .infinity).padding(.vertical, 6)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

@MainActor struct LivePoseCameraView: View {
    @ObservedObject var camera: LivePoseCamera
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("我的实时动作", systemImage: "viewfinder").font(.headline)
                Spacer()
                Text(camera.isRunning ? "LIVE" : "摄像头")
                    .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
            }
            LivePoseCameraSurface(camera: camera).frame(minHeight: 150, maxHeight: .infinity)
            LivePoseCameraControls(camera: camera)
        }
        .padding(14)
    }
}

private struct LivePoseCameraSkeleton: View {
    let observation: LivePoseObservation
    let mirrored: Bool
    let imageRect: CGRect
    private let connections: [(String, String)] = [
        ("nose", "neck"), ("nose", "leftEye"), ("leftEye", "leftEar"),
        ("nose", "rightEye"), ("rightEye", "rightEar"),
        ("neck", "leftShoulder"), ("leftShoulder", "leftElbow"), ("leftElbow", "leftWrist"),
        ("neck", "rightShoulder"), ("rightShoulder", "rightElbow"), ("rightElbow", "rightWrist"),
        ("neck", "root"), ("root", "leftHip"), ("root", "rightHip"),
        ("leftHip", "leftKnee"), ("leftKnee", "leftAnkle"),
        ("rightHip", "rightKnee"), ("rightKnee", "rightAnkle")
    ]
    var body: some View {
        Canvas { context, _ in
            guard observation.bodyCount == 1, observation.error == nil else { return }
            let joints = observation.joints.filter { LivePoseFeedback.isVisible($0.value) }
            func location(_ point: LivePosePoint) -> CGPoint {
                CGPoint(x: imageRect.minX + (mirrored ? 1 - point.x : point.x) * imageRect.width,
                        y: imageRect.minY + (1 - point.y) * imageRect.height)
            }
            func color(_ name: String) -> Color {
                name.hasPrefix("left") ? Color(red: 0.31, green: 1, blue: 0.74) :
                    name.hasPrefix("right") ? Color(red: 0.77, green: 0.64, blue: 1) : .white
            }
            for (start, end) in connections {
                guard let a = joints[start], let b = joints[end] else { continue }
                var path = Path(); path.move(to: location(a)); path.addLine(to: location(b))
                context.stroke(path, with: .color(.black.opacity(0.50)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                context.stroke(path, with: .color(color(end)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            for (name, point) in joints {
                let p = location(point)
                let circle = Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7))
                context.fill(circle, with: .color(color(name)))
                context.stroke(circle, with: .color(.black.opacity(0.45)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
