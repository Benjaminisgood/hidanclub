import SwiftUI
import HidanCore

struct TrainingView: View {
    @ObservedObject var store: TrainingStore
    @ObservedObject var music: MusicService
    @State private var selectedMove: DanceMove?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                hero
                HStack(alignment: .top, spacing: 22) {
                    planList.frame(maxWidth: .infinity)
                    VStack(spacing: 20) { focusCard; rhythmCard }.frame(width: 285)
                }
                Text("先整理出不会滑倒、能自由伸展的空间。保持舒适呼吸；不适时暂停。练习时长与 BPM 是可调整起点，基础动作提示尚未经教练审核。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(32)
        }.sheet(item: $selectedMove) { MoveDetailSheet(move: $0) }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 9) {
                Eyebrow(text: "HIDAN CLUB / 每天，跳一点")
                Text("把今天，交给节奏。").font(.system(size: 31, weight: .bold))
                Text("从一个舒服的律动开始，给自己一点练习的空间。").foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(Date(), format: .dateTime.month(.wide).day()).font(.callout.weight(.medium))
                Text("YOUR DAILY PRACTICE").font(.system(size: 9, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
            }
        }
    }

    private var hero: some View {
        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 26).fill(ClubTheme.accent.gradient)
            GrooveArtwork().frame(width: 300, height: 250).padding(.trailing, 25).opacity(0.9).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 15) {
                Text(store.active ? "IN THE GROOVE" : "TODAY’S SESSION").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2).opacity(0.75)
                Text(heroTitle).font(.system(size: 29, weight: .bold)).frame(maxWidth: 430, alignment: .leading)
                if store.active {
                    Text(clockText(store.snapshot.remainingSeconds)).font(.system(size: 55, weight: .light, design: .rounded)).monospacedDigit()
                    Text(store.clock.state == .paused ? "已暂停 · 按自己的节奏继续" : (store.snapshot.currentBlock?.cue ?? "")).font(.callout).frame(maxWidth: 420, alignment: .leading)
                } else {
                    Text("\(store.minutes) 分钟 · \(store.style.displayName) · \(store.level == 1 ? "入门" : "基础进阶")").opacity(0.8)
                    Text("热身  /  分解  /  组合  /  放松").font(.callout).opacity(0.8)
                }
                HStack(spacing: 12) {
                    Button(action: primaryAction) {
                        Label(primaryTitle, systemImage: store.clock.state == .running ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 17).padding(.vertical, 9)
                    }.buttonStyle(.plain).background(ClubTheme.lime, in: Capsule()).foregroundStyle(Color.black.opacity(0.85))
                    if store.active {
                        Button("下一段") { store.advance(); if !store.active { music.stop() } }.buttonStyle(.plain).padding(.horizontal, 8)
                        Button("结束") { store.stop(); music.stop() }.buttonStyle(.plain).opacity(0.8)
                    }
                }.padding(.top, 4)
            }.foregroundStyle(.white).padding(30).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: 270)
    }
    private var heroTitle: String {
        if store.active { return store.snapshot.currentBlock?.title ?? "练习" }
        if store.clock.state == .completed { return "今天的练习，完成了。" }
        if store.clock.state == .stopped { return "每一点练习，都算数。" }
        return "找到你的基础律动"
    }
    private var primaryTitle: String {
        switch store.clock.state {
        case .running: return "暂停练习"
        case .paused: return "继续练习"
        case .completed, .stopped: return "再练一次"
        case .idle: return "开始练习"
        }
    }
    private func primaryAction() {
        switch store.clock.state {
        case .running: store.pause(); music.pause()
        case .paused: store.resume(); music.play()
        default: store.start(); music.play()
        }
    }
    private var planList: some View {
        ClubCard {
            VStack(alignment: .leading, spacing: 17) {
                HStack {
                    Text("今天怎么练").font(.title3.weight(.semibold)); Spacer()
                    Text("\(store.plan.blocks.count) 段").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Picker("舞种", selection: $store.style) { ForEach(DanceStyle.allCases) { Text($0.displayName).tag($0) } }.labelsHidden()
                    Picker("时长", selection: $store.minutes) { ForEach([10, 15, 20, 30, 45], id: \.self) { Text("\($0) 分钟").tag($0) } }.labelsHidden().frame(width: 105)
                }.disabled(store.active)
                    .onChange(of: store.style) { _, _ in store.rebuild() }
                    .onChange(of: store.minutes) { _, _ in store.rebuild() }
                Picker("练习层级", selection: $store.level) {
                    Text("入门 · 先找律动").tag(1)
                    Text("基础进阶 · 加入协调").tag(2)
                }.pickerStyle(.segmented).disabled(store.active)
                    .onChange(of: store.level) { _, _ in store.rebuild() }
                Divider()
                ForEach(Array(store.plan.blocks.enumerated()), id: \.element.id) { index, block in
                    HStack(spacing: 13) {
                        Text(String(format: "%02d", index + 1)).font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(isCurrent(index) ? ClubTheme.accent : .secondary)
                            .frame(width: 31, height: 31).background(isCurrent(index) ? ClubTheme.accent.opacity(0.12) : Color.primary.opacity(0.04), in: Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text(block.title).font(.system(size: 12, weight: isCurrent(index) ? .bold : .medium))
                            Text(block.kind.displayName).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(clockText(Double(block.durationSeconds))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if let id = block.moveID, let move = DanceCatalog.move(id: id) {
                            Button { selectedMove = move } label: { Image(systemName: "info.circle") }.buttonStyle(.plain).foregroundStyle(.secondary).help("查看动作提示")
                        }
                    }
                }
            }
        }
    }
    private func isCurrent(_ index: Int) -> Bool { store.active && store.snapshot.blockIndex == index }
    private var focusCard: some View {
        ClubCard {
            VStack(alignment: .leading, spacing: 15) {
                Eyebrow(text: "ONE THING AT A TIME")
                Image(systemName: "figure.dance").font(.system(size: 35, weight: .light)).foregroundStyle(ClubTheme.accent)
                Text("今天，先练稳定。").font(.title3.weight(.semibold))
                Text("动作可以小一点。听见节拍，感受重心，再让手臂加入。").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack { Text("此刻的用力感").font(.caption); Spacer(); Text("\(store.effort) / 10").font(.caption.monospacedDigit()) }
                Slider(value: Binding(get: { Double(store.effort) }, set: { store.effort = Int($0) }), in: 1...10, step: 1)
                Text("自我记录，不是 AI 测量；结束时保存。").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    private var rhythmCard: some View {
        ClubCard {
            VStack(alignment: .leading, spacing: 16) {
                Eyebrow(text: "FEEL THE EIGHT / 八拍")
                TimelineView(.periodic(from: .now, by: 0.05)) { _ in
                    HStack(spacing: 5) {
                        ForEach(0..<8) { beat in
                            Text("\(beat + 1)").font(.system(size: 11, weight: .semibold, design: .rounded))
                                .frame(maxWidth: .infinity).frame(height: 29)
                                .background(music.currentBeat == beat ? ClubTheme.lime : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                                .foregroundStyle(music.currentBeat == beat ? Color.black.opacity(0.8) : .primary)
                        }
                    }
                }
                Text(music.sourceURL == nil ? "跟随原创节拍的音频播放进度。" : "本地音乐尚未标注节拍；用耳朵找到第一拍。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct GrooveArtwork: View {
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width * 0.55, y: size.height * 0.53)
            for i in 0..<5 {
                let r = CGFloat(40 + i * 23)
                context.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)), with: .color(.white.opacity(0.13)), lineWidth: 1)
            }
            var stroke = Path()
            stroke.move(to: CGPoint(x: 53, y: 159))
            stroke.addCurve(to: CGPoint(x: 222, y: 97), control1: CGPoint(x: 6, y: 22), control2: CGPoint(x: 304, y: 249))
            stroke.addCurve(to: CGPoint(x: 155, y: 196), control1: CGPoint(x: 168, y: -14), control2: CGPoint(x: 65, y: 236))
            context.stroke(stroke, with: .color(ClubTheme.lime), style: StrokeStyle(lineWidth: 26, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: 175, y: 29, width: 40, height: 40)), with: .color(ClubTheme.peach))
            context.draw(Text("MOVE.").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(4).foregroundColor(.white.opacity(0.7)), at: CGPoint(x: 248, y: 224))
        }
    }
}
