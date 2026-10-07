import Combine
import SwiftUI
import HidanCore

/// 2D COCO-17 skeleton player built on HidanCore's built-in practice motions.
/// The macOS app renders the same data in SceneKit; on iOS we draw a flat
/// front-view projection with SwiftUI Canvas so no dataset files are needed.
struct SkeletonCanvasView: View {
    let frames: [[SIMD3<Double>]]
    var fps: Double = 60
    var speed: Double = 1
    @State private var frameIndex = 0

    private static let edges: [(Int, Int)] = [
        (15, 13), (13, 11), (16, 14), (14, 12), (11, 12),
        (5, 11), (6, 12), (5, 6), (5, 7), (6, 8), (7, 9), (8, 10),
        (1, 2), (0, 1), (0, 2), (1, 3), (2, 4), (3, 5), (4, 6)
    ]

    var body: some View {
        Canvas { context, size in
            guard !frames.isEmpty else { return }
            let joints = frames[frameIndex % frames.count]
            let scale = min(size.width / 150, size.height / 210)
            func point(_ joint: SIMD3<Double>) -> CGPoint? {
                guard joint.x.isFinite, joint.y.isFinite else { return nil }
                return CGPoint(x: size.width / 2 + CGFloat(joint.x) * scale,
                               y: size.height - 8 - CGFloat(joint.y) * scale)
            }
            for (a, b) in Self.edges {
                guard let pa = point(joints[a]), let pb = point(joints[b]) else { continue }
                var path = Path()
                path.move(to: pa)
                path.addLine(to: pb)
                context.stroke(path, with: .color(.white.opacity(0.75)),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            for joint in joints {
                guard let p = point(joint) else { continue }
                context.fill(Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)),
                             with: .color(ClubThemeIOS.lime))
            }
        }
        .background(ClubThemeIOS.stage, in: RoundedRectangle(cornerRadius: ClubThemeIOS.cornerRadius))
        .onReceive(timer) { _ in advance() }
    }

    private var timer: Publishers.Autoconnect<Timer.TimerPublisher> {
        Timer.publish(every: 1.0 / max(1, fps * speed), on: .main, in: .common).autoconnect()
    }

    private func advance() {
        guard !frames.isEmpty else { return }
        frameIndex = (frameIndex + 1) % frames.count
    }

    /// Builds the built-in demo motion for a catalog move (optimized layer).
    static func frames(for move: DanceMove) -> [[SIMD3<Double>]] {
        PracticeMotionLibrary.makePair(for: move).optimized
    }
}
