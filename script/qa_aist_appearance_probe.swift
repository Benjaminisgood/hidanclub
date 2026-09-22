// A behavioral probe of production SceneKit objects. It opens no window and
// does not write source data. Visual inspection remains a separate acceptance.
import AppKit
import CryptoKit
import Foundation
import SceneKit
import simd

private struct AppearanceFailure: Error, CustomStringConvertible {
    let description: String
}

@main struct AISTAppearanceProbe {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw AppearanceFailure(description: "Run via script/qa_aist_appearance.sh [dataset directory]")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let manifestURL = root.appendingPathComponent("manifest.json")
        let manifestBytes = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(AISTManifest.self, from: manifestBytes)
        try manifest.validate()
        let representatives = try ["gMH", "gHO", "gBR"].map { genre in
            guard let sequence = manifest.sequences.first(where: { !$0.ignored && $0.genreCode == genre && $0.isBasic }) else {
                throw AppearanceFailure(description: "Missing representative \(genre) source sequence")
            }
            return sequence
        }
        for sequence in representatives {
            let motion = try AISTMotion(directory: root, sequence: sequence, optimized: true)
            let before = digest(motion.data)
            try verifySwitchingAndMissingValues(motion: motion, sequence: sequence)
            try check(digest(motion.data) == before, "Display mutated in-memory source bytes: \(sequence.id)")
            try check(digest(Data(contentsOf: sequence.motionURL(in: root, optimized: true))) == before, "Display modified source file: \(sequence.id)")
        }
        guard let fullSequence = manifest.sequences.filter({ !$0.ignored && $0.genreCode == "gBR" && !$0.isBasic }).max(by: { $0.frameCount < $1.frameCount }) else {
            throw AppearanceFailure(description: "No full Break sequence available")
        }
        let fullMotion = try AISTMotion(directory: root, sequence: fullSequence, optimized: false)
        let fullBefore = digest(fullMotion.data)
        try verifyEveryFrame(motion: fullMotion, sequence: fullSequence)
        try check(digest(fullMotion.data) == fullBefore, "Full-sequence display mutated in-memory data")
        try check(digest(Data(contentsOf: fullSequence.motionURL(in: root, optimized: false))) == fullBefore, "Full-sequence display modified dataset file")
        try check(Data(contentsOf: manifestURL) == manifestBytes, "Display modified source manifest")
        print("APPEARANCE QA PASSED: three styles; first/middle/final poses across three genres; original 17 joints/19 edges; camera and fixed display coordinates retained; overlays and missing-joint recovery; no node accumulation; every frame of \(fullSequence.id) (\(fullSequence.frameCount) frames per style) has finite transforms; source hashes unchanged.")
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw AppearanceFailure(description: message) }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor private final class Fixture {
        let view = SCNView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let coordinator = AISTSkeletonView.Coordinator()
        let nodes: [SCNNode]
        let identifiers: Set<ObjectIdentifier>
        let joints: [SCNNode]
        let bones: [SCNNode]
        let avatar: SCNNode
        let studio: SCNNode
        let camera: SCNNode
        let baselineCamera: simd_float4x4
        let baselineTarget: SCNVector3
        let anchorSource: SIMD3<Double>
        let anchorDisplay: SIMD3<Double>
        let scale: Double

        init(points: [SIMD3<Double>]) throws {
            coordinator.install(in: view)
            coordinator.update(joints: points, upAxis: "y", mirrored: false, resetToken: 0,
                               showJointNames: false, style: .skeleton, in: view)
            guard let root = view.scene?.rootNode,
                  let skeleton = root.childNode(withName: "COCO-17 — source joints", recursively: true),
                  let avatar = root.childNode(withName: "AIST stylized avatar", recursively: true),
                  let studio = root.childNode(withName: "Figure studio — display only", recursively: true),
                  let camera = view.pointOfView else {
                throw AppearanceFailure(description: "Expected production scene nodes are unavailable")
            }
            self.avatar = avatar; self.studio = studio; self.camera = camera
            joints = skeleton.childNodes.filter { $0.name?.hasPrefix("joint_") == true }.sorted {
                Int($0.name!.split(separator: "_")[1])! < Int($1.name!.split(separator: "_")[1])!
            }
            bones = skeleton.childNodes.filter { $0.name?.hasPrefix("bone_") == true }
            try check(joints.count == 17 && bones.count == 19, "Classic COCO topology changed")
            nodes = Self.descendants(root)
            identifiers = Set(nodes.map(ObjectIdentifier.init))
            // Simulate a user's orbit/zoom. Source/style updates may not reset it.
            camera.simdPosition += SIMD3<Float>(0.3, 0.2, 0.4)
            camera.simdOrientation = simd_quatf(angle: 0.12, axis: SIMD3<Float>(0, 1, 0)) * camera.simdOrientation
            baselineCamera = camera.simdTransform
            baselineTarget = view.defaultCameraController.target

            let measuredNodes = joints
            let finiteIndices = points.indices.filter { finite(points[$0]) && !measuredNodes[$0].isHidden }
            guard let first = finiteIndices.first,
                  let second = finiteIndices.max(by: { simd_distance(points[first], points[$0]) < simd_distance(points[first], points[$1]) }), first != second else {
                throw AppearanceFailure(description: "Need two distinct finite source points to establish display reference")
            }
            anchorSource = points[first]
            anchorDisplay = SIMD3<Double>(joints[first].simdPosition)
            let displayDistance = simd_distance(SIMD3<Double>(joints[second].simdPosition), anchorDisplay)
            scale = displayDistance / simd_distance(points[second], anchorSource)
            try check(scale.isFinite && scale > 0, "Invalid initial display scale")
        }

        func update(_ points: [SIMD3<Double>], style: AISTVisualStyle, overlay: Bool = false, grid: Bool = false) {
            coordinator.update(joints: points, upAxis: "y", mirrored: false, resetToken: 0,
                               showJointNames: false, style: style, showSkeletonOverlay: overlay,
                               showReferenceGrid: grid, in: view)
        }

        func verifyStableState(points: [SIMD3<Double>], label: String) throws {
            guard let root = view.scene?.rootNode else { throw AppearanceFailure(description: "Scene detached during \(label)") }
            let current = Self.descendants(root)
            try check(current.count == nodes.count && Set(current.map(ObjectIdentifier.init)) == identifiers, "Nodes were added/replaced during \(label)")
            try check(camera.simdTransform == baselineCamera, "Style/source update reset orbit camera during \(label)")
            let target = view.defaultCameraController.target
            try check(target.x == baselineTarget.x && target.y == baselineTarget.y && target.z == baselineTarget.z, "Camera target reset during \(label)")
            for node in current {
                try check(finite(node.simdTransform), "Non-finite transform on \(node.name ?? "unnamed") during \(label)")
            }
            for index in 0..<min(points.count, 17) where finite(points[index]) {
                let expected = anchorDisplay + (points[index] - anchorSource) * scale
                let actual = SIMD3<Double>(joints[index].simdPosition)
                try check(simd_distance(expected, actual) <= max(0.0001, simd_length(expected) * 0.00001), "Source trajectory or fixed normalization changed at joint \(index) during \(label)")
            }
        }

        static func descendants(_ root: SCNNode) -> [SCNNode] {
            [root] + root.childNodes.flatMap { descendants($0) }
        }

        static func visibleGeometry(_ root: SCNNode, parentVisible: Bool = true) -> [SCNNode] {
            let visible = parentVisible && !root.isHidden && root.opacity > 0
            guard visible else { return [] }
            return (root.geometry == nil ? [] : [root]) + root.childNodes.flatMap { visibleGeometry($0, parentVisible: visible) }
        }
    }

    @MainActor private static func verifySwitchingAndMissingValues(motion: AISTMotion, sequence: AISTSequence) throws {
        let first = motion.joints(at: 0)
        try check(first.allSatisfy(finite), "Optimized representative first frame contains missing coordinates")
        let fixture = try Fixture(points: first)
        for frame in [0, motion.frameCount / 2, motion.frameCount - 1] {
            let points = motion.joints(at: frame)
            for style in [AISTVisualStyle.skeleton, .porcelain, .neon, .skeleton] {
                fixture.update(points, style: style)
                try fixture.verifyStableState(points: points, label: "\(sequence.id) frame \(frame) \(style.rawValue)")
                let bodyVisible = Fixture.visibleGeometry(fixture.avatar)
                try check(style == .skeleton ? bodyVisible.isEmpty : !bodyVisible.isEmpty, "Style did not change visible body geometry")
                try check(fixture.studio.isHidden == (style == .skeleton), "Studio visibility differs from selected style")
                let visibleJoints = fixture.joints.filter { !$0.isHidden }.count
                try check(visibleJoints == (style == .skeleton ? 17 : 0), "Classic/overlay joint visibility differs")
                if style != .skeleton {
                    fixture.update(points, style: style, overlay: true, grid: true)
                    try check(fixture.joints.allSatisfy { !$0.isHidden } && fixture.bones.allSatisfy { !$0.isHidden }, "Skeleton overlay did not show 17 joints and 19 edges")
                    try fixture.verifyStableState(points: points, label: "overlay/grid on")
                    guard let gridNode = fixture.studio.childNode(withName: "Optional studio reference grid", recursively: true) else {
                        throw AppearanceFailure(description: "Optional stage grid node missing")
                    }
                    try check(!gridNode.isHidden, "Reference grid toggle did not show grid")
                    fixture.update(points, style: style, overlay: false, grid: false)
                    try check(fixture.joints.allSatisfy(\.isHidden) && fixture.bones.allSatisfy(\.isHidden) && gridNode.isHidden, "Overlay/grid toggles did not hide their nodes")
                }
            }
        }
        // A missing source joint must hide dependent visuals without emitting a
        // NaN transform, and recovering data must bring them back.
        fixture.update(first, style: .porcelain, overlay: true)
        let visibleBodyBefore = Set(Fixture.visibleGeometry(fixture.avatar).map(ObjectIdentifier.init))
        var missing = first
        missing[5] = SIMD3(repeating: Double.nan)
        fixture.update(missing, style: .porcelain, overlay: true)
        try check(fixture.joints[5].isHidden, "Missing shoulder remained visible")
        for bone in fixture.bones where bone.name!.split(separator: "_").dropFirst().contains("5") {
            try check(bone.isHidden, "Bone connected to missing shoulder remained visible")
        }
        try check(Set(Fixture.visibleGeometry(fixture.avatar).map(ObjectIdentifier.init)).count < visibleBodyBefore.count, "Avatar did not hide any dependent geometry for missing shoulder")
        try fixture.verifyStableState(points: missing, label: "one missing shoulder")
        let empty = Array(repeating: SIMD3<Double>(repeating: .nan), count: 17)
        fixture.update(empty, style: .neon, overlay: true)
        try check(fixture.joints.allSatisfy(\.isHidden) && fixture.bones.allSatisfy(\.isHidden), "All-missing source left skeleton visible")
        try check(Fixture.visibleGeometry(fixture.avatar).isEmpty, "All-missing source left body visible")
        try fixture.verifyStableState(points: empty, label: "all coordinates missing")
        fixture.update(first, style: .porcelain, overlay: true)
        try check(fixture.joints.allSatisfy { !$0.isHidden } && fixture.bones.allSatisfy { !$0.isHidden }, "Recovered coordinates did not restore skeleton")
        try check(Set(Fixture.visibleGeometry(fixture.avatar).map(ObjectIdentifier.init)) == visibleBodyBefore, "Recovered coordinates did not restore body geometry")
        try fixture.verifyStableState(points: first, label: "coordinates recovered")
        fixture.coordinator.install(in: fixture.view)
        try fixture.verifyStableState(points: first, label: "idempotent install")
        print("PASS: \(sequence.genreName), first/middle/final + style/overlay/grid/NaN recovery, \(fixture.nodes.count) stable nodes.")
    }

    @MainActor private static func verifyEveryFrame(motion: AISTMotion, sequence: AISTSequence) throws {
        let initialFrame = (0..<motion.frameCount).first { motion.joints(at: $0).filter(finite).count >= 2 }!
        let fixture = try Fixture(points: motion.joints(at: initialFrame))
        for style in [AISTVisualStyle.skeleton, .porcelain, .neon] {
            for frame in 0..<motion.frameCount {
                try autoreleasepool {
                    let points = motion.joints(at: frame)
                    fixture.update(points, style: style, overlay: style != .skeleton)
                    try fixture.verifyStableState(points: points, label: "\(sequence.id) frame \(frame) \(style.rawValue)")
                }
            }
            print("PASS: every original frame (\(motion.frameCount)) — \(style.rawValue), finite transforms and stable nodes/reference/camera.")
        }
    }

    private static func finite<T: SIMDScalar & BinaryFloatingPoint>(_ value: SIMD3<T>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    private static func finite(_ matrix: simd_float4x4) -> Bool {
        for column in 0..<4 { for row in 0..<4 { if !matrix[column][row].isFinite { return false } } }
        return true
    }
}
