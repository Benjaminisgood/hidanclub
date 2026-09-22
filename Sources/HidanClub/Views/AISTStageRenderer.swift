import AppKit
import SceneKit

/// A presentation stage with fixed geometry and lighting. No source coordinates
/// or floor estimates are modified to make the figure sit on the display plinth.
@MainActor final class AISTStageRenderer {
    let node = SCNNode()
    private let floorMaterial = SCNMaterial()
    private let platformMaterial = SCNMaterial()
    private let ringMaterial = SCNMaterial()
    private let gridMaterial = SCNMaterial()
    private let grid = SCNNode()
    private let ambient = SCNLight()
    private let key = SCNLight()
    private let fill = SCNLight()
    private let rim = SCNLight()

    init() {
        node.name = "Figure studio — display only"
        let floor = SCNPlane(width: 160, height: 160)
        floorMaterial.lightingModel = .blinn
        floorMaterial.isDoubleSided = true
        floor.firstMaterial = floorMaterial
        let floorNode = SCNNode(geometry: floor)
        floorNode.name = "Studio floor"
        floorNode.eulerAngles.x = -.pi / 2
        floorNode.position.y = -0.18
        node.addChildNode(floorNode)

        let platform = SCNCylinder(radius: 2.8, height: 0.05)
        platform.radialSegmentCount = 128
        platformMaterial.lightingModel = .blinn
        platformMaterial.specular.contents = NSColor(white: 0.12, alpha: 1)
        platformMaterial.shininess = 0.18
        platform.firstMaterial = platformMaterial
        let platformNode = SCNNode(geometry: platform)
        platformNode.name = "Display plinth"
        platformNode.position.y = -0.155
        node.addChildNode(platformNode)

        let ring = SCNTorus(ringRadius: 2.72, pipeRadius: 0.006)
        ring.ringSegmentCount = 128
        ring.pipeSegmentCount = 8
        ringMaterial.lightingModel = .constant
        ring.firstMaterial = ringMaterial
        let ringNode = SCNNode(geometry: ring)
        ringNode.name = "Stage rim"
        ringNode.position.y = -0.121
        node.addChildNode(ringNode)

        grid.name = "Optional studio reference grid"
        gridMaterial.lightingModel = .constant
        for index in -5...5 {
            for crosswise in [true, false] {
                let line = SCNBox(width: crosswise ? 5 : 0.0025, height: 0.001,
                                  length: crosswise ? 0.0025 : 5, chamferRadius: 0)
                line.firstMaterial = gridMaterial
                let segment = SCNNode(geometry: line)
                segment.position = SCNVector3(crosswise ? 0 : Float(index) * 0.5, -0.124,
                                              crosswise ? Float(index) * 0.5 : 0)
                grid.addChildNode(segment)
            }
        }
        node.addChildNode(grid)
        add(ambient, type: .ambient, angles: SCNVector3Zero)
        add(key, type: .directional, angles: SCNVector3(-0.65, -0.55, -0.18))
        add(fill, type: .directional, angles: SCNVector3(-0.18, 0.95, 0.20))
        add(rim, type: .directional, angles: SCNVector3(-0.4, 2.8, 0))
        key.castsShadow = true
        key.shadowMode = .forward
        key.shadowMapSize = CGSize(width: 2048, height: 2048)
        key.shadowSampleCount = 16
        key.shadowRadius = 5
        key.shadowBias = 0.01
        key.orthographicScale = 9
        key.maximumShadowDistance = 25
    }

    func apply(style: AISTVisualStyle, showGrid: Bool, scene: SCNScene) {
        node.isHidden = style == .skeleton
        grid.isHidden = !showGrid
        guard style != .skeleton else { return }
        let light = style == .porcelain
        let backdrop = light ? color(0.86, 0.90, 0.93) : color(0.045, 0.035, 0.085)
        scene.background.contents = backdrop
        scene.fogColor = backdrop
        scene.fogStartDistance = 8
        scene.fogEndDistance = 18
        floorMaterial.diffuse.contents = light ? color(0.85, 0.88, 0.90) : color(0.047, 0.042, 0.085)
        platformMaterial.diffuse.contents = light ? color(0.78, 0.83, 0.86) : color(0.075, 0.065, 0.13)
        ringMaterial.diffuse.contents = light ? color(0.64, 0.71, 0.77) : color(0.40, 0.56, 0.85)
        gridMaterial.diffuse.contents = light ? color(0.67, 0.74, 0.79) : color(0.15, 0.18, 0.28)
        ambient.color = light ? color(0.91, 0.95, 1) : color(0.58, 0.60, 0.86)
        ambient.intensity = light ? 340 : 210
        key.color = light ? color(1, 0.96, 0.90) : color(0.80, 0.90, 1)
        key.intensity = light ? 900 : 850
        key.shadowColor = NSColor.black.withAlphaComponent(light ? 0.20 : 0.42)
        fill.color = light ? color(0.71, 0.83, 1) : color(0.65, 0.39, 1)
        fill.intensity = light ? 240 : 380
        rim.color = light ? color(0.79, 0.87, 1) : color(0.26, 1, 0.87)
        rim.intensity = light ? 550 : 700
    }

    func setSurfaceHidden(_ hidden: Bool, showGrid: Bool = false) {
        // Keep the lights active when compositing a mannequin over camera video.
        for child in node.childNodes where child.light == nil {
            child.isHidden = hidden || (child === grid && !showGrid)
        }
    }

    private func add(_ light: SCNLight, type: SCNLight.LightType, angles: SCNVector3) {
        light.type = type
        let source = SCNNode()
        source.light = light
        source.eulerAngles = angles
        node.addChildNode(source)
    }
    private func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
