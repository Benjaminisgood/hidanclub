import SwiftUI

enum ClubTheme {
    static let accent = Color(nsColor: .systemIndigo)
    static let lime = Color(red: 0.73, green: 0.89, blue: 0.37)
    static let peach = Color(red: 0.97, green: 0.63, blue: 0.47)
    static let pageInset: CGFloat = 24
    static let cornerRadius: CGFloat = 16
    static let stage = Color(red: 0.055, green: 0.065, blue: 0.09)
}

struct Eyebrow: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
    }
}

struct ClubCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ClubTheme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: ClubTheme.cornerRadius).strokeBorder(.primary.opacity(0.08)))
    }
}

struct ClubPageTitle: View {
    let title: String
    let eyebrow: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: eyebrow)
            Text(title).font(.system(size: 28, weight: .bold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

func clockText(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded(.up)))
    return String(format: "%02d:%02d", s / 60, s % 60)
}
