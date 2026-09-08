import AppKit
import SwiftUI

enum BrandAssets {
    // Prefer the bundle staged inside the app. The SwiftPM fallback is used only
    // by development previews so a distributed app never needs the build folder.
    private static let resources: Bundle = {
        if let url = Bundle.main.url(forResource: "HidanClub_HidanClub", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()

    static let logo: NSImage? = {
        guard let url = resources.url(forResource: "HidanLogo", withExtension: "png", subdirectory: "Resources/Brand") else { return nil }
        return NSImage(contentsOf: url)
    }()

    static var applicationIcon: NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }
}

struct BrandIcon: View {
    var size: CGFloat = 48

    var body: some View {
        Group {
            if let image = BrandAssets.logo {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "figure.dance").resizable().scaledToFit().foregroundStyle(ClubTheme.accent)
            }
        }.frame(width: size, height: size).accessibilityLabel("Hidan Club 标志")
    }
}
