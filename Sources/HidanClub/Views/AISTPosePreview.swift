import Foundation
import HidanCore
import SwiftUI
import simd

/// Visible gallery cards autoplay the raw layer. Both coordinate files must exist
/// before a card is allowed to play; the opened action uses the other layer.
@MainActor final class AISTGalleryPlayback: ObservableObject {
    @Published private(set) var joints: [String: [SIMD3<Double>]] = [:]
    private var motions: [String: AISTMotion] = [:]
    private var cursors: [String: Int] = [:]
    private var pins: [String: Int] = [:]
    private var pinned: [String: AISTSequence] = [:]
    private var directory: URL?
    private var timer: Timer?
    private var generation = 0

    func use(directory: URL, reload: Bool = false) {
        let changed = self.directory != directory
        guard changed || reload else { return }
        let hadDirectory = self.directory != nil
        self.directory = directory
        guard hadDirectory || reload else { return }
        generation += 1
        timer?.invalidate()
        timer = nil
        motions = [:]
        cursors = [:]
        joints = [:]
        for sequence in pinned.values { load(sequence) }
    }

    func pin(_ sequence: AISTSequence) {
        pins[sequence.id, default: 0] += 1
        pinned[sequence.id] = sequence
        load(sequence)
    }

    private func load(_ sequence: AISTSequence) {
        guard motions[sequence.id] == nil, let directory else { return }
        let generation = generation
        let id = sequence.id
        Task {
            let loaded = try? await Task.detached {
                try sequence.requireBothCoordinateFiles(in: directory)
                return try AISTMotion(directory: directory, sequence: sequence, optimized: false)
            }.value
            guard generation == self.generation, pins[id, default: 0] > 0, motions[id] == nil, let loaded else { return }
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
        pinned[id] = nil
        motions[id] = nil
        cursors[id] = nil
        joints[id] = nil
        if motions.isEmpty { timer?.invalidate(); timer = nil }
    }

    func stop() {
        generation += 1
        timer?.invalidate()
        timer = nil
        motions = [:]
        cursors = [:]
        pins = [:]
        pinned = [:]
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

struct AISTPoseThumbnail: View {
    var joints: [SIMD3<Double>]
    private static let edges = [
        (15, 13), (13, 11), (16, 14), (14, 12), (11, 12),
        (5, 11), (6, 12), (5, 6), (5, 7), (6, 8), (7, 9), (8, 10),
        (1, 2), (0, 1), (0, 2), (1, 3), (2, 4), (3, 5), (4, 6)
    ]
    private static let left: Set<Int> = [1, 3, 5, 7, 9, 11, 13, 15]
    private static let right: Set<Int> = [2, 4, 6, 8, 10, 12, 14, 16]

    var body: some View {
        Canvas { context, size in
            let finite = joints.enumerated().compactMap { index, point -> (Int, SIMD2<Double>)? in
                guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { return nil }
                return (index, SIMD2(point.x, point.y))
            }
            guard finite.count >= 2 else { return }
            var low = SIMD2(finite[0].1.x, finite[0].1.y)
            var high = low
            for item in finite.dropFirst() {
                low = simd_min(low, item.1)
                high = simd_max(high, item.1)
            }
            let span = high - low
            let pad: Double = 16
            let available = SIMD2(Double(size.width) - pad * 2, Double(size.height) - pad * 2)
            guard available.x > 8, available.y > 8 else { return }
            let scale = min(available.x / max(span.x, 0.0001), available.y / max(span.y, 0.0001))
            guard scale.isFinite, scale > 0 else { return }
            let fitted = span * scale
            let origin = SIMD2(pad + (available.x - fitted.x) / 2, pad + (available.y - fitted.y) / 2)
            func point(_ value: SIMD2<Double>) -> CGPoint {
                CGPoint(x: origin.x + (value.x - low.x) * scale,
                        y: origin.y + (high.y - value.y) * scale)
            }
            let located = Dictionary(uniqueKeysWithValues: finite.map { ($0.0, point($0.1)) })
            for edge in Self.edges {
                guard let start = located[edge.0], let end = located[edge.1] else { continue }
                var path = Path()
                path.move(to: start)
                path.addLine(to: end)
                context.stroke(path, with: .color(color(for: edge.0, and: edge.1)), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
            }
            for (index, center) in located {
                let radius: CGFloat = index < 5 ? 2.4 : 3.4
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(color(for: index)))
            }
        }
        .background(Color(red: 0.055, green: 0.064, blue: 0.095))
        .accessibilityLabel("肢体预览")
    }

    private func color(for index: Int) -> Color {
        if Self.left.contains(index) { return Color(red: 0.39, green: 0.91, blue: 0.76) }
        if Self.right.contains(index) { return Color(red: 0.65, green: 0.65, blue: 1) }
        return Color(red: 0.88, green: 0.90, blue: 0.96)
    }

    private func color(for start: Int, and end: Int) -> Color {
        if Self.left.contains(start), Self.left.contains(end) { return color(for: start) }
        if Self.right.contains(start), Self.right.contains(end) { return color(for: start) }
        return color(for: 0)
    }
}
