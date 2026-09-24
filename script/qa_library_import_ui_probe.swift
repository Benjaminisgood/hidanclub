// Run only through qa_library_import_ui.sh. The production import path fills an
// isolated library with a real exported motion file, then the production views
// are rendered offscreen so the result can be looked at. No window is opened,
// no click is simulated, and the user's real library is never touched.
import AppKit
import Foundation
import SwiftUI
import HidanCore

@main struct LibraryImportUIProbe {
    struct Failure: Error { let message: String }

    private final class Box<T> { var value: T?; var done = false }

    /// Drive main-actor work from a synchronous main so the run loop keeps
    /// pumping for SwiftUI, timers and the stores' detached loads.
    @MainActor static func drain<T>(_ body: @escaping @MainActor () async -> T) -> T {
        let box = Box<T>()
        Task { @MainActor in box.value = await body(); box.done = true }
        while !box.done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        guard let value = box.value else { fatalError("Drained task produced no value") }
        return value
    }

    @MainActor static func waitUntil(_ label: String, timeout: Double = 20, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw Failure(message: "Timed out waiting for \(label)") }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    @MainActor static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, scheme: ColorScheme = .light, to url: URL) throws {
        NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let framed = view.frame(width: width, height: height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme).tint(ClubTheme.accent)
            .buttonStyle(.bordered)
        // NSHostingView includes native text fields, menus and segmented controls
        // that ImageRenderer deliberately omits. This window is never ordered on screen.
        let host = NSHostingView(rootView: framed)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSApp.appearance
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw Failure(message: "Native snapshot failed: \(url.lastPathComponent)")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure(message: "PNG encoding failed: \(url.lastPathComponent)")
        }
        window.contentView = nil
        try png.write(to: url, options: .atomic)
    }

    @MainActor static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 5 else {
            throw Failure(message: "usage: LibraryImportUIProbe <library-dir> <arrangement-dir> <motion.json> <png-dir>")
        }
        let libraryDir = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let arrangementDir = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let sourceURL = URL(fileURLWithPath: arguments[3])
        let pngDir = URL(fileURLWithPath: arguments[4], isDirectory: true)
        try FileManager.default.createDirectory(at: pngDir, withIntermediateDirectories: true)
        let sourceBytes = try Data(contentsOf: sourceURL)

        NSApplication.shared.setActivationPolicy(.prohibited)

        // The same stores the pages observe, on isolated directories.
        let published = CapturedLibraryStore(directory: libraryDir)
        let arrangements = AISTArrangementStore(directory: arrangementDir)
        try waitUntil("library load") { !published.isLoading }
        guard arrangements.saved.isEmpty && arrangements.draft.isEmpty else {
            throw Failure(message: "AIST arrangement store must stay untouched by 2D imports")
        }
        guard published.actions.isEmpty && published.arrangements.isEmpty else {
            throw Failure(message: "Isolated library must start empty")
        }

        // Exactly what the 动作库 import button calls after the file picker returns.
        let actionResults = drain { await published.importFiles([sourceURL], to: .actions) }
        guard let action = actionResults.first?.published else {
            throw Failure(message: "Import failed: \(actionResults.first?.problem ?? "")")
        }
        guard published.arrangements.isEmpty else {
            throw Failure(message: "动作库导入不应写入编排库")
        }
        let notice = LibraryImportNotice.text(actionResults, destination: .actions)
        guard try Data(contentsOf: sourceURL) == sourceBytes else { throw Failure(message: "Source file changed") }

        // 动作库: the production player and controls an imported clip opens into.
        let playback = CapturedMotionPlayback()
        playback.prepare(action)
        let player = VStack(spacing: 14) {
            CapturedMotionPlayerView(playback: playback).frame(height: 430)
            CapturedMotionPreviewControls(playback: playback)
        }.padding(20)
        try render(player, width: 900, height: 640, to: pngDir.appendingPathComponent("action-player.png"))

        // The shared import control and its status line, with the real messages.
        try render(ImportControlHarness(store: published, notice: LibraryImportNotice.text(actionResults, destination: .actions)),
                   width: 900, height: 460, to: pngDir.appendingPathComponent("import-controls.png"))

        let actionCard = VStack(alignment: .leading, spacing: 10) {
            Text("我的").font(.headline)
            ClippedPoseThumbnail(model: action).frame(width: 220, height: 188).clipShape(RoundedRectangle(cornerRadius: ClubTheme.cornerRadius))
            Text(action.name).font(.system(size: 14, weight: .semibold))
            Text("视频截取 · \(String(format: "%.1f", action.segments.first.map { action.duration(of: $0) } ?? 0)) 秒")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(22)
        try render(actionCard, width: 320, height: 380, to: pngDir.appendingPathComponent("action-card.png"))

        // Compact/wide layouts use the same controls as the app. Appearance is
        // scoped to this offscreen process, never the user's system preference.
        let musicLibrary = MusicLibraryStore(directory: libraryDir.appendingPathComponent("music-ui"))
        try waitUntil("music library load") { !musicLibrary.isLoading }
        let music = MusicService()
        music.volume = 0
        for scheme in [ColorScheme.light, .dark] {
            let appearance = scheme == .light ? "light" : "dark"
            for width: CGFloat in [540, 900] {
                let name = "\(appearance)-\(Int(width))"
                try render(player, width: width, height: 640, scheme: scheme,
                           to: pngDir.appendingPathComponent("player-\(name).png"))
                music.useBeat()
                try render(MusicBar(music: music, library: musicLibrary), width: width, height: 180, scheme: scheme,
                           to: pngDir.appendingPathComponent("beat-\(name).png"))
                // Presentation-only long-title fixture; no audio is loaded or played.
                music.sourceURL = URL(fileURLWithPath: "/ui-fixture-not-played.wav")
                music.trackName = "用于检查长曲名与节拍控制换行的本地音乐"
                music.trackBPM = 128
                try render(MusicBar(music: music, library: musicLibrary), width: width, height: 180, scheme: scheme,
                           to: pngDir.appendingPathComponent("music-\(name).png"))
            }
        }
        music.stop()

        print("Library import UI probe passed: 动作库 player, import control and clip card rendered from real imports.")
        print("  action: \(action.name) · \(action.frameCount) 帧 · 片段 \(action.segments.map { "\($0.startFrame)-\($0.endFrame)x\($0.repeats)" }.joined(separator: ",")) · \(String(format: "%.2f", action.segments.reduce(0) { $0 + action.duration(of: $1) * Double($1.repeats) })) 秒")
        print("  notice: \(notice.replacingOccurrences(of: "\n", with: " / "))")
        print("  png: \(pngDir.path)")
    }
}

/// Hosts the production import button so its `@Binding` notice has a real
/// `@State` behind it, exactly as inside the two library pages.
private struct ImportControlHarness: View {
    @ObservedObject var store: CapturedLibraryStore
    @State var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("动作库导入入口").font(.headline)
                Spacer()
                LibraryImportButton(title: "导入 JSON…", destination: .actions, store: store, notice: $notice)
            }
            LibraryImportStatus(store: store, notice: notice)
        }.padding(22)
    }
}
