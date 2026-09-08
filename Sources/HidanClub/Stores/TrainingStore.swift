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
    @Published private(set) var history: [FinishedSession] = []
    @Published var persistenceError: String?
    private var savingBlocked = false
    private let stateURL: URL
    private var timer: Timer?
    private var sleepObserver: NSObjectProtocol?
    var onPauseForSleep: (() -> Void)?

    var active: Bool { clock.state == .running || clock.state == .paused }
    var snapshot: TrainingSnapshot { clock.snapshot() }
    var dataDirectory: URL { stateURL.deletingLastPathComponent() }
    var canRetrySaving: Bool { !savingBlocked }

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
        do { plan = try PlanBuilder.make(durationMinutes: minutes, style: style, level: level); clock = TrainingClock(plan: plan) }
        catch { persistenceError = error.localizedDescription }
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
