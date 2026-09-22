import Foundation
import SwiftUI
import HidanCore
import AppKit

@MainActor final class TrainingStore: ObservableObject {
    @Published var style: DanceStyle = .hipHop
    @Published var minutes = 20
    @Published var level = 1
    @Published var effort = 4
    @Published private(set) var plan: TrainingPlan
    @Published private(set) var clock: TrainingClock
    @Published private(set) var reference: AISTPracticeReference?
    @Published private(set) var isCustomPlan = false
    @Published private(set) var usesGeneratedDemonstration = false
    @Published private(set) var referencesByBlockID: [String: AISTPracticeReference] = [:]
    @Published private(set) var demonstrationError: String?
    @Published private(set) var history: [FinishedSession] = []
    @Published var persistenceError: String?
    private var savingBlocked = false
    private let stateURL: URL
    private var timer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var demonstrationMoves: [AISTTrainingMove] = []
    var onPauseForSleep: (() -> Void)?

    var active: Bool { clock.state == .running || clock.state == .paused }
    var snapshot: TrainingSnapshot { clock.snapshot() }
    var dataDirectory: URL { stateURL.deletingLastPathComponent() }
    var canRetrySaving: Bool { !savingBlocked }
    var hasConfiguredDemonstrations: Bool { !demonstrationMoves.isEmpty }
    var hasDemonstrations: Bool {
        let practice = plan.blocks.filter { $0.kind == .drill || $0.kind == .freestyle }
        return !practice.isEmpty && practice.allSatisfy { referencesByBlockID[$0.id] != nil }
    }
    var currentReference: AISTPracticeReference? { snapshot.currentBlock.flatMap { reference(for: $0) } }

    func reference(for block: TrainingBlock) -> AISTPracticeReference? { referencesByBlockID[block.id] }

    func configureDemonstrations(_ moves: [AISTTrainingMove]) {
        guard moves != demonstrationMoves else { return }
        demonstrationMoves = moves
        guard !active, !isCustomPlan else { return }
        rebuild()
    }

