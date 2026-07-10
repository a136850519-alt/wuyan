import SwiftUI

struct WuyanCard<Content: View>: View {
    var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .background(Color.primary.opacity(0.035))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Palette.hairline, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct WuyanPill: View {
    var text: String
    var foreground: Color = .secondary
    var background: Color = Color.primary.opacity(0.055)

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(Capsule())
    }
}

struct WuyanPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .foregroundStyle(.white)
            .background(Palette.cinnabar.opacity(configuration.isPressed ? 0.82 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct WuyanSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundStyle(.secondary)
            .background(Color.primary.opacity(configuration.isPressed ? 0.08 : 0.02))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.hairline, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct WuyanBoardKeyButtonStyle: ButtonStyle {
    var hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Palette.cinnabarDeep)
            .padding(.horizontal, 22)
            .frame(width: 310, height: 60)
            .background(hovering ? Palette.cinnabarHover : Palette.cinnabarSoft)
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(hovering ? Palette.cinnabar : Palette.cinnabarStroke, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(WuyanMotion.reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

enum WuyanMotion {
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static var ease: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.6)
    }
}
