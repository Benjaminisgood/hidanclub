import SwiftUI

enum ClubPage: String, CaseIterable, Identifiable {
    case training = "训练台", library = "动作库", video = "视频练习", sequence = "我的 32 拍", history = "练习记录", resources = "资源与研究"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .training: return "square.grid.2x2"
        case .library: return "figure.dance"
        case .video: return "play.rectangle"
        case .sequence: return "square.stack.3d.up"
        case .history: return "calendar"
        case .resources: return "books.vertical"
        }
    }
}

struct ContentView: View {
    @ObservedObject var training: TrainingStore
    @ObservedObject var music: MusicService
    @ObservedObject var video: VideoService
    @ObservedObject var analyzer: PoseAnalyzer
    @State private var selection: ClubPage? = .training

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        BrandIcon(size: 43)
                        Text("hidan").font(.system(size: 31, weight: .black, design: .rounded)).tracking(-1.5)
                    }
                    Text("DANCE. LEARN. REPEAT.").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1.6).foregroundStyle(.secondary)
                }.padding(.horizontal, 24).padding(.top, 25).padding(.bottom, 30)
                List(ClubPage.allCases, selection: $selection) { page in
                    Label(page.rawValue, systemImage: page.icon).padding(.vertical, 5).tag(page)
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    Label("属于你的练习空间", systemImage: "sparkle").font(.caption).foregroundStyle(.secondary)
                    Text("一步一步，找到自己的风格。").font(.caption2).foregroundStyle(.tertiary)
                }.padding(20)
            }.navigationSplitViewColumnWidth(min: 195, ideal: 210, max: 250)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch selection ?? .training {
                    case .training: TrainingView(store: training, music: music)
                    case .library: MoveLibraryView()
                    case .video: VideoPracticeView(video: video, analyzer: analyzer)
                    case .sequence: SequenceView(music: music)
                    case .history: HistoryView(store: training)
                    case .resources: ResourcesView()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let error = training.persistenceError {
                    HStack {
                        Text(error).font(.caption).foregroundStyle(.red)
                        Spacer()
                        if training.canRetrySaving { Button("重试保存") { training.retrySaving() } }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.red.opacity(0.06))
                }
                MusicBar(music: music)
            }.background(ClubTheme.accent.opacity(0.025))
        }
    }
}
