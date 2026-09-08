import SwiftUI

enum ClubTheme {
    static let accent = Color(red: 0.35, green: 0.39, blue: 0.94)
    static let lime = Color(red: 0.73, green: 0.89, blue: 0.37)
    static let peach = Color(red: 0.97, green: 0.63, blue: 0.47)
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
        content.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.primary.opacity(0.06)))
    }
}

func clockText(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded(.up)))
    return String(format: "%02d:%02d", s / 60, s % 60)
}
