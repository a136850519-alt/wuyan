import SwiftUI

/// Stable identifiers used by the year color picker. The same identifier
/// resolves to a light or dark token at render time.
enum YearTheme: String, CaseIterable, Identifiable {
    case pine, mist, wisteria, rose, wheat, clay

    static let `default`: YearTheme = .pine
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pine: return "松绿"
        case .mist: return "雾蓝"
        case .wisteria: return "藤紫"
        case .rose: return "玫瑰"
        case .wheat: return "麦黄"
        case .clay: return "陶棕"
        }
    }

    var lightHex: String {
        switch self {
        case .pine: return "#416857"
        case .mist: return "#6288A4"
        case .wisteria: return "#8C75A6"
        case .rose: return "#B96E83"
        case .wheat: return "#A17B3C"
        case .clay: return "#9A7564"
        }
    }

    var darkHex: String {
        switch self {
        case .pine: return "#A7C4A3"
        case .mist: return "#9DBBD0"
        case .wisteria: return "#BEA9DA"
        case .rose: return "#E5A3B7"
        case .wheat: return "#DFBF7D"
        case .clay: return "#D5B09A"
        }
    }

    var color: Color { Palette.adaptive(light: lightHex, dark: darkHex) }
    var softColor: Color {
        Palette.adaptive(light: lightHex, dark: darkHex).opacity(0.14)
    }
}

/// 年度颜色的持久化值。预设保留稳定标识，自定义颜色保存为 sRGB HEX。
enum YearThemeValue: Equatable {
    case preset(YearTheme)
    case custom(hex: String)

    static let `default`: YearThemeValue = .preset(.pine)

    init(storageValue: String?) {
        guard let raw = storageValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            self = .default
            return
        }
        if let preset = YearTheme(rawValue: raw) {
            self = .preset(preset)
        } else if let hex = Palette.normalizedHex(raw) {
            self = .custom(hex: hex)
        } else {
            self = .default
        }
    }

    var storageValue: String {
        switch self {
        case let .preset(theme): return theme.rawValue
        case let .custom(hex): return hex
        }
    }

    var hex: String {
        switch self {
        case let .preset(theme): return theme.lightHex
        case let .custom(hex): return hex
        }
    }

    var color: Color {
        switch self {
        case let .preset(theme): return theme.color
        case let .custom(hex): return Color(hex: hex)
        }
    }

    var softColor: Color { color.opacity(0.14) }

    var displayName: String {
        switch self {
        case let .preset(theme): return theme.displayName
        case .custom: return "自定义颜色"
        }
    }
}

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

    static func normalizedHex(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard raw.count == 3 || raw.count == 6,
              raw.allSatisfy({ $0.isHexDigit }) else { return nil }
        let expanded = raw.count == 3
            ? raw.map { "\($0)\($0)" }.joined()
            : raw
        return "#" + expanded.uppercased()
    }
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

    static func adaptive(light: String, dark: String) -> Color {
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
