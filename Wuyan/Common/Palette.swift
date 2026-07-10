import SwiftUI

enum Palette {
    static let cinnabar = Color(hex: "#D85A30")
    static let cinnabarDeep = Color(hex: "#993C1D")
    static let cinnabarSoft = Color(hex: "#FBF3EF")
    static let cinnabarHover = Color(hex: "#FAECE7")
    static let cinnabarStroke = Color(hex: "#E8C9BC")
    static let amber = Color(hex: "#C98522")
    static let babyPink = Color(hex: "#FBEAF0")
    static let babyPinkText = Color(hex: "#993556")
    static let paper = Color(nsColor: .textBackgroundColor)
    static let sidebarPaper = Color(nsColor: .windowBackgroundColor)
    static let hairline = Color.primary.opacity(0.12)
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
