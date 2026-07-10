import SwiftUI
import CoreText

enum WuyanFont {
    static let bundledSerifName = "LXGWWenKai-Regular"
    static let regularFilename = "LXGWWenKai-Regular"

    static func body(_ size: CGFloat = 17) -> Font {
        if AppSettings.bodyFont == "serif" {
            return .system(size: size, design: .serif)
        }
        return Font.custom(bundledSerifName, size: size, relativeTo: .body)
    }

    static func title(_ size: CGFloat = 28) -> Font {
        if AppSettings.bodyFont == "serif" {
            return .system(size: size, weight: .regular, design: .serif)
        }
        return Font.custom(bundledSerifName, size: size, relativeTo: .title)
    }

    static func registerBundledFonts() {
        // 优先从打包后的 Contents/Resources/Fonts 取（不依赖 SwiftPM 的 Bundle.module，
        // 后者在 .app 里只认 .app 顶层路径、签名不允许，会触发 fatalError）。
        let url = Bundle.main.url(forResource: regularFilename, withExtension: "ttf", subdirectory: "Fonts")
            ?? Bundle.main.url(forResource: regularFilename, withExtension: "ttf")
        guard let fontURL = url else { return }
        CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
    }
}
