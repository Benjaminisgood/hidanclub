import SwiftUI
import AppKit

@main struct HidanClubApp: App {
    @NSApplicationDelegateAdaptor(ClubAppDelegate.self) private var appDelegate
    @StateObject private var training = TrainingStore()
    @StateObject private var music = MusicService()
    @StateObject private var video = VideoService()
    @StateObject private var analyzer = PoseAnalyzer()

    var body: some Scene {
        WindowGroup("Hidan Club") {
            ContentView(training: training, music: music, video: video, analyzer: analyzer)
                .tint(ClubTheme.accent)
                .frame(minWidth: 1100, minHeight: 740)
                .onAppear {
                    training.onPauseForSleep = { music.pause(); video.pause() }
                    appDelegate.beforeTerminate = { training.stop(); training.retrySaving(); music.stop(); analyzer.cancel() }
                }
                .onChange(of: training.clock.state) { _, newValue in
                    if newValue == .completed || newValue == .stopped { music.stop() }
                }
        }.defaultSize(width: 1280, height: 850)
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandMenu("练习") {
                    Button("播放 / 暂停音乐") { music.toggle() }.keyboardShortcut("m", modifiers: [.command])
                    Button("暂停训练") { training.pause(); music.pause(); video.pause() }.keyboardShortcut(".", modifiers: [.command])
                }
            }
        Settings {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    BrandIcon(size: 64)
                    Text("Hidan Club").font(.title2.bold())
                }
                Text("本地优先的街舞学习原型 · 0.1").foregroundStyle(.secondary)
                Text("训练记录保存在这台 Mac。视频分析在本机完成，不向云端上传；导入媒体只在当前会话引用，重新打开应用需重新选择。")
                Button("打开训练记录目录") {
                    try? FileManager.default.createDirectory(at: training.dataDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(training.dataDirectory)
                }
                Text("本版未接入 MusicKit、实时摄像头、自动舞步分类或评分。详细路线见项目 docs。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(width: 440)
        }
    }
}

@MainActor final class ClubAppDelegate: NSObject, NSApplicationDelegate {
    var beforeTerminate: (() -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = BrandAssets.applicationIcon { NSApp.applicationIconImage = icon }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { beforeTerminate?() }
}
