import Foundation

/// Presentation choices only. They never select, transform or export source data.
enum AISTVisualStyle: String, CaseIterable, Identifiable {
    case porcelain, neon, skeleton
    var id: String { rawValue }
    var title: String {
        switch self {
        case .porcelain: return "柔光人形"
        case .neon: return "霓虹人形"
        case .skeleton: return "经典骨架"
        }
    }
    var subtitle: String {
        switch self {
        case .porcelain: return "立体轮廓 · 柔和光影"
        case .neon: return "双色身体 · 夜色舞台"
        case .skeleton: return "原版样式 · 关节与连线"
        }
    }
    var symbol: String {
        switch self {
        case .porcelain: return "figure.stand"
        case .neon: return "sparkles"
        case .skeleton: return "point.3.connected.trianglepath.dotted"
        }
    }
}
