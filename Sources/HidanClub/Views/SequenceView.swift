import SwiftUI
import HidanCore

struct SequenceView: View {
    @ObservedObject var arrangements: AISTArrangementStore
    @ObservedObject var published: CapturedLibraryStore
    var onPracticeAIST: ([AISTPracticeReference], String) -> Void
    var practiceClip: (CapturedMotion) -> Void
    var canPracticeClip: Bool
    @State private var importNotice: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Eyebrow(text: "SEQUENCE LIBRARY")
                        Text("编排库").font(.system(size: 28, weight: .bold))
                        Text("把动作库里的片段排成一套，再开始练习。基本功里的四段连播直接播放动作。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    LibraryImportButton(title: "导入编排 JSON…", destination: .arrangements,
                                        store: published, notice: $importNotice)
                        .help("从动作模型 JSON 文件导入一整套编排，保留片段顺序和重复次数")
                }
                draftEditor
                if let error = arrangements.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                savedArrangements
                CapturedArrangementSection(published: published, notice: $importNotice,
                                           practiceClip: practiceClip, canPracticeClip: canPracticeClip)
            }.padding(26)
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
                                .help("向前移动片段").disabled(index == 0 || !arrangements.canEditDraft)
                            Button { perform { try arrangements.moveDraft(at: index, by: 1) } } label: { Image(systemName: "arrow.down") }
                                .help("向后移动片段").disabled(index == arrangements.draft.count - 1 || !arrangements.canEditDraft)
                            Button { perform { try arrangements.removeDraft(at: index) } } label: { Image(systemName: "minus.circle") }
                                .help("从草稿移除片段").disabled(!arrangements.canEditDraft)
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

/// Published 2D arrangements: imported from JSON files or sent here from the
/// video library. Each entry is an independent copy of a complete model, so it
/// keeps every original frame, segment order and repetition. Kept as its own
/// view so the section can be reviewed without the page's scroll container.
struct CapturedArrangementSection: View {
    @ObservedObject var published: CapturedLibraryStore
    @Binding var notice: String?
    var practiceClip: (CapturedMotion) -> Void
    var canPracticeClip: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("视频动作编排 · \(published.arrangements.count)").font(.title3.weight(.semibold))
                Spacer()
                if published.isLoading { ProgressView().controlSize(.small) }
            }
            Text("二维动作模型排成的整套编排，保留片段顺序、重复次数和全部原始帧。导入只读取原文件，保存的是独立副本。")
                .font(.callout).foregroundStyle(.secondary)
            LibraryImportStatus(store: published, notice: notice)
            if let error = published.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if published.arrangements.isEmpty && !published.isLoading {
                Text("还没有视频动作编排。用「导入编排 JSON…」选择动作模型文件，或在视频库里把整套片段发布到这里。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(published.arrangements) { model in capturedCard(model) }
        }
    }

    private func capturedCard(_ model: CapturedMotion) -> some View {
        ClubCard {
            HStack(alignment: .top, spacing: 16) {
                ClippedPoseThumbnail(model: model)
                    .frame(width: 104, height: 128)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.name).font(.headline)
                    Text("\(model.segments.count) 个片段 · 原片段 \(seconds(sourceDuration(model))) 秒 · 播放 \(seconds(planDuration(model))) 秒 · \(model.frameCount) 帧")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(model.segments.enumerated().map { index, segment in
                        "\(index + 1). \(segment.name)（\(segment.startFrame)–\(segment.endFrame) 帧\(segment.repeats > 1 ? " ×\(segment.repeats)" : "")）"
                    }.joined(separator: " → ")).font(.callout).foregroundStyle(.secondary)
                    Text(model.qualityNotice).font(.caption2).foregroundStyle(.secondary)
                    if let method = model.arrangementMethod {
                        Text(method).font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 10) {
                        Button("练习这套", systemImage: "play.fill") { practiceClip(model) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canPracticeClip || !model.hasPlayableMotion)
                            .accessibilityIdentifier("sequence.captured.practice.\(model.id.uuidString)")
                        if !canPracticeClip { Text("先结束当前练习，再练这一套。").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    private func sourceDuration(_ model: CapturedMotion) -> Double {
        model.segments.reduce(0) { $0 + model.duration(of: $1) }
    }

    private func planDuration(_ model: CapturedMotion) -> Double {
        model.segments.reduce(0) { $0 + model.duration(of: $1) * Double($1.repeats) }
    }

    private func seconds(_ value: Double) -> String { String(format: "%.2f", value) }
}