    init() {
        let initial = try! PlanBuilder.make(durationMinutes: 20, style: .hipHop)
        plan = initial; clock = TrainingClock(plan: initial)
        let directory = ProcessInfo.processInfo.environment["HIDAN_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HidanClub", isDirectory: true)
        stateURL = directory.appendingPathComponent("history.json")
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pause(); self.onPauseForSleep?()
            }
        }
    }

    func rebuild() {
        guard !active else { return }
        do {
            let rebuilt: TrainingPlan
            let references: [String: AISTPracticeReference]
            if demonstrationMoves.isEmpty {
                rebuilt = try PlanBuilder.make(durationMinutes: minutes, style: style, level: level)
                references = [:]
            } else {
                let result = try AISTTrainingPlanBuilder.make(durationMinutes: minutes, style: style, level: level, moves: demonstrationMoves)
                rebuilt = result.plan; references = result.referencesByBlockID
            }
            plan = rebuilt; clock = TrainingClock(plan: rebuilt); reference = nil; isCustomPlan = false
            usesGeneratedDemonstration = false
            referencesByBlockID = references
            demonstrationError = nil
        }
        catch { demonstrationError = error.localizedDescription }
    }
    func prepareReference(_ reference: AISTPracticeReference, rounds: Int) throws {
        guard !active else { throw AISTPracticeError.trainingInProgress }
        let prepared = try AISTPracticePlanBuilder.make(reference: reference, rounds: rounds)
        let references = Dictionary(uniqueKeysWithValues: prepared.blocks.filter { $0.kind == .drill || $0.kind == .freestyle }.map { ($0.id, reference) })
        self.reference = reference; isCustomPlan = true; usesGeneratedDemonstration = false
        plan = prepared
        clock = TrainingClock(plan: prepared)
        referencesByBlockID = references
        demonstrationError = nil
    }
    func prepareArrangement(references: [AISTPracticeReference], name: String) throws {
        guard !active else { throw AISTPracticeError.trainingInProgress }
        guard !references.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AISTTrainingPlanError.invalidDemonstration(name)
        }
        for reference in references { try reference.validate() }
        let id = "arrangement-" + UUID().uuidString
        var blocks = [TrainingBlock(id: id + "-warmup", title: "准备进入编排", kind: .warmup,
                                    durationSeconds: 60, cue: "轻松活动肩、髋和脚踝。接下来按编排顺序逐段跟练。")]
        var mapping: [String: AISTPracticeReference] = [:]
        for (index, reference) in references.enumerated() {
            let blockID = id + "-drill-\(index)"
            blocks.append(TrainingBlock(id: blockID, title: reference.name, kind: .drill, durationSeconds: 60,
                                        cue: "第 \(index + 1) 段 / 共 \(references.count) 段 · 循环观察并跟练所选动作，保持舒适幅度。"))
            mapping[blockID] = reference
            if index + 1 < references.count {
                blocks.append(TrainingBlock(id: id + "-rest-\(index)", title: "休息与换段", kind: .rest,
                                            durationSeconds: 20, cue: "放松身体，观察接下来的片段。"))
            }
        }
        blocks.append(TrainingBlock(id: id + "-cooldown", title: "放松与回顾", kind: .cooldown,
                                    durationSeconds: 30, cue: "逐渐放慢动作，让呼吸恢复平稳。"))
        let prepared = TrainingPlan(id: id, title: name + " · 编排分段跟练", blocks: blocks)
        plan = prepared; clock = TrainingClock(plan: prepared); self.reference = nil
        referencesByBlockID = mapping; isCustomPlan = true; usesGeneratedDemonstration = false; demonstrationError = nil
    }

    func prepareMovePractice(name: String, rounds: Int) throws {
        guard !active else { throw AISTPracticeError.trainingInProgress }
        guard [2, 4, 6].contains(rounds) else { throw AISTPracticeError.invalidRounds }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw AISTPracticeError.missingName }
        let id = "practice-\(UUID().uuidString)"
        var blocks = [TrainingBlock(id: id + "-warmup", title: "先热身，找到舒适幅度", kind: .warmup, durationSeconds: 60,
                                    cue: "轻松活动肩、髋和脚踝。接下来跟随练习动作，幅度保持在自己舒服的范围。")]
        for round in 1...rounds {
            blocks.append(TrainingBlock(id: id + "-drill-\(round)", title: "\(title) · 第 \(round)/\(rounds) 组", kind: .drill,
                                        durationSeconds: 60, cue: "看着练习动作的时序平滑坐标跟练。这是应用生成的站立示范，不是影像捕捉，也不是评分。"))
            if round < rounds {
                blocks.append(TrainingBlock(id: id + "-rest-\(round)", title: "放松与回看", kind: .rest, durationSeconds: 20,
                                            cue: "停下来呼吸。需要的话把动作暂停，看清下一次的方向。"))
            }
        }
        blocks.append(TrainingBlock(id: id + "-cooldown", title: "慢慢回到平静", kind: .cooldown, durationSeconds: 30,
                                    cue: "逐渐放慢动作，让呼吸平稳。"))
        plan = TrainingPlan(id: id, title: title + " · \(rounds) 组", blocks: blocks)
        clock = TrainingClock(plan: plan)
        reference = nil
        referencesByBlockID = [:]
        isCustomPlan = true
        usesGeneratedDemonstration = true
        demonstrationError = nil
    }

    func start() {
        if clock.state == .completed || clock.state == .stopped { clock = TrainingClock(plan: plan) }
        clock.start(); tick()
    }
    func pause() { clock.pause(); recordIfFinished() }
    func resume() { clock.resume() }
    func advance() { clock.advance(); recordIfFinished() }
    func stop() { clock.stop(); recordIfFinished() }
    private func tick() {
        guard clock.state == .running else { return }
        clock.tick(); recordIfFinished()
    }
    private func recordIfFinished() {
        guard let session = clock.finishedSession(perceivedEffort: effort), !history.contains(where: { $0.id == session.id }) else { return }
        history.insert(session, at: 0); save()
    }

    private struct Archive: Codable { var version: Int; var sessions: [FinishedSession] }
    private func load() {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
        do {
            let data = try Data(contentsOf: stateURL)
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.version == 1 else { throw CocoaError(.coderReadCorrupt) }
            history = archive.sessions
        } catch {
            savingBlocked = true
            persistenceError = "训练记录无法读取，原文件已保留，自动保存已暂停。\(error.localizedDescription)"
        }
    }
    private func save() {
        guard !savingBlocked else { return }
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Archive(version: 1, sessions: history)).write(to: stateURL, options: .atomic)
            persistenceError = nil
        } catch { persistenceError = "记录暂未保存到磁盘：\(error.localizedDescription)" }
    }
    func retrySaving() { save() }
    func export(to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Archive(version: 1, sessions: history)).write(to: url, options: .atomic)
    }
}
