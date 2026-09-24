import SwiftUI
import HidanCore

struct SequenceView: View {
    @ObservedObject var arrangements: AISTArrangementStore
    var onPracticeAIST: ([AISTPracticeReference], String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 7) {
                    Eyebrow(text: "SEQUENCE LIBRARY")
                    Text("编排库").font(.system(size: 28, weight: .bold))
                    Text("把动作库里的片段排成一套，再开始练习。基本功里的四段连播直接播放动作。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                draftEditor
                if let error = arrangements.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                savedArrangements
            }.padding(ClubTheme.pageInset)
        }
    }

    private var draftEditor: some View {
        ClubCard {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Label("正在编排", systemImage: "square.stack.3d.up").font(.headline)
                    Spacer()
                    Text("\(arrangements.draft.count) 个片段").font(.caption).foregroundStyle(.secondary)
                    Button("新建空白编排") { perform { try arrangements.newDraft() } }
                        .disabled(!arrangements.canEditDraft)
                }
                HStack {
                    TextField("编排名称", text: Binding(get: { arrangements.draftName }, set: { value in perform { try arrangements.renameDraft(value) } }))
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 360).disabled(!arrangements.canEditDraft)
                    Spacer()
                    Button("保存编排", systemImage: "square.and.arrow.down") { perform { _ = try arrangements.saveDraft(name: arrangements.draftName) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(arrangements.draft.isEmpty || arrangements.draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !arrangements.canEditDraft)
                }
                if arrangements.draft.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("还没有动作片段").font(.headline)
                        Text("在动作里设好 A–B，再点「加入编排」。").font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 20)
                } else {
                    ForEach(Array(arrangements.draft.enumerated()), id: \.offset) { index, reference in
                        HStack(spacing: 12) {
                            Text(String(format: "%02d", index + 1)).font(.system(size: 22, weight: .light, design: .rounded))
                                .foregroundStyle(ClubTheme.accent).frame(width: 32)
                            referenceDescription(reference)
                            Spacer(minLength: 8)
                            Button { perform { try arrangements.moveDraft(at: index, by: -1) } } label: { Image(systemName: "arrow.up") }
                                .accessibilityLabel("向前移动片段").help("向前移动片段").disabled(index == 0 || !arrangements.canEditDraft)
                            Button { perform { try arrangements.moveDraft(at: index, by: 1) } } label: { Image(systemName: "arrow.down") }
                                .accessibilityLabel("向后移动片段").help("向后移动片段").disabled(index == arrangements.draft.count - 1 || !arrangements.canEditDraft)
                            Button { perform { try arrangements.removeDraft(at: index) } } label: { Image(systemName: "minus.circle") }
                                .accessibilityLabel("从草稿移除片段").help("从草稿移除片段").disabled(!arrangements.canEditDraft)
                        }.padding(.vertical, 5)
                        if index < arrangements.draft.count - 1 { Divider() }
                    }
                }
                Text("原片段合计 \(seconds(arrangements.sourceDuration)) 秒 · 按所选速度播放 \(seconds(arrangements.duration)) 秒")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text("四段八拍是编排习惯。这里保留实际片段长度，不强制截成 32 拍；不同片段的音乐拍点尚未自动对齐。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var savedArrangements: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("已保存的编排 · \(arrangements.saved.count)").font(.title3.weight(.semibold))
            if arrangements.saved.isEmpty {
                Text("保存后的动作编排会出现在这里。").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(arrangements.saved) { arrangement in
                ClubCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(arrangement.name).font(.headline)
                                Text("\(arrangement.references.count) 个动作 · 原片段 \(seconds(arrangement.sourceDuration)) 秒 · 播放 \(seconds(arrangement.duration)) 秒")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("编辑") { perform { try arrangements.loadDraft(arrangement) } }.disabled(!arrangements.canEditDraft)
                            Button("练习这套", systemImage: "play.fill") { onPracticeAIST(arrangement.references, arrangement.name) }
                                .buttonStyle(.borderedProminent)
                        }
                        Text(arrangement.references.map(\.name).joined(separator: " → ")).font(.callout).foregroundStyle(.secondary)
                        Text("按顺序分段跟练 · 每段循环 60 秒 · 间歇 20 秒").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func referenceDescription(_ reference: AISTPracticeReference) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(reference.name).font(.callout.weight(.semibold))
            Text("\(reference.frameCount) 帧 · 原片段 \(seconds(reference.sourceDuration)) 秒 · \(reference.speedLabel) · \(reference.layerLabel)")
                .font(.caption).foregroundStyle(.secondary)
            Text(reference.sourceLabel).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
    private func seconds(_ value: Double) -> String { String(format: "%.2f", value) }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { arrangements.errorMessage = error.localizedDescription }
    }
}
