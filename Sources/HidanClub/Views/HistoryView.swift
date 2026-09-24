import SwiftUI
import HidanCore
import UniformTypeIdentifiers

struct HistoryView: View {
    @ObservedObject var store: TrainingStore
    @State private var error: String?
    private var total: Double { store.history.reduce(0) { $0 + $1.activeSeconds } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    ClubPageTitle(title: "练习录", eyebrow: "PRACTICE JOURNAL", subtitle: "看见一点一滴的积累。")
                    Spacer()
                    Button("导出记录", systemImage: "square.and.arrow.up") { export() }.disabled(store.history.isEmpty)
                }
                HStack(spacing: 20) {
                    stat("练习录", "\(store.history.count)", "次已结束的练习")
                    stat("累计流程时长", String(format: "%.1f", total / 60), "分钟 · 含休息，不含暂停")
                    stat("完整练习段落", "\(store.history.reduce(0) { $0 + $1.completedBlocks })", "跳过的段落不计入")
                }
                if store.history.isEmpty {
                    ContentUnavailableView("第一段练习，等你开始", systemImage: "calendar.badge.clock", description: Text("结束训练后，这里会保存实际时长、完成段落和用力感。"))
                        .frame(minHeight: 260)
                }
                ForEach(store.history) { session in
                    ClubCard {
                        HStack(spacing: 20) {
                            Image(systemName: "checkmark.circle").font(.title2).foregroundStyle(ClubTheme.accent)
                            VStack(alignment: .leading, spacing: 7) {
                                Text(session.planTitle).font(.headline)
                                Text(session.date, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 7) {
                                Text(clockText(session.activeSeconds)).font(.title3.monospacedDigit())
                                Text("\(session.completedBlocks) / \(session.totalBlocks) 段 · 用力感 \(session.perceivedEffort.map(String.init) ?? "未记录")").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.padding(ClubTheme.pageInset)
        }
    }
    private func stat(_ title: String, _ value: String, _ detail: String) -> some View {
        ClubCard { VStack(alignment: .leading, spacing: 9) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(size: 35, weight: .semibold, design: .rounded)); Text(detail).font(.caption2).foregroundStyle(.secondary) } }
    }
    private func export() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "hidan-training-history.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.export(to: url) } catch { self.error = error.localizedDescription }
    }
}
