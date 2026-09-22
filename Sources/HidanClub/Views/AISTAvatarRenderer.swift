import AppKit
import SceneKit
import simd

/// An illustrative body surface driven by the same observed COCO-17 points.
/// This is not SMPL, a recovered body shape, or additional measured joints.
/// Body volume, palms, shoes and head shape are artistic display conventions.
@MainActor
final class AISTAvatarRenderer {
    let node = SCNNode()
    private let torso = SCNNode()
    private let head = SCNNode()
    private let neck = SCNNode()
    private var limbs: [SCNNode] = []
    private var articulations: [Int: SCNNode] = [:]
    private var hands: [SCNNode] = []
    private var feet: [SCNNode] = []
    private let porcelain = SCNMaterial()
    private let porcelainDetail = SCNMaterial()
    private let neonLeft = SCNMaterial()
    private let neonRight = SCNMaterial()
    private let neonCenter = SCNMaterial()
    private var style: AISTVisualStyle = .porcelain
    private static let segments: [(Int, Int, Float, Float)] = [
        (5, 7, 0.104, 0.76), (7, 9, 0.086, 0.61),
        (6, 8, 0.104, 0.76), (8, 10, 0.086, 0.61),
        (11, 13, 0.165, 0.66), (13, 15, 0.112, 0.49),
        (12, 14, 0.165, 0.66), (14, 16, 0.112, 0.49)
    ]
    private static let left: Set<Int> = [5, 7, 9, 11, 13, 15]

    init() {
        node.name = "AIST stylized avatar"
        configureMaterials()
        torso.name = "Continuous chest, waist and pelvis"
        node.addChildNode(torso)
        head.geometry = Self.ellipsoid()
        head.name = "Illustrative head"
        node.addChildNode(head)
        neck.geometry = Self.limbGeometry(distal: 0.88)
        neck.name = "Illustrative neck"
        node.addChildNode(neck)
        for segment in Self.segments {
            let part = SCNNode(geometry: Self.limbGeometry(distal: segment.3))
            part.name = "Body segment \(segment.0)–\(segment.1)"
            limbs.append(part)
            node.addChildNode(part)
            for endpoint in [segment.0, segment.1] where articulations[endpoint] == nil {
                let joint = SCNNode(geometry: Self.ellipsoid())
                joint.name = "Surface blend around joint \(endpoint)"
                articulations[endpoint] = joint
                node.addChildNode(joint)
            }
        }
        for side in 0..<2 {
            let palm = SCNNode()
            let main = SCNNode(geometry: Self.ellipsoid())
            main.simdScale = SIMD3(0.65, 1.18, 0.36)
            main.simdPosition = SIMD3(0, 0.65, 0)
            palm.addChildNode(main)
            let thumb = SCNNode(geometry: Self.ellipsoid())
            thumb.simdScale = SIMD3(0.28, 0.60, 0.30)
            thumb.simdPosition = SIMD3(side == 0 ? 0.53 : -0.53, 0.42, 0.05)
            thumb.eulerAngles.z = side == 0 ? -0.35 : 0.35
            palm.addChildNode(thumb)
            palm.name = "Illustrative palm \(side)"
            hands.append(palm)
            node.addChildNode(palm)
            let shoe = SCNNode(geometry: Self.shoeGeometry())
            shoe.name = "Illustrative shoe \(side) — toe direction is not measured"
            feet.append(shoe)
            node.addChildNode(shoe)
        }
        setStyle(.porcelain)
        node.childNodes.forEach { $0.isHidden = true }
    }

    func setStyle(_ style: AISTVisualStyle) {
        self.style = style
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        SCNTransaction.animationDuration = 0
        node.isHidden = style == .skeleton
        torso.geometry?.materials = torsoMaterials
        head.geometry?.materials = [style == .neon ? neonCenter : porcelain]
        neck.geometry?.materials = [style == .neon ? neonCenter : porcelain]
        for (index, segment) in Self.segments.enumerated() {
            limbs[index].geometry?.materials = [material(for: segment.0)]
        }
        for (index, articulation) in articulations { articulation.geometry?.materials = [material(for: index)] }
        for side in 0..<2 {
            let material = material(for: side == 0 ? 9 : 10)
            hands[side].childNodes.forEach { $0.geometry?.materials = [material] }
            feet[side].geometry?.materials = [style == .neon ? material : porcelainDetail]
        }
        SCNTransaction.commit()
    }

