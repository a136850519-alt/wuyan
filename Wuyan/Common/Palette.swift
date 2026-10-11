import SwiftUI

enum Palette {
    static let cinnabar = Color(hex: "#D85A30")
    static let cinnabarDeep = adaptive(light: "#A94120", dark: "#EC8057")
    static let cinnabarSoft = adaptive(light: "#FBF3EF", dark: "#51362A")
    static let cinnabarHover = adaptive(light: "#FAECE7", dark: "#604033")
    static let cinnabarStroke = adaptive(light: "#E8C9BC", dark: "#785444")
    static let amber = Color(hex: "#C98522")
    static let babyPink = adaptive(light: "#EFD1DD", dark: "#543340")
    static let babyPinkText = adaptive(light: "#792F4D", dark: "#FFD1E3")
    static let paper = adaptive(light: "#FFFDF8", dark: "#222221")
    static let sidebarPaper = adaptive(light: "#F0ECE3", dark: "#292927")
    static let ink = adaptive(light: "#2E302A", dark: "#F2ECE4")
    static let muted = adaptive(light: "#686A60", dark: "#B8B6AD")
    static let timelineSelection = adaptive(light: "#F4DFD2", dark: "#51362A")
    static let inspectorSurface = adaptive(light: "#F7F4ED", dark: "#262624")
    static let cardSurface = adaptive(light: "#EEEADF", dark: "#34332E")
    static let field = adaptive(light: "#EAE6DC", dark: "#373732")
    static let moodSurface = adaptive(light: "#F5DCA4", dark: "#503C21")
    static let moodText = adaptive(light: "#644415", dark: "#FFE0A3")
    static let moodSelected = Color(hex: "#F7BB4A")
    static let moodSelectedText = Color(hex: "#493410")
    static let weatherSurface = adaptive(light: "#CEE7F0", dark: "#253E4C")
    static let weatherText = adaptive(light: "#254C61", dark: "#D3EDF7")
    static let aiSurface = adaptive(light: "#F2DED6", dark: "#49332D")
    static let aiText = adaptive(light: "#5C2E20", dark: "#FFE1D6")
    static let growthSurface = babyPink
    static let hairline = adaptive(light: "#DED9CE", dark: "#41413C")

    private static func adaptive(light: String, dark: String) -> Color {
        let lightColor = NSColor(Color(hex: light))
        let darkColor = NSColor(Color(hex: dark))
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        })
    }
    static let heatmap = [
        Color.clear,
        Color(hex: "#FAECE7"),
        Color(hex: "#F5C4B3"),
        Color(hex: "#F0997B"),
        Color(hex: "#D85A30")
    ]
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let red: Double
        let green: Double
        let blue: Double
        let opacity: Double

        switch cleaned.count {
        case 3:
            red = Double((value >> 8) & 0xF) / 15.0
            green = Double((value >> 4) & 0xF) / 15.0
            blue = Double(value & 0xF) / 15.0
            opacity = 1
        case 6:
            red = Double((value >> 16) & 0xFF) / 255.0
            green = Double((value >> 8) & 0xFF) / 255.0
            blue = Double(value & 0xFF) / 255.0
            opacity = 1
        case 8:
            red = Double((value >> 24) & 0xFF) / 255.0
            green = Double((value >> 16) & 0xFF) / 255.0
            blue = Double((value >> 8) & 0xFF) / 255.0
            opacity = Double(value & 0xFF) / 255.0
        default:
            red = 0
            green = 0
            blue = 0
            opacity = 1
        }

        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}
