import SwiftUI
import AppKit

@main struct HidanClubApp: App {
    @NSApplicationDelegateAdaptor(ClubAppDelegate.self) private var appDelegate
    @StateObject private var training: TrainingStore
    @StateObject private var demonstration: TrainingDemonstrationStore
    @StateObject private var camera = LivePoseCamera()
    @StateObject private var captured = CapturedMotionStore()
    @StateObject private var arrangements = AISTArrangementStore()
    @StateObject private var music = MusicService()
    @StateObject private var video = VideoService()
    @StateObject private var analyzer = PoseAnalyzer()
    @StateObject private var aist = AISTLibraryStore()
    @StateObject private var videoLibrary = VideoLibraryStore()
    @StateObject private var published = CapturedLibraryStore()
    @StateObject private var practiceMotions = PracticeMotionStore()
    @State private var resumeMusicAfterPause = false
    @State private var recordingImports: [UUID: Task<Void, Never>] = [:]
    @State private var recoveryStarted = false
    @State private var isTerminating = false

    init() {
        let store = TrainingStore()
        _training = StateObject(wrappedValue: store)
        _demonstration = StateObject(wrappedValue: TrainingDemonstrationStore(training: store))
    }

    var body: some Scene {
        WindowGroup(Bundle.main.bundleIdentifier?.contains(".qa.") == true ? "Hidan QA · 隔离测试" : "Hidan Club") {
            ContentView(training: training, music: music, video: video, analyzer: analyzer, aist: aist, demonstration: demonstration, camera: camera, captured: captured, arrangements: arrangements, videoLibrary: videoLibrary, published: published, practiceMotions: practiceMotions)
                .disabled(isTerminating)
                .overlay {
                    if isTerminating {
                        ProgressView("正在保存录像与视频库…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .tint(ClubTheme.accent)
                .frame(minWidth: 1100, minHeight: 740)
                .onAppear {
                    camera.onRecordingSaved = { url in
                        let importID = UUID()
                        recordingImports[importID] = Task {
                            await videoLibrary.importVideo(url: url, source: .trainingRecording)
                            recordingImports.removeValue(forKey: importID)
                        }
                    }
                    appDelegate.prepareToTerminate = { completion in
                        isTerminating = true
                        camera.stop {
                            Task {
                                for task in Array(recordingImports.values) { await task.value }
                                while videoLibrary.isImporting || published.isImporting || captured.isSaving || captured.isExporting {
                                    try? await Task.sleep(for: .milliseconds(50))
                                }
                                videoLibrary.cancelAnalysis()
                                completion()
                            }
                        }
                    }
                    if !recoveryStarted {
                        recoveryStarted = true
                        Task {
                            do { await videoLibrary.recoverFinishedRecordings(from: try CameraMovieRecorder.pendingDirectory()) }
                            catch { videoLibrary.errorMessage = "录像恢复目录无法打开：\(error.localizedDescription)" }
                        }
                    }
                    training.onPauseForSleep = { demonstration.pause(); music.pause(); video.pause(); aist.pause(); camera.stop(); captured.pause(); practiceMotions.pause() }
                    appDelegate.beforeTerminate = { demonstration.stop(); training.retrySaving(); music.stop(); analyzer.cancel(); aist.pause(); camera.stop(); captured.pause(); practiceMotions.pause() }
                }
                .onChange(of: training.clock.state) { _, newValue in
                    if newValue == .paused {
                        resumeMusicAfterPause = music.isPlaying; music.pause()
                    } else if newValue == .running && resumeMusicAfterPause {
                        resumeMusicAfterPause = false; music.play()
                    } else if newValue == .completed || newValue == .stopped {
                        resumeMusicAfterPause = false; music.stop(); aist.pause()
                    }
                }
        }.defaultSize(width: 1280, height: 850)
            .windowStyle(.hiddenTitleBar)
            .windowToolbarStyle(.unifiedCompact(showsTitle: false))
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandMenu("练习") {
                    Button("播放 / 暂停音乐") { music.toggle() }.keyboardShortcut("m", modifiers: [.command])
                    Button("暂停训练") { demonstration.pause(); music.pause(); video.pause(); aist.pause(); captured.pause() }.keyboardShortcut(".", modifiers: [.command])
                }
            }
        Settings {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    BrandIcon(size: 64)
                    Text("Hidan Club").font(.title2.bold())
                }
                Text("本地优先的街舞学习原型 · 0.4.0").foregroundStyle(.secondary)
                Text("导入视频与训练录像保存在这台 Mac 的视频库，重启后仍可播放。身体关节识别在本机完成，不向云端上传。")
                Button("打开训练记录目录") {
                    try? FileManager.default.createDirectory(at: training.dataDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(training.dataDirectory)
                }
                Text("视频库保存原视频，并在本页识别肢体。截出的一段收入动作库，编排库只排列这些动作。当前识别为二维关节，不自动命名舞步或评分。外观和默认画面在应用内的设置页。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(width: 440)
        }
    }
}

@MainActor final class ClubAppDelegate: NSObject, NSApplicationDelegate {
    var beforeTerminate: (() -> Void)?
    var prepareToTerminate: ((@escaping () -> Void) -> Void)?
    private var terminationPending = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = BrandAssets.applicationIcon { NSApp.applicationIconImage = icon }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let prepareToTerminate else { return .terminateNow }
        if !terminationPending {
            terminationPending = true
            prepareToTerminate { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { beforeTerminate?() }
}