    func update(points: [SIMD3<Float>?]) {
        // All source positions are already in the host's fixed display reference.
        // Never filter, interpolate, resample or rewrite the input observations.
        let points: [SIMD3<Float>?] = (0..<17).map { index in
            guard points.indices.contains(index), let point = points[index], Self.finite(point) else { return nil }
            return point
        }
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        SCNTransaction.animationDuration = 0
        defer { SCNTransaction.commit() }
        let basis = BodyBasis(points: points)
        updateTorso(basis)
        for articulation in articulations.values { articulation.isHidden = true }
        for (index, segment) in Self.segments.enumerated() {
            let part = limbs[index]
            guard let start = points[segment.0], let end = points[segment.1],
                  let direction = Self.unit(end - start) else { part.isHidden = true; continue }
            let length = simd_length(end - start)
            let size = basis?.length ?? (length * (index < 4 ? 2.0 : 1.5))
            let radius = min(size * segment.2, length * 0.34)
            guard radius.isFinite, radius > 0.00001 else { part.isHidden = true; continue }
            Self.placeSegment(part, start: start, direction: direction, length: length, radius: radius)
            part.isHidden = false
            for (jointIndex, position, jointRadius) in [(segment.0, start, radius * 0.91), (segment.1, end, radius * segment.3)] {
                guard let joint = articulations[jointIndex] else { continue }
                // The shared elbow/knee blend uses the larger adjoining surface.
                let priorRadius = joint.isHidden ? 0 : joint.simdScale.x
                let actualRadius = max(priorRadius, jointRadius)
                joint.simdPosition = position
                joint.simdScale = SIMD3(repeating: actualRadius)
                joint.isHidden = false
            }
        }
        updateHead(points: points, body: basis)
        updateHands(points: points, body: basis)
        updateFeet(points: points, body: basis)
    }

    private func updateTorso(_ basis: BodyBasis?) {
        guard let body = basis else { torso.isHidden = true; return }
        let shoulderHalf = min(max(body.shoulderWidth * 0.5, body.length * 0.24), body.length * 0.60)
        let hipHalf = min(max(body.hipWidth * 0.57, shoulderHalf * 0.52), shoulderHalf * 0.94)
        // Smoothly taper the pelvis into a real waist and flare out to the rib cage.
        // Closely spaced rings round the shoulder and pelvic silhouette; the mesh
        // has no boxes, disconnected torso spheres, or artificial measured joints.
        let profile: [(Float, Float, Float)] = [
            (-0.20, 0.08, 0.05), (-0.18, 0.58, 0.48), (-0.12, 0.91, 0.68),
            (0.00, 1.02, 0.76), (0.13, 1.00, 0.73), (0.28, 0.92, 0.66),
            (0.42, 0.91, 0.67), (0.57, 1.00, 0.72), (0.72, 1.12, 0.77),
            (0.85, 1.21, 0.78), (0.95, 1.23, 0.71), (1.03, 1.10, 0.59),
            (1.09, 0.80, 0.47), (1.13, 0.43, 0.34), (1.14, 0.24, 0.24)
        ]
        let waistHalf = min(hipHalf * 0.94, shoulderHalf * 0.70)
        let rings = profile.map { fraction, width, depth -> Ring in
            let widthBase = fraction < 0.28 ? hipHalf : waistHalf
            let xRadius = fraction > 0.72 ? shoulderHalf * (width / 1.23) : widthBase * width
            return Ring(center: body.hip + body.up * (body.length * fraction),
                        xAxis: body.right, zAxis: body.depth,
                        xRadius: xRadius, zRadius: shoulderHalf * depth * 0.67)
        }
        // SceneKit geometry sources are immutable; only this small surface buffer
        // is renewed. Nodes, limb meshes and material instances remain retained.
        torso.geometry = Self.mesh(rings: rings, splitSides: true)
        torso.geometry?.materials = torsoMaterials
        torso.isHidden = false
    }

