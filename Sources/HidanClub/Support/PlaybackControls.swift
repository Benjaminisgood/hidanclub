import SwiftUI

/// Native controls retain keyboard focus, disabled states and system appearance.
struct CircularPlayButton: View {
    var playing: Bool
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .accessibilityLabel(playing ? "暂停" : "播放")
        .help(help)
    }
}

struct PlayerIconButton: View {
    let title: String
    let symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
                .frame(minWidth: 18, minHeight: 18)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(title)
        .help(title)
    }
}

struct PlayerToggle: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) { Label(title, systemImage: symbol) }
            .toggleStyle(.button)
            .tint(ClubTheme.accent)
            .accessibilityValue(isOn ? "已开启" : "已关闭")
            .help(title + (isOn ? "：已开启" : "：已关闭"))
    }
}

/// Material tray under a picture: 16 pt corners, 18 pt inset, regular native controls.
struct PlayerControlCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ClubTheme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: ClubTheme.cornerRadius).strokeBorder(.primary.opacity(0.08)))
    }
}

struct PlaybackTimeline: View {
    @Binding var value: Double
    let upperBound: Double
    var step: Double = 1
    let elapsed: String
    let total: String
    let label: String
    var detail: String? = nil

    var body: some View {
        VStack(spacing: 4) {
            // Quantize in the binding, not Slider's step parameter: macOS draws
            // one tick per step, which becomes a solid bar on long timelines.
            Slider(value: Binding(get: { value }, set: { value = min(upperBound, ($0 / step).rounded() * step) }),
                   in: 0...max(upperBound, step))
                .disabled(upperBound <= 0)
                .accessibilityLabel(label)
            HStack {
                Text(elapsed)
                Spacer(minLength: 8)
                if let detail { Text(detail).lineLimit(1) }
                Spacer(minLength: 8)
                Text(total)
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

/// Wrap controls at their natural widths, without shrinking labels or hit areas.
/// This is a SwiftUI Layout; each child remains its original native control.
struct ControlFlow: Layout {
    var spacing: CGFloat = 8

    private func arrangement(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = []
        var heights: [CGFloat] = []
        var rowStart = 0
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        func centerRow() {
            for index in rowStart..<points.count { points[index].y += (rowHeight - heights[index]) / 2 }
        }
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                centerRow()
                rowStart = points.count
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            heights.append(size.height)
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        centerRow()
        return (points, CGSize(width: usedWidth, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let layout = arrangement(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? layout.size.width, height: layout.size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrangement(subviews, width: bounds.width)
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX + layout.points[index].x, y: bounds.minY + layout.points[index].y),
                       anchor: .topLeading, proposal: .unspecified)
        }
    }
}

func playbackTime(_ seconds: Double) -> String {
    let value = seconds.isFinite ? max(0, seconds) : 0
    let whole = Int(value)
    return String(format: "%02d:%02d.%01d", whole / 60, whole % 60, Int(value * 10) % 10)
}
