import Foundation

enum RecordingPreference: String, CaseIterable, Identifiable {
    case daily = "日常生活", growth = "孩子成长", reading = "阅读观影"
    case work = "工作与创作", travel = "旅行见闻", selfReflection = "情绪与自己"
    var id: String { rawValue }
    var names: [String] {
        switch self {
        case .daily: return ["日常唠叨", "日常片段", "生活留声"]
        case .growth: return ["小小长大", "长大的每一天", "童言童语"]
        case .reading: return ["读完以后", "书影之间", "读与看"]
        case .work: return ["正在做的事", "手边的事", "灵感在场"]
        case .travel: return ["走到哪里", "沿途记", "出发以后"]
        case .selfReflection: return ["和自己说话", "心里有话", "给自己的信"]
        }
    }
    var theme: String {
        switch self {
        case .daily: return "日常琐事、心情和未说完的话"
        case .growth: return "孩子的原话、独立尝试与相处片段"
        case .reading: return "作品里的句子与自己的想法"
        case .work: return "工作进展、创作过程与灵感"
        case .travel: return "路上的风景、人物与意外发现"
        case .selfReflection: return "情绪起伏、身体感受与想对自己说的话"
        }
    }
    var kind: BoardKind { self == .growth ? .growth : .freeform }
    var icon: String {
        switch self {
        case .daily: return "bubble.left.and.bubble.right"
        case .growth: return "figure.and.child.holdinghands"
        case .reading: return "book"
        case .work: return "paintbrush.fill"
        case .travel: return "airplane"
        case .selfReflection: return "heart.fill"
        }
    }
    var color: String {
        switch self {
        case .daily: return "#D85A30"
        case .growth: return "#D66A91"
        case .reading: return "#4CAF50"
        case .work: return "#2196F3"
        case .travel: return "#E8A838"
        case .selfReflection: return "#9C27B0"
        }
    }
    static func inferred(from text: String) -> [Self] {
        let keywords: [(Self, [String])] = [
            (.growth, ["孩子", "女儿", "儿子", "宝宝", "小学", "成长"]),
            (.reading, ["书", "读", "电影", "观影"]), (.work, ["工作", "创作", "灵感", "项目"]),
            (.travel, ["旅行", "散步", "街道", "小店", "风景"]), (.selfReflection, ["情绪", "心情", "自己"])
        ]
        return keywords.filter { item in item.1.contains { text.contains($0) } }.map(\.0)
    }
}

struct BoardSuggestion: Identifiable, Equatable {
    let id: UUID
    let preference: RecordingPreference
    var name: String
    var lastSuggestedName: String
    var theme: String
    var selected = true
    var nameIndex = 0

    mutating func changeSuggestedName(to name: String) {
        // A manually edited name belongs to the user, even when refreshing.
        guard self.name == lastSuggestedName else { return }
        self.name = name
        lastSuggestedName = name
    }
    mutating func rotateName() {
        nameIndex = (nameIndex + 1) % preference.names.count
        changeSuggestedName(to: preference.names[nameIndex])
    }
    static func recommendations(preferences: Set<RecordingPreference>, description: String) -> [Self] {
        let detail = String(description.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        var choices = RecordingPreference.allCases.filter { preferences.contains($0) }
        for inferred in RecordingPreference.inferred(from: detail) where !choices.contains(inferred) { choices.append(inferred) }
        if choices.isEmpty, !detail.isEmpty { choices = [.daily] }
        return choices.prefix(3).map {
            Self(id: UUID(), preference: $0, name: $0.names[0], lastSuggestedName: $0.names[0],
                 theme: detail.isEmpty ? $0.theme : "\($0.theme)；想留下：\(detail)")
        }
    }
    static func localNames(theme: String, kind: BoardKind) -> [String] {
        if let preference = RecordingPreference.inferred(from: theme).first { return preference.names }
        switch kind {
        case .growth: return RecordingPreference.growth.names
        case .fiveYear: return ["五年以后", "时间留声", "年年此刻"]
        case .freeform: return RecordingPreference.daily.names
        }
    }
}
