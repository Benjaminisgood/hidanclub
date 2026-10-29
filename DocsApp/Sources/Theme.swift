import SwiftUI

enum Theme {
    static let accentPurple = Color(red: 0.58, green: 0.34, blue: 0.98)
    static let accentCyan = Color(red: 0.13, green: 0.83, blue: 0.93)
    static let accentMagenta = Color(red: 0.96, green: 0.29, blue: 0.69)
    static let accentLime = Color(red: 0.65, green: 0.93, blue: 0.26)

    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [accentPurple, accentCyan],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var heroGradient: LinearGradient {
        LinearGradient(
            colors: [accentMagenta, accentPurple, accentCyan],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    static let contentMaxWidth: CGFloat = 720

    static let codeBackground = Color(red: 0.09, green: 0.09, blue: 0.13)
    static let codeForeground = Color(red: 0.93, green: 0.94, blue: 0.98)

    static func cardBackground(scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(white: 0.13)
            : Color(white: 0.99)
    }

    static func cardStroke(scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(white: 0.22)
            : Color(white: 0.88)
    }

    static func quoteBackground(scheme: ColorScheme) -> Color {
        scheme == .dark
            ? accentPurple.opacity(0.12)
            : accentPurple.opacity(0.07)
    }

    static let highlightColor = Color.yellow.opacity(0.45)
}

extension Color {
    static let docsAccent = Theme.accentPurple
}
