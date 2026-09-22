import AppKit
import SceneKit
import SwiftUI
import simd

/// A display-only COCO-17 viewer. Input coordinates, frame order and frame count
/// are never changed. A fixed similarity transform, established by the first
/// finite frame, makes source units comfortable to view without calling them metres.
/// Give the representable a new SwiftUI identity when changing coordinate systems
/// or clips. `resetToken` reframes the camera; it does not rescale the moving body.
struct AISTSkeletonView: NSViewRepresentable {
    var joints: [SIMD3<Double>]
    var upAxis: String
    var mirrored: Bool
    var resetToken: Int
    var showJointNames: Bool = false
    var style: AISTVisualStyle = .skeleton
    var showSkeletonOverlay: Bool = false
    var showReferenceGrid: Bool = false
    var transparentBackground: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SkeletonSceneView()
        context.coordinator.install(in: view)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.update(
            joints: joints, upAxis: upAxis, mirrored: mirrored,
            resetToken: resetToken, showJointNames: showJointNames, style: style,
            showSkeletonOverlay: showSkeletonOverlay, showReferenceGrid: showReferenceGrid, transparentBackground: transparentBackground, in: view
        )
    }

    static func dismantleNSView(_ view: SCNView, coordinator: Coordinator) {
        (view as? SkeletonSceneView)?.didLayout = nil
        view.scene = nil
    }

    @MainActor final class Coordinator {
        // COCO's 17 measured joints only: no inferred neck/root or synthetic joints.
        private static let names = [
            "鼻", "左眼", "右眼", "左耳", "右耳", "左肩", "右肩", "左肘", "右肘",
            "左腕", "右腕", "左髋", "右髋", "左膝", "右膝", "左踝", "右踝"
        ]
        private static let edges = [
            (15, 13), (13, 11), (16, 14), (14, 12), (11, 12),
            (5, 11), (6, 12), (5, 6), (5, 7), (6, 8), (7, 9), (8, 10),
            (1, 2), (0, 1), (0, 2), (1, 3), (2, 4), (3, 5), (4, 6)
        ]
        private static let leftIndices: Set<Int> = [1, 3, 5, 7, 9, 11, 13, 15]
        private static let rightIndices: Set<Int> = [2, 4, 6, 8, 10, 12, 14, 16]
        private static let leftColor = NSColor(srgbRed: 0.39, green: 0.91, blue: 0.76, alpha: 1)
        private static let rightColor = NSColor(srgbRed: 0.65, green: 0.65, blue: 1.0, alpha: 1)
        private static let centralColor = NSColor(srgbRed: 0.88, green: 0.90, blue: 0.96, alpha: 1)

        private let scene = SCNScene()
        private let cameraNode = SCNNode()
        private let skeleton = SCNNode()
        private let originalEnvironment = SCNNode()
        private let avatar = AISTAvatarRenderer()
        private let studio = AISTStageRenderer()
        private var jointNodes: [SCNNode] = []
        private var boneNodes: [SCNNode] = []
        private var labelNodes: [SCNNode] = []
        private var reference: DisplayReference?
        private var previousResetToken: Int?
        private var previousUpAxis: String?
        private var displayedPoints: [SIMD3<Float>?] = []
        private var pendingCameraReset = true
        private var pendingInitialLayout = true
        private var framedSize = CGSize.zero
        private var sceneIsInstalled = false
        private var previousStyle: AISTVisualStyle?
        private var previousGrid: Bool?
        private var previousTransparent: Bool?

        func install(in view: SCNView) {
            // The scene and all skeleton geometries live for the representable's
            // lifetime. Frame updates only set transforms and visibility.
            guard !sceneIsInstalled else { return }
            sceneIsInstalled = true
            scene.background.contents = NSColor(srgbRed: 0.055, green: 0.064, blue: 0.095, alpha: 1)
            scene.rootNode.addChildNode(skeleton)
            scene.rootNode.addChildNode(originalEnvironment)
            scene.rootNode.addChildNode(avatar.node)
            scene.rootNode.addChildNode(studio.node)
            skeleton.name = "COCO-17 — source joints"
            createSkeleton()
            createEnvironment()

            let camera = SCNCamera()
            camera.fieldOfView = 42
            camera.zNear = 0.005
            camera.zFar = 500
            camera.wantsHDR = false
            camera.wantsExposureAdaptation = false
            camera.exposureOffset = 0
            camera.bloomIntensity = 0
            camera.bloomThreshold = 1
            cameraNode.camera = camera
            cameraNode.name = "Orbit camera"
            cameraNode.position = SCNVector3(0, 1.4, 5.6)
            scene.rootNode.addChildNode(cameraNode)

            view.scene = scene
            view.pointOfView = cameraNode
            view.allowsCameraControl = true
            view.defaultCameraController.interactionMode = .orbitTurntable
            view.defaultCameraController.inertiaEnabled = false
            view.defaultCameraController.worldUp = SCNVector3(0, 1, 0)
            view.autoenablesDefaultLighting = false
            view.antialiasingMode = .multisampling4X
            view.preferredFramesPerSecond = 60
            // Rendering is requested by source-frame updates and user interaction;
            // SceneKit does not run a separate skeleton timeline or interpolate poses.
            view.isPlaying = false
            view.rendersContinuously = false
            view.setAccessibilityLabel("三维骨架，绿色为左侧，紫色为右侧。拖动旋转，滚动缩放。地面为显示参考网格。")
            (view as? SkeletonSceneView)?.didLayout = { [weak self, weak view] in
                guard let self, let view,
                      view.bounds.width > 40, view.bounds.height > 40,
                      self.displayedPoints.contains(where: { $0 != nil }) else { return }
                let size = view.bounds.size
                let resized = abs(size.width - self.framedSize.width) > 24 || abs(size.height - self.framedSize.height) > 24
                guard self.pendingInitialLayout || resized else { return }
                self.withoutAnimation {
                    self.frameCamera(in: view)
                }
                self.framedSize = size
                self.pendingInitialLayout = false
                self.pendingCameraReset = false
            }
        }

        func update(joints: [SIMD3<Double>], upAxis: String, mirrored: Bool,
                    resetToken: Int, showJointNames: Bool, style: AISTVisualStyle = .skeleton,
                    showSkeletonOverlay: Bool = false, showReferenceGrid: Bool = false, transparentBackground: Bool = false, in view: SCNView) {
            let axis = upAxis.lowercased() == "z" ? "z" : "y"
            if previousUpAxis != axis {
                reference = nil
                pendingCameraReset = true
                pendingInitialLayout = true
                previousUpAxis = axis
            }
            if previousResetToken != resetToken {
                pendingCameraReset = true
                previousResetToken = resetToken
            }

            let oriented: [SIMD3<Double>?] = (0..<17).map { index in
                guard joints.indices.contains(index), Self.isFinite(joints[index]) else { return nil }
                let point = joints[index]
                // Rotation about X takes source Z-up to SceneKit Y-up while
                // retaining handedness. Mirroring is a separate display operation.
                return axis == "z" ? SIMD3(point.x, point.z, -point.y) : point
            }
            if reference == nil { reference = DisplayReference(points: oriented.compactMap { $0 }) }
            displayedPoints = oriented.map { point in
                guard let point, let reference else { return nil }
                var mapped = (point - reference.origin) * reference.scale
                if mirrored { mapped.x = -mapped.x }
                guard Self.isFinite(mapped) else { return nil }
                let result = SIMD3<Float>(mapped)
                return Self.isFinite(result) ? result : nil
            }

            withoutAnimation {
                if previousStyle != style || previousGrid != showReferenceGrid || previousTransparent != transparentBackground {
                    originalEnvironment.isHidden = style != .skeleton
                    studio.apply(style: style, showGrid: showReferenceGrid, scene: scene)
                    avatar.setStyle(style)
                    if style == .skeleton {
                        scene.background.contents = NSColor(srgbRed: 0.055, green: 0.064, blue: 0.095, alpha: 1)
                        scene.fogColor = NSColor(srgbRed: 0.055, green: 0.064, blue: 0.095, alpha: 1)
                        scene.fogStartDistance = 9; scene.fogEndDistance = 22
                    }
                    view.setAccessibilityLabel("\(style.title)。拖动旋转，滚动缩放。人体外观为关键点驱动示意。")
                    if transparentBackground {
                        originalEnvironment.isHidden = true
                        studio.setSurfaceHidden(true)
                        scene.background.contents = NSColor.clear
                        scene.fogStartDistance = 0; scene.fogEndDistance = 0
                    } else { studio.setSurfaceHidden(false, showGrid: showReferenceGrid) }
                    view.backgroundColor = .clear
                    previousTransparent = transparentBackground
                    previousStyle = style; previousGrid = showReferenceGrid
                }
                avatar.node.isHidden = style == .skeleton
                if style != .skeleton { avatar.update(points: displayedPoints) }
                let drawBones = style == .skeleton || showSkeletonOverlay
                for index in 0..<17 {
                    let node = jointNodes[index]
                    let label = labelNodes[index]
                    guard let point = displayedPoints[index] else {
                        node.isHidden = true
                        label.isHidden = true
                        continue
                    }
                    node.simdPosition = point
                    node.isHidden = !drawBones
                    node.renderingOrder = style == .skeleton ? 0 : 5
                    node.geometry?.firstMaterial?.readsFromDepthBuffer = style == .skeleton
                    node.geometry?.firstMaterial?.writesToDepthBuffer = style == .skeleton
                    label.simdPosition = point + SIMD3<Float>(0.045, 0.025, 0)
                    label.isHidden = !showJointNames
                }
                for (index, edge) in Self.edges.enumerated() {
                    let node = boneNodes[index]
                    guard let start = displayedPoints[edge.0], let end = displayedPoints[edge.1] else {
                        node.isHidden = true
                        continue
                    }
                    let displacement = end - start
                    let length = simd_length(displacement)
                    guard length.isFinite, length > 0.000001 else {
                        node.isHidden = true
                        continue
                    }
                    node.simdPosition = start + displacement * 0.5
                    node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: displacement / length)
                    node.simdScale = SIMD3<Float>(1, length, 1)
                    node.isHidden = !drawBones
                    node.renderingOrder = style == .skeleton ? 0 : 5
                    node.geometry?.firstMaterial?.readsFromDepthBuffer = style == .skeleton
                    node.geometry?.firstMaterial?.writesToDepthBuffer = style == .skeleton
                }
                if pendingCameraReset, displayedPoints.contains(where: { $0 != nil }),
                   view.bounds.width > 40, view.bounds.height > 40 {
                    frameCamera(in: view)
                    pendingCameraReset = false
                    pendingInitialLayout = false
                    framedSize = view.bounds.size
                }
            }
            view.needsDisplay = true
        }

        private func createSkeleton() {
            for index in 0..<17 {
                let sphere = SCNSphere(radius: index < 5 ? 0.021 : 0.031)
                sphere.segmentCount = 16
                sphere.firstMaterial = material(color: color(for: index))
                let node = SCNNode(geometry: sphere)
                node.name = "joint_\(index)_\(Self.names[index])"
                node.isHidden = true
                skeleton.addChildNode(node)
                jointNodes.append(node)

                let text = SCNText(string: Self.names[index], extrusionDepth: 0)
                text.font = .systemFont(ofSize: 8, weight: .medium)
                text.flatness = 0.2
                let labelMaterial = material(color: color(for: index))
                labelMaterial.lightingModel = .constant
                labelMaterial.readsFromDepthBuffer = false
                labelMaterial.writesToDepthBuffer = false
                text.firstMaterial = labelMaterial
                let label = SCNNode(geometry: text)
                label.name = "label_\(index)"
                label.simdScale = SIMD3(repeating: 0.006)
                label.constraints = [SCNBillboardConstraint()]
                label.renderingOrder = 10
                label.isHidden = true
                skeleton.addChildNode(label)
                labelNodes.append(label)
            }
            for (start, end) in Self.edges {
                let cylinder = SCNCylinder(radius: (start < 5 && end < 5) ? 0.011 : 0.017, height: 1)
                cylinder.radialSegmentCount = 12
                let edgeColor: NSColor
                if Self.leftIndices.contains(start), Self.leftIndices.contains(end) {
                    edgeColor = Self.leftColor
                } else if Self.rightIndices.contains(start), Self.rightIndices.contains(end) {
                    edgeColor = Self.rightColor
                } else { edgeColor = Self.centralColor }
                cylinder.firstMaterial = material(color: edgeColor)
                let node = SCNNode(geometry: cylinder)
                node.name = "bone_\(start)_\(end)"
                node.isHidden = true
                skeleton.addChildNode(node)
                boneNodes.append(node)
            }
        }

        private func createEnvironment() {
            let ambient = SCNLight()
            ambient.type = .ambient
            ambient.color = NSColor(srgbRed: 0.77, green: 0.82, blue: 1, alpha: 1)
            ambient.intensity = 260
            let ambientNode = SCNNode()
            ambientNode.light = ambient
            originalEnvironment.addChildNode(ambientNode)

            let key = SCNLight()
            key.type = .directional
            key.color = NSColor(srgbRed: 0.87, green: 0.93, blue: 1, alpha: 1)
            key.intensity = 650
            let keyNode = SCNNode()
            keyNode.light = key
            keyNode.eulerAngles = SCNVector3(-0.7, -0.6, -0.3)
            originalEnvironment.addChildNode(keyNode)

            let rim = SCNLight()
            rim.type = .directional
            rim.color = NSColor(srgbRed: 0.63, green: 0.62, blue: 1, alpha: 1)
            rim.intensity = 250
            let rimNode = SCNNode()
            rimNode.light = rim
            rimNode.eulerAngles = SCNVector3(-0.3, 2.3, 0)
            originalEnvironment.addChildNode(rimNode)

            // This fixed, unitless reference grid starts below the first finite
            // frame's lowest joint. It neither estimates a physical floor nor
            // follows the feet, so vertical movement remains visible unchanged.
            let floor = SCNPlane(width: 16, height: 16)
            let floorMaterial = material(color: NSColor(srgbRed: 0.073, green: 0.084, blue: 0.117, alpha: 1))
            floorMaterial.lightingModel = .constant
            floorMaterial.isDoubleSided = true
            floor.firstMaterial = floorMaterial
            let floorNode = SCNNode(geometry: floor)
            floorNode.name = "Display reference plane — no physical units"
            floorNode.eulerAngles.x = -.pi / 2
            floorNode.position.y = -0.055
            originalEnvironment.addChildNode(floorNode)

            let grid = SCNNode()
            grid.name = "Unitless display grid"
            let gridMaterial = SCNMaterial()
            gridMaterial.lightingModel = .constant
            gridMaterial.diffuse.contents = NSColor(srgbRed: 0.20, green: 0.23, blue: 0.31, alpha: 1)
            for step in -12...12 {
                let offset = Float(step) * 0.5
                let width: CGFloat = step == 0 ? 0.006 : 0.003
                for isHorizontal in [false, true] {
                    let line = SCNBox(width: isHorizontal ? 12 : width, height: 0.001,
                                      length: isHorizontal ? width : 12, chamferRadius: 0)
                    line.firstMaterial = gridMaterial
                    let lineNode = SCNNode(geometry: line)
                    lineNode.position = SCNVector3(isHorizontal ? 0 : offset, -0.05, isHorizontal ? offset : 0)
                    grid.addChildNode(lineNode)
                }
            }
            originalEnvironment.addChildNode(grid)
            scene.fogColor = NSColor(srgbRed: 0.055, green: 0.064, blue: 0.095, alpha: 1)
            scene.fogStartDistance = 9
            scene.fogEndDistance = 22
        }

        private func frameCamera(in view: SCNView) {
            let points = displayedPoints.compactMap { $0 }
            guard let first = points.first else { return }
            var low = first
            var high = first
            for point in points.dropFirst() {
                low = simd_min(low, point)
                high = simd_max(high, point)
            }
            let center = low + (high - low) * 0.5
            let radius = max(points.map { simd_distance($0, center) }.max() ?? 1, 0.3)
            guard Self.isFinite(center), radius.isFinite else { return }
            let aspect = view.bounds.height > 0 ? Float(view.bounds.width / view.bounds.height) : 1
            let verticalHalfFOV = Float(42 * Double.pi / 360)
            let horizontalHalfFOV = atan(tan(verticalHalfFOV) * max(aspect, 0.15))
            let padding: Float = previousStyle == .skeleton ? 1.22 : 1.36
            let distance = radius / sin(min(verticalHalfFOV, horizontalHalfFOV)) * padding
            guard distance.isFinite else { return }
            let direction = simd_normalize(SIMD3<Float>(0.20, 0.13, 1))
            cameraNode.simdPosition = center + direction * distance
            cameraNode.look(at: SCNVector3(center), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
            cameraNode.camera?.zFar = Double(max(distance + radius * 8, 50))
            view.pointOfView = cameraNode
            view.defaultCameraController.target = SCNVector3(center)
            view.defaultCameraController.stopInertia()
        }

        private func material(color: NSColor) -> SCNMaterial {
            let material = SCNMaterial()
            material.lightingModel = .blinn
            material.diffuse.contents = color
            material.specular.contents = NSColor(white: 0.18, alpha: 1)
            material.shininess = 0.35
            return material
        }

        private func color(for index: Int) -> NSColor {
            if Self.leftIndices.contains(index) { return Self.leftColor }
            if Self.rightIndices.contains(index) { return Self.rightColor }
            return Self.centralColor
        }

        private func withoutAnimation(_ update: () -> Void) {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0
            SCNTransaction.disableActions = true
            update()
            SCNTransaction.commit()
        }

        private static func isFinite<T: SIMDScalar & BinaryFloatingPoint>(_ value: SIMD3<T>) -> Bool {
            value.x.isFinite && value.y.isFinite && value.z.isFinite
        }

        private struct DisplayReference {
            let origin: SIMD3<Double>
            let scale: Double

            init?(points: [SIMD3<Double>]) {
                guard let first = points.first else { return nil }
                var low = first
                var high = first
                for point in points.dropFirst() {
                    low = simd_min(low, point)
                    high = simd_max(high, point)
                }
                let extent = high - low
                guard extent.x.isFinite, extent.y.isFinite, extent.z.isFinite else { return nil }
                origin = SIMD3(low.x + extent.x * 0.5, low.y, low.z + extent.z * 0.5)
                let largestExtent = max(extent.x, max(extent.y, extent.z))
                scale = largestExtent > 0.000000001 ? 2.2 / largestExtent : 1
            }
        }
    }
}

private final class SkeletonSceneView: SCNView {
    var didLayout: (() -> Void)?

    override func layout() {
        super.layout()
        didLayout?()
    }
}
