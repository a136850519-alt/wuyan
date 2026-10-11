import SwiftUI

struct InspectorCard<Content: View>: View {
    var title: String
    var background: Color = Palette.cardSurface
    var foreground: Color = Palette.ink
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if !title.isEmpty { Text(title).font(.system(size: 13, weight: .semibold)) }
            content()
        }
        .font(.system(size: 13))
        .foregroundStyle(foreground)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct MoodChoices: View {
    @Binding var selection: Int?
    var emojiSize: CGFloat = 27
    @FocusState private var focusedMood: Int?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Mood.allCases) { option in
                Button {
                    selection = option.rawValue
                } label: {
                    VStack(spacing: 6) {
                        Text(option.emoji).font(.system(size: emojiSize))
                        Text(option.label).font(.system(size: 11)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(selection == option.rawValue ? Palette.moodSelected : Color.clear,
                                in: RoundedRectangle(cornerRadius: 9))
                    .foregroundStyle(selection == option.rawValue ? Palette.moodSelectedText : Palette.moodText)
                    .overlay(alignment: .topTrailing) {
                        if selection == option.rawValue {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11)).foregroundStyle(Palette.moodSelectedText)
                        }
                    }
                }
                .buttonStyle(.plain)
                .focused($focusedMood, equals: option.rawValue)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(selection == option.rawValue ? .isSelected : [])
            }
        }
        .onMoveCommand { direction in
            let delta = direction == .right ? 1 : direction == .left ? -1 : 0
            guard delta != 0 else { return }
            selection = ((selection ?? 1) - 1 + delta + 5) % 5 + 1
            focusedMood = selection
        }
    }
}
