import AppKit
import SwiftUI
import HidanCore

enum ClubPage: String, CaseIterable, Identifiable {
    case library = "动作库", basics = "基本功", video = "视频库", music = "音乐库", sequence = "编排库", history = "练习记录", settings = "设置", resources = "资源与研究"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .library: return "figure.dance"
        case .basics: return "figure.walk"
        case .video: return "play.rectangle"
        case .music: return "music.note.list"
        case .sequence: return "square.stack.3d.up"
        case .history: return "calendar"
        case .settings: return "gearshape"
        case .resources: return "books.vertical"
        }
    }
}

struct ContentView: View {
    @ObservedObject var training: TrainingStore
    @ObservedObject var music: MusicService
    let video: VideoService
    @ObservedObject var analyzer: PoseAnalyzer
    @ObservedObject var aist: AISTLibraryStore
    @ObservedObject var demonstration: TrainingDemonstrationStore
    let camera: LivePoseCamera
    @ObservedObject var captured: CapturedMotionStore
    @ObservedObject var arrangements: AISTArrangementStore
    @ObservedObject var videoLibrary: VideoLibraryStore
    @ObservedObject var published: CapturedLibraryStore
    @ObservedObject var practiceMotions: PracticeMotionStore
    @ObservedObject var musicLibrary: MusicLibraryStore
    @State private var trainingSource: TrainingSource = .none
    @State private var selection: ClubPage? = .library
    @State private var practicing = false
    @State private var showMotionDetail = false
    @State private var aistFilters = AISTLibraryFilters()
    @State private var practiceFilters = MoveLibraryFilters()
    @State private var musicPractice: (() -> Void)?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var practiceFullscreen = false
    @State private var sidebarBeforeFullscreen: NavigationSplitViewVisibility?
    @State private var enteredWindowFullscreen = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        BrandIcon(size: 43)
                        Text("hidan").font(.system(size: 31, weight: .black, design: .rounded)).tracking(-1.5)
                    }
                    Text("DANCE. LEARN. REPEAT.").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1.6).foregroundStyle(.secondary)
                }.padding(.horizontal, 24).padding(.top, 36).padding(.bottom, 18)
                List(ClubPage.allCases, selection: sidebarSelection) { page in
                    Label(page.rawValue, systemImage: page.icon).padding(.vertical, 5).tag(page)
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    Label("属于你的练习空间", systemImage: "sparkle").font(.caption).foregroundStyle(.secondary)
                    Text("一步一步，找到自己的风格。").font(.caption2).foregroundStyle(.tertiary)
                }.padding(20)
            }.navigationSplitViewColumnWidth(min: 195, ideal: 210, max: 250)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    if practicing {
                        TrainingView(store: training, music: music, demonstration: demonstration, camera: camera,
                                     captured: captured, practice: practiceMotions, source: $trainingSource,
                                     fullscreen: $practiceFullscreen, onBack: {
                            leavePractice()
                        })
                    } else {
                        switch selection ?? .library {
                        case .library:
                            AISTLibraryView(store: aist, training: training, music: music, musicLibrary: musicLibrary, arrangements: arrangements, clips: published,
                                            filters: $aistFilters, showDetail: $showMotionDetail,
                                            openTraining: { beginPractice(.aist) }, offerMusicPractice: { musicPractice = $0 },
                                            practiceClip: practiceCaptured, canPracticeClip: !training.active)
                        case .basics:
                            MoveLibraryView(filters: $practiceFilters, motions: practiceMotions, music: music, trainingActive: training.active, startPractice: { moves, title in
                                practiceGenerated(moves, title: title)
                            }, offerMusicPractice: { musicPractice = $0 })
                        case .music:
                            MusicLibraryView(music: music, library: musicLibrary)
                        case .video:
                            VideoLibraryView(library: videoLibrary, video: video, captured: captured, published: published,
                                             onRecord: recordPractice, onPractice: {
                                guard !training.active else { return }
                                video.pause(); demonstration.pause(); captured.pause()
                                beginPractice(.captured)
                            }, canPractice: !training.active)
                        case .sequence:
                            SequenceView(arrangements: arrangements, published: published, onPracticeAIST: { references, name in
                                do {
                                    if training.active { demonstration.stop() }
                                    try training.prepareArrangement(references: references, name: name)
                                    beginPractice(.aist)
                                } catch { arrangements.errorMessage = error.localizedDescription }
                            }, practiceClip: practiceCaptured, canPracticeClip: !training.active)
                        case .history: HistoryView(store: training)
                        case .settings:
                            PracticeSettingsView(aist: aist, trainingDirectory: training.dataDirectory, musicDirectory: musicLibrary.directory) {
                                demonstration.applyCoordinatePreference()
                            }
                        case .resources: ResourcesView()
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let error = training.persistenceError {
                    HStack {
                        Text(error).font(.caption).foregroundStyle(.red)
                        Spacer()
                        if training.canRetrySaving { Button("重试保存") { training.retrySaving() } }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.red.opacity(0.06))
                }
                MusicBar(music: music, library: musicLibrary, onPlayToggle: musicPlayAction, motionBPM: practiceMotionBPM, onOpenLibrary: {
                    if practicing { leavePractice() }
                    selection = .music
                })
            }.background(ClubTheme.accent.opacity(0.025))
        }
        .toolbar(.hidden, for: .windowToolbar)
        .onChange(of: practiceFullscreen) { _, on in
            if on {
                if columnVisibility != .detailOnly { sidebarBeforeFullscreen = columnVisibility }
                columnVisibility = .detailOnly
                if let window = NSApp.keyWindow ?? NSApp.mainWindow, !window.styleMask.contains(.fullScreen) {
                    enteredWindowFullscreen = true
                    window.toggleFullScreen(nil)
                }
            } else {
                columnVisibility = sidebarBeforeFullscreen ?? .all
                sidebarBeforeFullscreen = nil
                if enteredWindowFullscreen {
                    enteredWindowFullscreen = false
                    if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.styleMask.contains(.fullScreen) {
                        window.toggleFullScreen(nil)
                    }
                }
            }
        }
        .onChange(of: practicing) { _, on in if !on, practiceFullscreen { practiceFullscreen = false } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard enteredWindowFullscreen, let window = note.object as? NSWindow,
                  window == NSApp.keyWindow || window == NSApp.mainWindow else { return }
            enteredWindowFullscreen = false
            if practiceFullscreen { practiceFullscreen = false }
        }
    }

    private var sidebarSelection: Binding<ClubPage?> {
        Binding(get: { selection }, set: { page in
            if practicing { leavePractice() }
            selection = page
        })
    }

    private func leavePractice() {
        demonstration.stop()
        practiceMotions.pause()
        captured.pause()
        aist.pause()
        practicing = false
        if practiceFullscreen { practiceFullscreen = false }
    }

    private var practiceMotionBPM: Double? {
        guard practicing else { return nil }
        switch trainingSource {
        case .aist: return demonstration.reference?.sequence.bpm.map(Double.init) ?? demonstration.player.selected?.bpm.map(Double.init)
        case .generated: return practiceMotions.beatBPM
        case .captured, .none: return nil
        }
    }

    private var musicPlayAction: (() -> Void)? {
        if practicing && trainingSource != .none { return togglePracticePlayback }
        if musicPractice != nil { return startPracticeFromMusic }
        return nil
    }

    private func startPracticeFromMusic() {
        musicPractice?()
        guard practicing else { return }
        if music.isPlaying {
            setPracticeMotion(playing: true)
        } else {
            if !music.isPaused { alignPracticeDownbeat() }
            music.play()
            setPracticeMotion(playing: music.isPlaying)
        }
    }

    private func togglePracticePlayback() {
        if music.isPlaying {
            music.pause()
            setPracticeMotion(playing: false)
        } else {
            if !music.isPaused { alignPracticeDownbeat() }
            music.play()
            setPracticeMotion(playing: music.isPlaying)
        }
    }

    /// A fresh play starts the motion and the beat on the same downbeat.
    private func alignPracticeDownbeat() {
        switch trainingSource {
        case .aist:
            demonstration.player.seek(demonstration.player.loopStart)
        case .generated:
            practiceMotions.seek(0)
        case .captured, .none:
            break
        }
        if music.sourceURL == nil { music.stop() }
    }

    private func setPracticeMotion(playing: Bool) {
        switch trainingSource {
        case .aist:
            demonstration.setReferencePlaying(playing)
        case .generated:
            if playing { practiceMotions.play() } else { practiceMotions.pause() }
        case .captured:
            if playing { captured.playback.play() } else { captured.playback.pause() }
        case .none:
            break
        }
    }

    private func beginPractice(_ source: TrainingSource) {
        trainingSource = source
        practicing = true
    }

    private func recordPractice() {
        guard !training.active else { beginPractice(trainingSource); return }
        video.pause(); demonstration.pause(); captured.pause(); aist.pause()
        beginPractice(.none)
    }

    private func practiceGenerated(_ moves: [DanceMove], title: String) {
        if training.active { demonstration.stop() }
        let stored = UserDefaults.standard.object(forKey: "training.defaultRounds") as? Int ?? 4
        let rounds = [2, 4, 6].contains(stored) ? stored : 4
        do {
            try training.prepareMovePractice(name: title.isEmpty ? (moves.first?.name ?? "基本功") : title, rounds: rounds)
            video.pause(); demonstration.pause(); aist.pause(); captured.pause()
            beginPractice(.generated)
        } catch {
            practiceMotions.pause()
        }
    }

    private func practiceCaptured(_ model: CapturedMotion) {
        if training.active { demonstration.stop() }
        video.pause(); demonstration.pause(); aist.pause(); captured.pause()
        captured.select(model)
        beginPractice(.captured)
    }
}