    private func updateHead(points: [SIMD3<Float>?], body: BodyBasis?) {
        head.isHidden = true
        neck.isHidden = true
        guard let leftShoulder = points[5], let rightShoulder = points[6] else { return }
        let shoulder = (leftShoulder + rightShoulder) * 0.5
        let face = (0..<5).compactMap { points[$0] }
        guard face.count >= 3 else { return }
        let faceCenter = face.reduce(SIMD3<Float>.zero, +) / Float(face.count)
        guard let up = body?.up ?? Self.unit(faceCenter - shoulder) else { return }
        let length = body?.length ?? simd_distance(leftShoulder, rightShoulder) * 1.45
        guard length.isFinite, length > 0.0001 else { return }
        let ears = points[3].flatMap { a in points[4].map { (a + $0) * 0.5 } }
        let eyes = points[1].flatMap { a in points[2].map { (a + $0) * 0.5 } }
        let support = ears ?? eyes ?? faceCenter
        let forward = Self.faceDirection(points: points, up: up) ?? body?.forward
        guard let forward, let right = Self.unit(simd_cross(up, forward)) else { return }
        let headUp = Self.unit(simd_cross(forward, right)) ?? up
        let center = support + headUp * (length * (ears != nil ? 0.055 : 0.01))
        head.simdPosition = center
        head.simdOrientation = simd_quatf(simd_float3x3(columns: (right, headUp, forward)))
        head.simdScale = SIMD3(length * 0.154, length * 0.211, length * 0.173)
        head.isHidden = false
        let bottom = center - headUp * (length * 0.15)
        let neckStart = shoulder + up * (length * 0.08)
        if let direction = Self.unit(bottom - neckStart) {
            Self.placeSegment(neck, start: neckStart, direction: direction,
                              length: simd_distance(neckStart, bottom), radius: length * 0.081)
            neck.isHidden = false
        }
    }

