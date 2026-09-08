import SwiftUI
import HidanCore

struct MoveLibraryView: View {
    @State private var query = ""
    @State private var style: DanceStyle?
    @State private var selected: DanceMove?
    private var filtered: [DanceMove] {
        DanceCatalog.moves.filter { (style == nil || $0.style == style) && (query.isEmpty || ($0.name + $0.englishName + $0.summary).localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Eyebrow(text: "MOVEMENT LIBRARY / 动作词汇")
                HStack(alignment: .lastTextBaseline) {
                    Text("先有律动，再有动作。").font(.system(size: 30, weight: .bold))
                    Spacer(); Text("\(DanceCatalog.moves.count) 个基础练习").foregroundStyle(.secondary)
                }
                Text("从小幅、清晰的身体感知开始，积累自己的动作语言。").foregroundStyle(.secondary)
                HStack {
                    TextField("搜索动作 / English name", text: $query).textFieldStyle(.roundedBorder).frame(width: 300)
                    Spacer()
                    Picker("舞种", selection: $style) {
                        Text("全部舞种").tag(Optional<DanceStyle>.none)
                        ForEach(DanceStyle.allCases) { Text($0.displayName).tag(Optional($0)) }
                    }.frame(width: 220)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 18)], spacing: 18) {
                    ForEach(filtered) { move in
                        Button { selected = move } label: {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    Image(systemName: icon(move.style)).font(.system(size: 29, weight: .light)).foregroundStyle(ClubTheme.accent)
                                    Spacer()
                                    Text(move.levelName).font(.caption2.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 5).background(.primary.opacity(0.05), in: Capsule())
                                }.frame(height: 52)
                                Text(move.englishName).font(.system(size: 18, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                                Text(move.name).foregroundStyle(.secondary)
                                Divider()
                                HStack { Text(move.style.displayName); Spacer(); Text(move.bpmLabel) }.font(.caption2).foregroundStyle(.secondary)
                            }.padding(21).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.07)))
                        }.buttonStyle(.plain)
                    }
                }
                if filtered.isEmpty { ContentUnavailableView.search(text: query) }
                Text(DanceCatalog.contentNotice).font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }.padding(32)
        }.sheet(item: $selected) { move in MoveDetailSheet(move: move) }
    }
    private func icon(_ style: DanceStyle) -> String {
        switch style { case .hipHop: return "waveform.path"; case .popping: return "hand.draw"; case .locking: return "hand.point.up.left"; case .house: return "figure.dance" }
    }
}

struct MoveDetailSheet: View {
    let move: DanceMove
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack { Eyebrow(text: move.style.displayName.uppercased()); Spacer(); Button("完成") { dismiss() } }
                Text(move.englishName).font(.system(size: 32, weight: .bold))
                Text(move.name).font(.title2).foregroundStyle(.secondary)
                Text(move.summary).font(.body)
                HStack(spacing: 15) { Label(move.bpmLabel, systemImage: "metronome"); Text(move.levelName); Text(move.impact.displayName) }.font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("练习提示").font(.headline)
                ForEach(Array(move.cues.enumerated()), id: \.offset) { index, cue in
                    HStack(alignment: .top, spacing: 14) {
                        Text("\(index + 1)").font(.caption.bold()).frame(width: 24, height: 24).background(ClubTheme.accent.opacity(0.12), in: Circle()).foregroundStyle(ClubTheme.accent)
                        Text(cue).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("留意这些习惯").font(.headline)
                ForEach(move.commonMistakes, id: \.self) { Text("•  " + $0).foregroundStyle(.secondary) }
                if !move.prerequisites.isEmpty {
                    Text("先练：" + move.prerequisites.compactMap { DanceCatalog.move(id: $0)?.englishName }.joined(separator: "、")).font(.callout)
                }
                Text("这是原创文字练习卡。完整动作与风格细节需要结合有权观看的示范或教师指导；BPM 为可调整的练习起点。").font(.caption).foregroundStyle(.secondary)
            }.padding(32)
        }.frame(width: 560, height: 650)
    }
}
