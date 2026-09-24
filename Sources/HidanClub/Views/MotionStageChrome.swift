import SwiftUI

/// Shared motion picture for the action library and fundamentals.
/// Playback controls stay in the bar under the picture, not on top of it.
struct MotionStageChrome: View {
    var joints: [SIMD3<Double>]
    var upAxis: String
    var mirrored: Bool
    var resetToken: Int
    var loading: Bool
    var identity: String
    var visualStyle: AISTVisualStyle
    var showJointNames: Bool
    var showSkeletonOverlay: Bool
    var showReferenceGrid: Bool

    var body: some View {
        ZStack {
            AISTSkeletonView(joints: joints, upAxis: upAxis, mirrored: mirrored,
                             resetToken: resetToken, showJointNames: showJointNames,
                             style: visualStyle, showSkeletonOverlay: showSkeletonOverlay,
                             showReferenceGrid: showReferenceGrid)
                .id(identity)
                .frame(height: 360)
                .accessibilityLabel("\(visualStyle.title)，可拖动旋转，滚动缩放")
            if loading { ProgressView() }
            if !loading && visibleJoints < 17 {
                VStack {
                    Spacer()
                    Label("当前帧 \(visibleJoints) / 17 个关节可见", systemImage: "info.circle")
                        .font(.caption2).padding(8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(14)
                }.allowsHitTesting(false)
            }
        }.clipShape(RoundedRectangle(cornerRadius: ClubTheme.cornerRadius))
    }

    private var visibleJoints: Int {
        joints.filter { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }.count
    }
}

struct MotionPlaybackReader<Content: View>: View {
    @ObservedObject var playback: AISTPlaybackState
    @ViewBuilder var content: () -> Content
    var body: some View { content() }
}
