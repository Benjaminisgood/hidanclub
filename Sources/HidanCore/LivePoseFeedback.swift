import Foundation

public struct LivePosePoint: Sendable {
    public let x: Double
    public let y: Double
    public let confidence: Double
    public init(x: Double, y: Double, confidence: Double) {
        self.x = x; self.y = y; self.confidence = confidence
    }
}

/// One camera observation. Coordinates retain Vision's normalized bottom-left
/// origin; angles below restore the captured image aspect ratio first.
public struct LivePoseObservation: Sendable {
    public let frameNumber: Int
    public let timestamp: Double
    public let width: Int
    public let height: Int
    public let bodyCount: Int
    public let joints: [String: LivePosePoint]
    public let error: String?
    public init(frameNumber: Int, timestamp: Double, width: Int, height: Int,
                bodyCount: Int, joints: [String: LivePosePoint], error: String? = nil) {
        self.frameNumber = frameNumber; self.timestamp = timestamp
        self.width = width; self.height = height; self.bodyCount = bodyCount
        self.joints = joints; self.error = error
    }
}

/// Visibility and 2D observations only. This is not an AIST 3D comparison,
/// movement-quality score, diagnosis, or a prescription for a particular dance.
public struct LivePoseFeedback: Sendable {
    public static let confidenceThreshold = 0.35
    public let headline: String
    public let guidance: String
    public let visibleJointCount: Int
    public let fullBodyVisible: Bool
    public let leftElbow: Double?
    public let rightElbow: Double?
    public let leftKnee: Double?
    public let rightKnee: Double?

    public init(observation: LivePoseObservation) {
        let points = observation.bodyCount == 1 && observation.error == nil
            ? observation.joints.filter { Self.isVisible($0.value) } : [:]
        visibleJointCount = points.count
        func angle(_ a: String, _ b: String, _ c: String) -> Double? {
            Self.angle(a: points[a], vertex: points[b], c: points[c], width: observation.width, height: observation.height)
        }
        leftElbow = angle("leftShoulder", "leftElbow", "leftWrist")
        rightElbow = angle("rightShoulder", "rightElbow", "rightWrist")
        leftKnee = angle("leftHip", "leftKnee", "leftAnkle")
        rightKnee = angle("rightHip", "rightKnee", "rightAnkle")
        let required = ["leftShoulder", "rightShoulder", "leftHip", "rightHip", "leftKnee", "rightKnee", "leftAnkle", "rightAnkle"]
        fullBodyVisible = required.allSatisfy { points[$0] != nil }
        if observation.error != nil {
            headline = "这一帧未完成检测"
            guidance = "图像仍来自当前相机帧；检测错误会计入统计。"
        } else if observation.bodyCount > 1 {
            headline = "画面中有 \(observation.bodyCount) 人"
            guidance = "请让画面中只保留你一人，以免混淆关节。"
        } else if observation.bodyCount == 0 {
            headline = "还没看见完整人体"
            guidance = "站到镜头前，让身体有足够光线，并与背景拉开距离。"
        } else if points["leftShoulder"] == nil || points["rightShoulder"] == nil {
            headline = "肩部还不够清楚"
            guidance = "将上身移入画面，避免遮住双肩，并增加正面光线。"
        } else if points["leftHip"] == nil || points["rightHip"] == nil {
            headline = "已看见上身，髋部未完整入镜"
            guidance = "稍微后退并调整镜头，让腰部和双腿进入画面。"
        } else if points["leftAnkle"] == nil || points["rightAnkle"] == nil {
            headline = "脚踝还未完整入镜"
            guidance = "再后退一点或降低镜头，把双脚和脚踝放入画面。"
        } else if !fullBodyVisible {
            headline = "膝部关键点不够清楚"
            guidance = "避免腿部互相遮挡，让双膝都能被镜头看见。"
        } else if required.contains(where: { name in
            guard let point = points[name] else { return false }
            return point.x < 0.04 || point.x > 0.96 || point.y < 0.035 || point.y > 0.97
        }) {
            headline = "全身已入镜，靠近画面边缘"
            guidance = "稍微后退或向画面中央移动，为舞步留出空间。"
        } else {
            headline = "全身已入镜"
            guidance = "肩、髋、膝与踝均可见，可以开始跟练。"
        }
    }

    public static func isVisible(_ point: LivePosePoint) -> Bool {
        point.x.isFinite && point.y.isFinite && point.confidence.isFinite &&
        (0...1).contains(point.x) && (0...1).contains(point.y) && (confidenceThreshold...1).contains(point.confidence)
    }

    public static func angle(a: LivePosePoint?, vertex: LivePosePoint?, c: LivePosePoint?, width: Int, height: Int) -> Double? {
        guard width > 0, height > 0, let a, let vertex, let c,
              isVisible(a), isVisible(vertex), isVisible(c) else { return nil }
        let ax = (a.x - vertex.x) * Double(width), ay = (a.y - vertex.y) * Double(height)
        let cx = (c.x - vertex.x) * Double(width), cy = (c.y - vertex.y) * Double(height)
        let an = hypot(ax, ay), cn = hypot(cx, cy)
        guard an >= 2, cn >= 2 else { return nil }
        let cosine = min(1, max(-1, (ax * cx + ay * cy) / (an * cn)))
        let result = acos(cosine) * 180 / .pi
        return result.isFinite ? result : nil
    }
}
