import SwiftUI
import HidanCore

struct SequenceView: View {
    @ObservedObject var music: MusicService
    @State private var style: DanceStyle = .hipHop
    @State private var bpm = 85.0
    @State private var selected: Set<String> = []
    @State private var sequence: DanceSequence?
    @State private var error: String?
    @State private var seed = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Eyebrow(text: "SEQUENCE BUILDER / 我的 32 拍")
                Text("让熟悉的动作，连起来。").font(.system(size: 30, weight: .bold))
                Text("选择你已经会的动作，按规则编排四组八拍。保留自己的表达空间。").foregroundStyle(.secondary)
                ClubCard {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            Picker("舞种", selection: $style) { ForEach(DanceStyle.allCases) { Text($0.displayName).tag($0) } }.frame(width: 230)
                                .onChange(of: style) { _, _ in selected = []; sequence = nil }
                            Spacer()
                            Text("\(Int(bpm)) BPM").monospacedDigit()
                            Slider(value: $bpm, in: 50...130, step: 1).frame(width: 170)
                        }
                        Text("已掌握动作").font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)], alignment: .leading, spacing: 16) {
                            ForEach(DanceCatalog.moves.filter { $0.style == style }) { move in
                                Toggle(isOn: Binding(get: { selected.contains(move.id) }, set: { if $0 { selected.insert(move.id) } else { selected.remove(move.id) } })) {
                                    VStack(alignment: .leading, spacing: 4) { Text(move.englishName).font(.callout); Text(move.name).font(.caption).foregroundStyle(.secondary) }
                                }.toggleStyle(.checkbox)
                            }
                        }
                        Button("生成练习组合", systemImage: "square.grid.3x3.topleft.filled") { generate() }.buttonStyle(.borderedProminent).disabled(selected.isEmpty)
                    }
                }
                if let sequence {
                    Button("以 \(Int(sequence.bpm)) BPM 播放原创节拍", systemImage: "play.circle") {
                        music.useBeat(); music.bpm = sequence.bpm; music.play()
                    }
                    HStack(spacing: 14) {
                        ForEach(Array(sequence.slots.enumerated()), id: \.offset) { index, slot in
                            VStack(alignment: .leading, spacing: 18) {
                                Text(String(format: "%02d", index + 1)).font(.system(size: 44, weight: .light, design: .rounded)).foregroundStyle(ClubTheme.accent.opacity(0.7))
                                Text(DanceCatalog.move(id: slot.moveID)?.englishName ?? slot.moveID).font(.headline).frame(height: 42, alignment: .top)
                                HStack(spacing: 3) { ForEach(1...8, id: \.self) { n in Text("\(n)").font(.system(size: 9, design: .monospaced)).frame(maxWidth: .infinity).padding(.vertical, 5).background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 3)) } }
                            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                        }
                    }
                    ForEach(sequence.warnings, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                    Text("每次只换一个要素：方向、幅度或手臂。先用自然站姿连接，衔接不顺时增加准备拍。").foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
                Text("此处使用动作库与约束规则，未调用生成式 AI，也未生成新的三维动作。组合的连贯性和教学价值仍需舞者实际检查。").font(.caption).foregroundStyle(.secondary)
            }.padding(32)
        }.onChange(of: bpm) { _, _ in sequence = nil }
            .onChange(of: selected) { _, _ in sequence = nil }
    }
    private func generate() {
        do {
            sequence = try SequenceBuilder.make(moveIDs: selected.sorted(), catalog: DanceCatalog.moves, bpm: bpm, seed: seed)
            seed += 1; error = nil
        } catch { self.error = error.localizedDescription; sequence = nil }
    }
}
