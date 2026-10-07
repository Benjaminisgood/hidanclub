import SwiftUI
import HidanCore

@MainActor
final class SessionHistoryStore: ObservableObject {
    @Published private(set) var sessions: [FinishedSession] = []
    private let key = "ios.history.finishedSessions"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([FinishedSession].self, from: data) {
            sessions = decoded
        }
    }

    func add(_ session: FinishedSession) {
        sessions.insert(session, at: 0)
        persist()
    }

    func clear() {
        sessions = []
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

@MainActor
final class TrainingSessionModel: ObservableObject {
    @Published var snapshot: TrainingSnapshot?
    private var clock: TrainingClock?
    private var timer: Timer?

    func start(plan: TrainingPlan) {
        var clock = TrainingClock(plan: plan)
        _ = clock.start()
        self.clock = clock
        snapshot = clock.snapshot()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func pause() {
        _ = clock?.pause()
        if let clock { snapshot = clock.snapshot() }
    }

    func resume() {
        _ = clock?.resume()
        if let clock { snapshot = clock.snapshot() }
    }

    var isActive: Bool { snapshot?.state == .running }
    var isPaused: Bool { snapshot?.state == .paused }
    var isFinished: Bool { snapshot?.isCompleted == true }

    func stop() -> FinishedSession? {
        timer?.invalidate(); timer = nil
        guard var clock else { return nil }
        _ = clock.stop()
        snapshot = clock.snapshot()
        self.clock = nil
        return clock.finishedSession()
    }

    func cancel() {
        timer?.invalidate(); timer = nil
        clock = nil
        snapshot = nil
    }

    private func tick() {
        guard var clock else { return }
        _ = clock.tick()
        if clock.isCompleted {
            timer?.invalidate(); timer = nil
        }
        snapshot = clock.snapshot()
        self.clock = clock
    }
}

struct TrainingTab: View {
    @EnvironmentObject private var history: SessionHistoryStore
    @StateObject private var session = TrainingSessionModel()
    @State private var style: DanceStyle = .hipHop
    @State private var minutes: Int = 15
    @State private var level: Int = 1
    @State private var plan: TrainingPlan?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let snapshot = session.snapshot, session.isActive || session.isPaused || session.isFinished {
                        sessionRunner(snapshot: snapshot)
                    } else {
                        planBuilder
                    }
                }
                .padding()
            }
            .navigationTitle("训练")
        }
    }

    private var planBuilder: some View {
        VStack(alignment: .leading, spacing: 14) {
            ClubCardIOS {
                VStack(alignment: .leading, spacing: 10) {
                    EyebrowIOS(text: "PLAN BUILDER")
                    Text("生成练习计划").font(.headline)
                    Picker("风格", selection: $style) {
                        ForEach(DanceStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.menu)
                    Picker("时长（分钟）", selection: $minutes) {
                        ForEach([10, 15, 20, 30, 45], id: \.self) { value in
                            Text("\(value)").tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker("等级", selection: $level) {
                        Text("入门").tag(1)
                        Text("基础进阶").tag(2)
                    }
                    .pickerStyle(.segmented)
                    Button {
                        buildPlan()
                    } label: {
                        Label("生成计划", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red)
            }

            if let plan {
                ClubCardIOS {
                    VStack(alignment: .leading, spacing: 8) {
                        EyebrowIOS(text: "PLAN")
                        Text(plan.title).font(.headline)
                        Text("共 \(plan.blocks.count) 段 · 约 \(plan.totalSeconds / 60) 分钟")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(plan.blocks) { block in
                            HStack(alignment: .top, spacing: 8) {
                                Text(block.kind.displayName)
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(kindColor(block.kind).opacity(0.2), in: Capsule())
                                    .foregroundStyle(kindColor(block.kind))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(block.title).font(.subheadline.weight(.medium))
                                    Text(block.cue).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(block.durationSeconds / 60):\(String(format: "%02d", block.durationSeconds % 60))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button {
                            session.start(plan: plan)
                        } label: {
                            Label("开始练习", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(ClubThemeIOS.lime.opacity(0.9))
                        .foregroundStyle(.black)
                    }
                }
                Text(PlanBuilder.planningNotice)
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func sessionRunner(snapshot: TrainingSnapshot) -> some View {
        ClubCardIOS {
            VStack(alignment: .leading, spacing: 12) {
                EyebrowIOS(text: "SESSION")
                if let block = snapshot.currentBlock {
                    Text(block.title).font(.title3.bold())
                    Text(block.kind.displayName).font(.caption).foregroundStyle(.secondary)
                    Text(block.cue).font(.callout)
                } else if snapshot.isCompleted {
                    Text("练习完成").font(.title3.bold())
                }
                Text(timeString(snapshot.remainingSeconds))
                    .font(.system(size: 56, weight: .bold, design: .rounded).monospacedDigit())
                ProgressView(value: Double(snapshot.completedBlocks),
                             total: Double(max(1, snapshot.totalBlocks)))
                Text("第 \(snapshot.blockIndex + 1) / \(snapshot.totalBlocks) 段 · 已活动 \(Int(snapshot.activeSeconds)) 秒")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if session.isActive {
                        Button { session.pause() } label: { Label("暂停", systemImage: "pause.fill") }
                            .buttonStyle(.bordered)
                    } else if session.isPaused {
                        Button { session.resume() } label: { Label("继续", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent)
                    }
                    Button(role: .destructive) {
                        if let finished = session.stop() { history.add(finished) }
                        session.cancel()
                    } label: {
                        Label(snapshot.isCompleted ? "记录并退出" : "结束", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                }
                if snapshot.isCompleted {
                    Text("全部段落完成。可以结束本次练习并写入练习录。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func buildPlan() {
        do {
            plan = try PlanBuilder.make(durationMinutes: minutes, style: style, level: level,
                                        seed: Int(Date().timeIntervalSince1970) % 9973)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func kindColor(_ kind: TrainingBlockKind) -> Color {
        switch kind {
        case .warmup: return ClubThemeIOS.peach
        case .drill: return ClubThemeIOS.accent
        case .rest: return .gray
        case .freestyle: return ClubThemeIOS.lime
        case .cooldown: return .teal
        }
    }

    private func timeString(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
