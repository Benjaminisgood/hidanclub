import SwiftUI

struct ClippedMotionDetail: View {
    let model: CapturedMotion
    var onBack: () -> Void
    var onPractice: () -> Void
    var canPractice: Bool
    @StateObject private var playback = CapturedMotionPlayback()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    PlayerIconButton(title: "全部动作", symbol: "chevron.left", action: onBack)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name).font(.title3.weight(.semibold)).lineLimit(1)
                        Text("从视频截出的二维动作 · \(String(format: "%.1f", model.segments.first.map { model.duration(of: $0) } ?? 0)) 秒")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button("开始练习", systemImage: "figure.dance", action: onPractice)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canPractice)
                }
                CapturedMotionPlayerView(playback: playback).frame(height: 320)
                CapturedMotionPreviewControls(playback: playback)
                if !canPractice { Text("先结束当前练习，再练这一段。").font(.caption).foregroundStyle(.secondary) }
                Text(model.qualityNotice).font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
        .onAppear { playback.prepare(model) }
        .onDisappear { playback.pause() }
    }
}

struct ClippedPoseThumbnail: View {
    let model: CapturedMotion
    private let links: [(String, String)] = [
        ("nose", "neck"), ("nose", "leftEye"), ("leftEye", "leftEar"), ("nose", "rightEye"), ("rightEye", "rightEar"),
        ("neck", "leftShoulder"), ("leftShoulder", "leftElbow"), ("leftElbow", "leftWrist"),
        ("neck", "rightShoulder"), ("rightShoulder", "rightElbow"), ("rightElbow", "rightWrist"),
        ("neck", "root"), ("root", "leftHip"), ("root", "rightHip"), ("leftHip", "rightHip"),
        ("leftHip", "leftKnee"), ("leftKnee", "leftAnkle"), ("rightHip", "rightKnee"), ("rightKnee", "rightAnkle")
    ]

    var body: some View {
        Canvas { context, size in
            guard let segment = model.segments.first,
                  model.report.frames.indices.contains(segment.startFrame),
                  model.report.frames.indices.contains(segment.endFrame) else { return }
            let frame = model.report.frames[(segment.startFrame + segment.endFrame) / 2]
            let ratio = CGFloat(model.imageAspectRatio)
            let width = max(0, min(size.width - 16, (size.height - 16) * ratio))
            let height = width / max(ratio, 0.01)
            let left = (size.width - width) / 2
            let top = (size.height - height) / 2
            func point(_ joint: PoseJoint) -> CGPoint {
                CGPoint(x: left + joint.x * width, y: top + (1 - joint.y) * height)
            }
            for (a, b) in links {
                guard let first = frame.joints[a], let second = frame.joints[b], first.confidence > 0, second.confidence > 0 else { continue }
                var path = Path()
                path.move(to: point(first))
                path.addLine(to: point(second))
                context.stroke(path, with: .color(Color.mint.opacity(0.9)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            for (name, joint) in frame.joints where joint.confidence > 0 {
                let center = point(joint)
                let rect = CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)
                context.fill(Path(ellipseIn: rect), with: .color(name.hasPrefix("right") ? Color.purple : Color.mint))
            }
        }
        .background(Color(red: 0.055, green: 0.064, blue: 0.095))
        .accessibilityLabel("肢体预览")
    }
}