    private func updateHands(points: [SIMD3<Float>?], body: BodyBasis?) {
        for (side, pair) in [(7, 9), (8, 10)].enumerated() {
            let hand = hands[side]
            guard let elbow = points[pair.0], let wrist = points[pair.1],
                  let direction = Self.unit(wrist - elbow) else { hand.isHidden = true; continue }
            let length = body?.length ?? simd_distance(elbow, wrist) * 2.0
            let scale = min(length * 0.088, simd_distance(elbow, wrist) * 0.24)
            hand.simdPosition = wrist
            hand.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: direction)
            hand.simdScale = SIMD3(repeating: scale)
            hand.isHidden = false
        }
    }

    private func updateFeet(points: [SIMD3<Float>?], body: BodyBasis?) {
        for (side, pair) in [(13, 15), (14, 16)].enumerated() {
            let foot = feet[side]
            guard let body, let knee = points[pair.0], let ankle = points[pair.1],
                  let up = Self.unit(knee - ankle),
                  let forward = Self.unit(body.forward - up * simd_dot(body.forward, up)),
                  let right = Self.unit(simd_cross(up, forward)) else { foot.isHidden = true; continue }
            foot.simdPosition = ankle - up * (body.length * 0.035) + forward * (body.length * 0.035)
            foot.simdOrientation = simd_quatf(simd_float3x3(columns: (right, up, forward)))
            foot.simdScale = SIMD3(repeating: body.length * 0.27)
            foot.isHidden = false
        }
    }

    private func configureMaterials() {
        for material in [porcelain, porcelainDetail, neonLeft, neonRight, neonCenter] {
            material.lightingModel = .physicallyBased
            material.isDoubleSided = false
            material.roughness.contents = 0.40
            material.metalness.contents = 0.10
        }
        porcelain.diffuse.contents = NSColor(srgbRed: 0.81, green: 0.88, blue: 0.98, alpha: 1)
        porcelain.roughness.contents = 0.48
        porcelain.metalness.contents = 0.05
        porcelainDetail.diffuse.contents = NSColor(srgbRed: 0.56, green: 0.65, blue: 0.82, alpha: 1)
        porcelainDetail.roughness.contents = 0.50
        neonLeft.diffuse.contents = NSColor(srgbRed: 0.06, green: 0.55, blue: 0.62, alpha: 1)
        neonLeft.emission.contents = NSColor(srgbRed: 0.015, green: 0.20, blue: 0.23, alpha: 1)
        neonRight.diffuse.contents = NSColor(srgbRed: 0.45, green: 0.20, blue: 0.78, alpha: 1)
        neonRight.emission.contents = NSColor(srgbRed: 0.12, green: 0.025, blue: 0.27, alpha: 1)
        neonCenter.diffuse.contents = NSColor(srgbRed: 0.46, green: 0.57, blue: 0.91, alpha: 1)
        neonCenter.emission.contents = NSColor(srgbRed: 0.06, green: 0.07, blue: 0.19, alpha: 1)
        for material in [neonLeft, neonRight, neonCenter] {
            material.metalness.contents = 0.40
            material.roughness.contents = 0.29
        }
    }

    private var torsoMaterials: [SCNMaterial] { style == .neon ? [neonLeft, neonRight] : [porcelain, porcelain] }
    private func material(for index: Int) -> SCNMaterial {
        style == .neon ? (Self.left.contains(index) ? neonLeft : neonRight) : porcelain
    }

    private struct BodyBasis {
        let hip: SIMD3<Float>
        let up: SIMD3<Float>
        let right: SIMD3<Float>
        let depth: SIMD3<Float>
        let forward: SIMD3<Float>
        let length: Float
        let shoulderWidth: Float
        let hipWidth: Float

        init?(points: [SIMD3<Float>?]) {
            guard let ls = points[5], let rs = points[6], let lh = points[11], let rh = points[12] else { return nil }
            hip = (lh + rh) * 0.5
            let shoulder = (ls + rs) * 0.5
            let spine = shoulder - hip
            guard let up = AISTAvatarRenderer.unit(spine) else { return nil }
            length = simd_length(spine)
            shoulderWidth = simd_distance(ls, rs)
            hipWidth = simd_distance(lh, rh)
            guard length.isFinite, shoulderWidth.isFinite, hipWidth.isFinite,
                  shoulderWidth > length * 0.08, hipWidth > length * 0.05 else { return nil }
            let lateral = (rs - ls) + (rh - lh)
            guard let right = AISTAvatarRenderer.unit(lateral - up * simd_dot(lateral, up)),
                  let depth = AISTAvatarRenderer.unit(simd_cross(right, up)) else { return nil }
            self.up = up
            self.right = right
            self.depth = depth
            forward = AISTAvatarRenderer.faceDirection(points: points, up: up) ?? -depth
        }
    }

    private struct Ring {
        let center: SIMD3<Float>
        let xAxis: SIMD3<Float>
        let zAxis: SIMD3<Float>
        let xRadius: Float
        let zRadius: Float
    }

    nonisolated private static func finite(_ point: SIMD3<Float>) -> Bool { point.x.isFinite && point.y.isFinite && point.z.isFinite }
    nonisolated private static func unit(_ vector: SIMD3<Float>) -> SIMD3<Float>? {
        let length = simd_length(vector)
        guard length.isFinite, length > 0.00001 else { return nil }
        return vector / length
    }

    nonisolated private static func faceDirection(points: [SIMD3<Float>?], up: SIMD3<Float>) -> SIMD3<Float>? {
        guard let nose = points[0], let leftEar = points[3], let rightEar = points[4] else { return nil }
        let vector = nose - (leftEar + rightEar) * 0.5
        return unit(vector - up * simd_dot(vector, up))
    }

    private static func placeSegment(_ node: SCNNode, start: SIMD3<Float>, direction: SIMD3<Float>, length: Float, radius: Float) {
        node.simdPosition = start
        node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: direction)
        node.simdScale = SIMD3(radius, length, radius * 0.92)
    }

    private static func ellipsoid() -> SCNSphere {
        let geometry = SCNSphere(radius: 1)
        geometry.segmentCount = 32
        return geometry
    }

    private static func limbGeometry(distal: Float) -> SCNGeometry {
        let profile: [(Float, Float)] = [
            (-0.045, 0.015), (-0.018, 0.57), (0, 0.90), (0.07, 1.00),
            (0.20, 1.04), (0.40, 0.99), (0.65, 0.88), (0.86, distal * 1.10),
            (1.00, distal), (1.025, distal * 0.55), (1.04, 0.015)
        ]
        return mesh(rings: profile.map {
            Ring(center: SIMD3(0, $0.0, 0), xAxis: SIMD3(1, 0, 0), zAxis: SIMD3(0, 0, 1), xRadius: $0.1, zRadius: $0.1)
        })
    }

    private static func shoeGeometry() -> SCNGeometry {
        // Cross-sections run heel to toe, with a flattened sole and rounded instep.
        let profile: [(Float, Float, Float, Float)] = [
            (-0.55, 0.03, 0.03, 0.02), (-0.50, 0.30, 0.23, 0.03),
            (-0.35, 0.40, 0.34, 0.07), (-0.12, 0.43, 0.42, 0.10),
            (0.15, 0.46, 0.39, 0.07), (0.48, 0.47, 0.28, 0.00),
            (0.77, 0.40, 0.22, -0.03), (0.95, 0.23, 0.16, -0.03),
            (1.00, 0.02, 0.02, -0.03)
        ]
        let count = 32
        var vertices: [SIMD3<Float>] = []
        for (z, width, height, offset) in profile {
            for index in 0..<count {
                let angle = Float(index) / Float(count) * 2 * .pi
                vertices.append(SIMD3(cos(angle) * width, max(sin(angle) * height + offset, -0.22), z))
            }
        }
        // Orient ring winding consistently with the longitudinal +Z direction.
        return indexedMesh(vertices: vertices, ringCount: profile.count, radialCount: count, splitSides: false, reverse: true)
    }

    private static func mesh(rings: [Ring], splitSides: Bool = false) -> SCNGeometry {
        let count = 32
        var vertices: [SIMD3<Float>] = []
        vertices.reserveCapacity(rings.count * count)
        for ring in rings {
            for index in 0..<count {
                let angle = Float(index) / Float(count) * 2 * .pi
                vertices.append(ring.center + ring.xAxis * (cos(angle) * ring.xRadius) + ring.zAxis * (sin(angle) * ring.zRadius))
            }
        }
        return indexedMesh(vertices: vertices, ringCount: rings.count, radialCount: count, splitSides: splitSides)
    }

    private static func indexedMesh(vertices inputVertices: [SIMD3<Float>], ringCount: Int, radialCount: Int, splitSides: Bool, reverse: Bool = false) -> SCNGeometry {
        var vertices = inputVertices
        let firstCenter = vertices.prefix(radialCount).reduce(SIMD3<Float>.zero, +) / Float(radialCount)
        let lastCenter = vertices.suffix(radialCount).reduce(SIMD3<Float>.zero, +) / Float(radialCount)
        let firstCenterIndex = UInt32(vertices.count)
        vertices.append(firstCenter)
        let lastCenterIndex = UInt32(vertices.count)
        vertices.append(lastCenter)
        var groups = [[UInt32](), [UInt32]()]
        var normals = [SIMD3<Float>](repeating: .zero, count: vertices.count)
        for ring in 0..<(ringCount - 1) {
            for index in 0..<radialCount {
                let a = UInt32(ring * radialCount + index)
                let b = UInt32(ring * radialCount + (index + 1) % radialCount)
                let c = a + UInt32(radialCount)
                let d = b + UInt32(radialCount)
                let group = splitSides && cos((Float(index) + 0.5) / Float(radialCount) * 2 * .pi) >= 0 ? 1 : 0
                let triangles = reverse ? [a, b, c, b, d, c] : [a, c, b, b, c, d]
                groups[group].append(contentsOf: triangles)
                for offset in stride(from: 0, to: triangles.count, by: 3) {
                    let i = Int(triangles[offset]), j = Int(triangles[offset + 1]), k = Int(triangles[offset + 2])
                    let normal = simd_cross(vertices[j] - vertices[i], vertices[k] - vertices[i])
                    normals[i] += normal; normals[j] += normal; normals[k] += normal
                }
            }
        }
        // Close the heel, toe and limb ends so highlights cannot reveal pinholes.
        for index in 0..<radialCount {
            let a = UInt32(index), b = UInt32((index + 1) % radialCount)
            let c = a + UInt32((ringCount - 1) * radialCount)
            let d = b + UInt32((ringCount - 1) * radialCount)
            let group = splitSides && cos((Float(index) + 0.5) / Float(radialCount) * 2 * .pi) >= 0 ? 1 : 0
            let triangles = reverse ? [firstCenterIndex, b, a, lastCenterIndex, c, d] : [firstCenterIndex, a, b, lastCenterIndex, d, c]
            groups[group].append(contentsOf: triangles)
            for offset in stride(from: 0, to: triangles.count, by: 3) {
                let i = Int(triangles[offset]), j = Int(triangles[offset + 1]), k = Int(triangles[offset + 2])
                let normal = simd_cross(vertices[j] - vertices[i], vertices[k] - vertices[i])
                normals[i] += normal; normals[j] += normal; normals[k] += normal
            }
        }
        let normalVectors = normals.map { SCNVector3(unit($0) ?? SIMD3(0, 1, 0)) }
        let source = SCNGeometrySource(vertices: vertices.map(SCNVector3.init))
        let normalSource = SCNGeometrySource(normals: normalVectors)
        let elements = groups.filter { !$0.isEmpty }.map { SCNGeometryElement(indices: $0, primitiveType: .triangles) }
        return SCNGeometry(sources: [source, normalSource], elements: elements)
    }
}
