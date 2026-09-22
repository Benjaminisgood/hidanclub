// Rendering QA at full 800 x 600 output resolution. The selected exact source
// frame is a visual fixture, not a reduced dataset or a motion-processing path.
import AppKit
import CryptoKit
import Foundation
import SceneKit
import simd

private struct OverlayFailure: Error, CustomStringConvertible {
    let description: String
}

@main struct TrainingOverlayProbe {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw OverlayFailure(description: "Use script/qa_training_overlay.sh [dataset] [PNG directory]")
        }
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let manifestBytes = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(AISTManifest.self, from: manifestBytes)
        try manifest.validate()
        guard let sequence = manifest.sequences.first(where: { !$0.ignored && $0.genreCode == "gMH" && $0.isBasic }) else {
            throw OverlayFailure(description: "No basic Hip Hop source sequence installed")
        }
        let motion = try AISTMotion(directory: root, sequence: sequence, optimized: true)
        let digest = SHA256.hash(data: motion.data)
        let frame = motion.frameCount / 2
        let points = motion.joints(at: frame)
        let view = SCNView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let coordinator = AISTSkeletonView.Coordinator()
        coordinator.install(in: view)
        func update(_ style: AISTVisualStyle, transparent: Bool) {
            coordinator.update(joints: points, upAxis: "y", mirrored: false, resetToken: 0,
                               showJointNames: false, style: style, showSkeletonOverlay: false,
                               showReferenceGrid: true, transparentBackground: transparent, in: view)
            SCNTransaction.flush()
        }
        update(.skeleton, transparent: false)
        guard let scene = view.scene, let camera = view.pointOfView,
              let studio = scene.rootNode.childNode(withName: "Figure studio — display only", recursively: true),
              let floor = scene.rootNode.childNode(withName: "Display reference plane — no physical units", recursively: true) else {
            throw OverlayFailure(description: "Production scene incomplete")
        }
        camera.simdPosition += SIMD3<Float>(0.07, 0.05, 0.1)
        let originalCamera = camera.simdTransform
        let nodeIDs = Set(descendants(scene.rootNode).map(ObjectIdentifier.init))
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message); print("FAIL: \(message)") }
        }
        for style in [AISTVisualStyle.skeleton, .porcelain, .neon] {
            update(style, transparent: false)
            let normal = try Raster(view.snapshot())
            try normal.save(output.appendingPathComponent("\(style.rawValue)-normal.png"))
            expect(normal.transparentFraction < 0.001, "\(style.rawValue) normal background must be opaque")

            update(style, transparent: true)
            let transparent = try Raster(view.snapshot())
            try transparent.save(output.appendingPathComponent("\(style.rawValue)-transparent.png"))
            try transparent.composited().save(output.appendingPathComponent("\(style.rawValue)-composite.png"))
            let stats = transparent.figureStats
            print("\(style.rawValue): clear=\(transparent.transparentFraction), solid figure=\(stats.count), mean/max channel=\(stats.mean)/\(stats.max), corners=\(transparent.cornerAlphas)")
            expect(transparent.transparentFraction > 0.75, "\(style.rawValue) overlay blocks the camera with an opaque background/surface")
            expect(transparent.cornerAlphas.allSatisfy { $0 == 0 }, "\(style.rawValue) overlay corners are not actually transparent")
            expect(stats.count > 500, "\(style.rawValue) overlay figure is absent or effectively invisible")
            expect(stats.mean > 0.13 && stats.max > 0.4, "\(style.rawValue) overlay figure has lost its illumination")
            expect(!effectivelyVisible(floor), "\(style.rawValue) overlay retained original floor")
            expect(studio.childNodes.filter { $0.light == nil }.allSatisfy { !effectivelyVisible($0) }, "\(style.rawValue) overlay retained studio surface/grid")
            if style != .skeleton {
                expect(studio.childNodes.contains { $0.light != nil && effectivelyVisible($0) }, "\(style.rawValue) overlay hid studio lights")
            }

            update(style, transparent: false)
            let restored = try Raster(view.snapshot())
            try restored.save(output.appendingPathComponent("\(style.rawValue)-restored.png"))
            expect(restored.transparentFraction < 0.001, "\(style.rawValue) normal background did not restore")
            // SceneKit's shadow antialiasing can change a few integer pixels
            // between snapshots despite identical scene state.
            let difference = normal.difference(from: restored)
            print("\(style.rawValue) restored RGBA difference: mean=\(difference.mean), max=\(difference.max)")
            expect(difference.mean < 0.2 && difference.max <= 8, "\(style.rawValue) normal rendering differs materially after transparent roundtrip")
            expect(scene.fogEndDistance > scene.fogStartDistance && scene.fogEndDistance > 0, "\(style.rawValue) normal fog did not restore")
            expect(style == .skeleton ? effectivelyVisible(floor) : studio.childNodes.filter { $0.light == nil }.allSatisfy(effectivelyVisible), "\(style.rawValue) normal stage/grid did not restore")
            expect(camera.simdTransform == originalCamera, "\(style.rawValue) transparent/style toggle changed camera")
            expect(Set(descendants(scene.rootNode).map(ObjectIdentifier.init)) == nodeIDs, "\(style.rawValue) toggles accumulated or replaced scene nodes")
        }
        expect(SHA256.hash(data: motion.data) == digest, "Renderer mutated source in memory")
        expect(SHA256.hash(data: try Data(contentsOf: sequence.motionURL(in: root, optimized: true))) == digest, "Renderer mutated source file")
        expect(try Data(contentsOf: root.appendingPathComponent("manifest.json")) == manifestBytes, "Renderer mutated manifest")
        print("Visual fixture: \(sequence.id), exact frame \(frame) of \(motion.frameCount). PNGs: \(output.path)")
        if !failures.isEmpty { fflush(stdout); exit(1) }
        print("TRAINING OVERLAY QA PASSED: three genuinely transparent, illuminated styles; normal surfaces/background restored; camera and nodes stable; source hashes unchanged.")
    }

    private static func descendants(_ node: SCNNode) -> [SCNNode] {
        [node] + node.childNodes.flatMap(descendants)
    }
    private static func effectivelyVisible(_ node: SCNNode) -> Bool {
        !node.isHidden && node.opacity > 0 && (node.parent.map(effectivelyVisible) ?? true)
    }

    private struct Raster {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init(_ image: NSImage) throws {
            var rect = NSRect(origin: .zero, size: image.size)
            guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
                throw OverlayFailure(description: "SceneKit snapshot produced no image")
            }
            let pixelWidth = source.width, pixelHeight = source.height
            width = pixelWidth; height = pixelHeight
            var storage = [UInt8](repeating: 0, count: width * height * 4)
            let rendered = storage.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(data: raw.baseAddress, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                              bytesPerRow: pixelWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(source, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
                return true
            }
            guard rendered else { throw OverlayFailure(description: "Cannot normalize snapshot RGBA pixels") }
            bytes = storage
        }
        private init(width: Int, height: Int, bytes: [UInt8]) {
            self.width = width; self.height = height; self.bytes = bytes
        }
        var transparentFraction: Double {
            Double(stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] == 0 }.count) / Double(width * height)
        }
        var cornerAlphas: [UInt8] {
            [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)].map { bytes[($0.1 * width + $0.0) * 4 + 3] }
        }
        var figureStats: (count: Int, mean: Double, max: Double) {
            var count = 0; var total = 0.0; var brightest = 0.0
            for index in stride(from: 0, to: bytes.count, by: 4) where bytes[index + 3] >= 230 {
                count += 1
                let maximum = Double(max(bytes[index], bytes[index + 1], bytes[index + 2])) / 255
                total += maximum; brightest = max(brightest, maximum)
            }
            return (count, count > 0 ? total / Double(count) : 0, brightest)
        }
        func difference(from other: Raster) -> (mean: Double, max: Int) {
            guard width == other.width, height == other.height else { return (.infinity, 255) }
            var total = 0; var maximum = 0
            for (first, second) in zip(bytes, other.bytes) {
                let difference = abs(Int(first) - Int(second))
                total += difference; maximum = max(maximum, difference)
            }
            return (Double(total) / Double(bytes.count), maximum)
        }
        func composited() -> Raster {
            var result = bytes
            for y in 0..<height {
                for x in 0..<width {
                    let index = (y * width + x) * 4
                    let light = ((x / 50) + (y / 50)) % 2 == 0
                    let background = light ? [210.0, 230.0, 235.0] : [66.0, 77.0, 89.0]
                    let alpha = Double(bytes[index + 3]) / 255
                    for channel in 0..<3 {
                        result[index + channel] = UInt8(min(255, Double(bytes[index + channel]) + background[channel] * (1 - alpha)))
                    }
                    result[index + 3] = 255
                }
            }
            return Raster(width: width, height: height, bytes: result)
        }
        func save(_ url: URL) throws {
            let provider = CGDataProvider(data: Data(bytes) as CFData)!
            guard let cgImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
                throw OverlayFailure(description: "Cannot encode PNG")
            }
            try png.write(to: url)
        }
    }
}
