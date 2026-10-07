import SwiftUI

enum ClubThemeIOS {
    static let accent = Color.indigo
    static let lime = Color(red: 0.73, green: 0.89, blue: 0.37)
    static let peach = Color(red: 0.97, green: 0.63, blue: 0.47)
    static let stage = Color(red: 0.055, green: 0.065, blue: 0.09)
    static let cornerRadius: CGFloat = 16
}

struct EyebrowIOS: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(2)
            .foregroundStyle(.secondary)
    }
}

struct ClubCardIOS<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ClubThemeIOS.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: ClubThemeIOS.cornerRadius).strokeBorder(.primary.opacity(0.08)))
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            AISTLibraryTab()
                .tabItem { Label("AIST", systemImage: "square.grid.2x2") }
            MoveLibraryTab()
                .tabItem { Label("动作库", systemImage: "figure.dance") }
            TrainingTab()
                .tabItem { Label("训练", systemImage: "timer") }
            SequenceTab()
                .tabItem { Label("编排", systemImage: "square.stack.3d.up") }
            HistoryTab()
                .tabItem { Label("练习录", systemImage: "calendar") }
            AboutTab()
                .tabItem { Label("关于", systemImage: "books.vertical") }
        }
    }
}
