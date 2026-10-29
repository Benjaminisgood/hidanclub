import SwiftUI

@main
struct HidanDocsApp: App {
    @StateObject private var library = DocLibrary()

    var body: some Scene {
        WindowGroup("Hidan Club Docs") {
            RootView()
                .environmentObject(library)
                #if os(macOS)
                .frame(minWidth: 980, minHeight: 640)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 840)
        #endif
    }
}
