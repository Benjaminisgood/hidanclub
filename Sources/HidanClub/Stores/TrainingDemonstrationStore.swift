import Foundation
import Combine
import HidanCore

/// Owns the training player so browsing the atlas cannot replace a running drill.
@MainActor final class TrainingDemonstrationStore: ObservableObject {
    let training: TrainingStore
    let player: AISTLibraryStore
    @Published private(set) var reference: AISTPracticeReference?
    @Published private(set) var issue: String?
    private var subscriptions: Set<AnyCancellable> = []
    private var catalogKey: String?
    private var waitingToResume: AISTPracticeReference?
    private var previewing = false
    private var referenceHeld = false
    private var playWhenReady = false
    private var synchronizing = false

    init(training: TrainingStore, player: AISTLibraryStore? = nil) {
        self.training = training; self.player = player ?? AISTLibraryStore()
        training.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.synchronize() }.store(in: &subscriptions)
        self.player.$loading.receive(on: RunLoop.main).sink { [weak self] _ in self?.synchronize() }.store(in: &subscriptions)
        self.player.$errorMessage.receive(on: RunLoop.main).sink { [weak self] _ in self?.synchronize() }.store(in: &subscriptions)
        synchronize()
    }

    var isReady: Bool {
        guard let reference else { return false }
        return training.hasDemonstrations && !player.loading && player.errorMessage == nil && player.motion != nil
            && player.selected == reference.sequence && player.optimized == reference.optimized
            && player.loopStart == reference.startFrame && player.loopEnd == reference.endFrame
    }
    var isCurrentDrill: Bool { training.currentReference != nil }
    var stageLabel: String {
        if !training.active { return "动作预览 · 不计入训练" }
        if isCurrentDrill { return training.clock.state == .paused ? "跟练已暂停" : "当前动作 · 循环跟练" }
        if training.snapshot.currentBlock?.kind == .cooldown { return "放松时间 · 动作回看" }
        return "\(training.snapshot.currentBlock?.kind.displayName ?? "准备") · 下个动作预览"
    }

    func synchronize() {
        guard !synchronizing else { return }
        synchronizing = true
        defer { synchronizing = false; objectWillChange.send() }
        if training.usesGeneratedDemonstration {
            player.pause(); previewing = false; referenceHeld = false; waitingToResume = nil; setIssue(nil); return
        }
        installCatalogIfNeeded()
        let target = targetReference()
        if target != reference {
            previewing = false; referenceHeld = false; waitingToResume = nil; player.pause()
            reference = target
            if let target { player.restoreReference(target) }
        }
        guard reference != nil, training.hasDemonstrations else {
            if training.clock.state == .running { training.pause() }
            player.pause()
            setIssue(player.errorMessage ?? training.demonstrationError ?? (player.loading ? nil : "当前计划没有完整动作示范。请载入动作库后重新生成计划。"))
            return
        }
        if let error = player.errorMessage {
            waitingToResume = nil; previewing = false
            if training.clock.state == .running { training.pause() }
            player.pause(); setIssue("示范暂不可用，训练已暂停：\(error)"); return
        }
        if !isReady {
            if training.clock.state == .running {
                waitingToResume = reference
                training.pause()
            }
            setIssue(nil); return
        }
        setIssue(nil)
        if playWhenReady {
            playWhenReady = false
            previewing = training.clock.state != .running
            referenceHeld = false
            if !player.isPlaying { player.play() }
        }
        if waitingToResume == reference, training.clock.state == .paused {
            waitingToResume = nil; training.resume()
        }
        let shouldPlay = !referenceHeld && (training.clock.state == .running || previewing)
        if shouldPlay && !player.isPlaying { player.play() }
        if !shouldPlay && player.isPlaying { player.pause() }
    }

    @discardableResult func startOrResume() -> Bool {
        referenceHeld = false; previewing = false; synchronize()
        guard isReady else { setIssue(issue ?? "等待动作示范载入后即可开始。"); return false }
        if training.clock.state == .paused { training.resume() } else { training.start() }
        synchronize(); return training.clock.state == .running
    }
    func pause() { waitingToResume = nil; previewing = false; referenceHeld = false; training.pause(); player.pause(); synchronize() }
    func advance() {
        // A quick second skip during loading retains the user's running intent;
        // an explicit pause still cancels it through pause().
        let intendedRunning = training.clock.state == .running || waitingToResume != nil
        waitingToResume = nil; previewing = false; referenceHeld = false; training.advance()
        if intendedRunning && training.clock.state == .paused { training.resume() }
        synchronize()
    }
    func stop() { waitingToResume = nil; previewing = false; referenceHeld = false; training.stop(); player.pause(); synchronize() }
    func setReferencePlaying(_ playing: Bool) {
        guard player.motion != nil else { return }
        if playing {
            referenceHeld = false
            previewing = training.clock.state != .running
            if player.motion == nil || player.loading {
                playWhenReady = true
            } else {
                playWhenReady = false
                if !player.isPlaying { player.play() }
            }
        } else {
            playWhenReady = false
            previewing = false
            referenceHeld = true
            if player.isPlaying { player.pause() }
        }
    }
    func toggleReferencePlayback() { setReferencePlaying(!player.isPlaying) }
    func togglePreview() { toggleReferencePlayback() }
    func reload() {
        pause(); catalogKey = nil; reference = nil; player.reload()
    }

    func applyCoordinatePreference() {
        guard !training.active else { return }
        catalogKey = nil
        synchronize()
    }

    private func targetReference() -> AISTPracticeReference? {
        if training.clock.state == .completed || training.clock.state == .stopped {
            return training.plan.blocks.compactMap { training.reference(for: $0) }.first
        }
        let index = training.snapshot.blockIndex
        let upcoming = training.plan.blocks.dropFirst(index).compactMap { training.reference(for: $0) }.first
        return upcoming ?? training.plan.blocks.compactMap { training.reference(for: $0) }.last
    }
    private func setIssue(_ value: String?) { if issue != value { issue = value } }

    private func installCatalogIfNeeded() {
        guard let manifest = player.manifest else { return }
        let key = player.directory.path + manifest.sourceSHA256
        guard key != catalogKey else { return }
        struct Catalog: Decodable {
            struct Entry: Decodable {
                let id: String; let style: DanceStyle; let genreCode: String
                let choreographyCode: String; let name: String; let observationCue: String
            }
            let entries: [Entry]
        }
        do {
            let bundle: Bundle
            if let url = Bundle.main.url(forResource: "HidanClub_HidanClub", withExtension: "bundle"), let packaged = Bundle(url: url) { bundle = packaged }
            else { bundle = .module }
            guard let url = bundle.url(forResource: "training-moves", withExtension: "json", subdirectory: "Resources/AIST") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
            let moves = try catalog.entries.map { entry -> AISTTrainingMove in
                let candidates = manifest.sequences.filter {
                    $0.genreCode == entry.genreCode && $0.choreographyCode == entry.choreographyCode && $0.isBasic && !$0.ignored
                }.sorted { ($0.bpm ?? 999, $0.id) < ($1.bpm ?? 999, $1.id) }
                guard let sequence = candidates.first else { throw AISTTrainingPlanError.invalidDemonstration(entry.id) }
                let optimized = UserDefaults.standard.string(forKey: CoordinateLayerPreference.key) != "raw"
                let reference = try AISTPracticeReference(sequence: sequence, name: entry.name, startFrame: 0,
                                                          endFrame: sequence.frameCount - 1, optimized: optimized, speed: 0.5)
                return AISTTrainingMove(id: entry.id, style: entry.style, reference: reference, observationCue: entry.observationCue)
            }
            training.configureDemonstrations(moves); catalogKey = key
        } catch { setIssue("动作示范目录读取失败：\(error.localizedDescription)") }
    }
}
