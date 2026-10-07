import SwiftUI
import HidanCore

struct HistoryTab: View {
    @EnvironmentObject private var history: SessionHistoryStore

    var body: some View {
        NavigationStack {
            Group {
                if history.sessions.isEmpty {
                    ContentUnavailableView("还没有练习记录",
                                           systemImage: "calendar",
                                           description: Text("在「训练」页完成一次练习后，记录会出现在这里。"))
                } else {
                    List {
                        ForEach(history.sessions) { session in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.planTitle).font(.headline)
                                Text("\(formatted(session.date)) · 活动 \(Int(session.activeSeconds / 60)) 分钟 · 完成 \(session.completedBlocks)/\(session.totalBlocks) 段")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("练习录")
            .toolbar {
                if !history.sessions.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("清空", role: .destructive) { history.clear() }
                    }
                }
            }
        }
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

struct AboutTab: View {
    @StateObject private var resources = AISTResourceStore()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ClubCardIOS {
                        HStack(spacing: 12) {
                            if let logo = resources.logo {
                                Image(uiImage: logo)
                                    .resizable().scaledToFit()
                                    .frame(width: 52, height: 52)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                EyebrowIOS(text: "HIDANCLUB · IOS")
                                Text("HidanClub").font(.title.bold())
                            }
                        }
                        Text("舞蹈基本功与 AIST 练习应用的 iOS 版本。动作库、训练计划、4×8 拍编排与练习录基于与 macOS 版共享的 HidanCore 引擎；「AIST」页直接读取随包分发的 AIST 曲库 JSON。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ClubCardIOS {
                        VStack(alignment: .leading, spacing: 6) {
                            EyebrowIOS(text: "CONTENT NOTICE")
                            Text("内容与安全").font(.headline)
                            Text(DanceCatalog.contentNotice).font(.callout)
                            Text(PlanBuilder.planningNotice).font(.callout)
                            Text(DanceSequence.generationNotice).font(.callout)
                        }
                    }
                    ClubCardIOS {
                        VStack(alignment: .leading, spacing: 6) {
                            EyebrowIOS(text: "DATASET")
                            Text("AIST++ 数据").font(.headline)
                            Text("「AIST」页加载随包的 AIST/training-moves.json 与 choreography-names.json；骨架预览使用 HidanCore 内置的练习动作数据（PracticeMotionLibrary），不依赖本机 AIST++ 数据集。完整的 AIST++ 骨架回放、视频库与相机跟练仍在 macOS 版本提供。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if let url = Bundle.main.url(forResource: "NOTICE", withExtension: "md") {
                        ClubCardIOS {
                            VStack(alignment: .leading, spacing: 6) {
                                EyebrowIOS(text: "NOTICE")
                                Text((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("关于")
        }
    }
}
