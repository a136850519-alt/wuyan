import SwiftUI

struct WeatherCardView: View {
    var entry: Entry
    var save: (MetadataDraft, Entry) throws -> Void
    @State private var isEditing = false
    @State private var draft: MetadataDraft?
    @State private var baseline: Entry?
    @State private var error: String?
    @State private var showsCoordinates = false
    @FocusState private var editFocused: Bool

    var body: some View {
        InspectorCard(title: "", background: Palette.weatherSurface, foreground: Palette.weatherText) {
            HStack {
                Text("天气与地点").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("编辑") {
                    baseline = entry
                    draft = MetadataDraft(entry: entry)
                    error = nil
                    isEditing = true
                }
                .buttonStyle(.plain).font(.system(size: 11))
                .focused($editFocused)
            }
            HStack(spacing: 16) {
                Image(systemName: WeatherKind.classify(entry.weather?.condition).symbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 42))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.weather.map { "\($0.tempC.formatted(.number.precision(.fractionLength(0...1))))℃" } ?? "—")
                        .font(.system(size: 30, weight: .medium))
                    Text(entry.weather?.condition ?? "未记录天气")
                }
            }
            Text("\(entry.location?.placeName ?? "未设置地点") · 记录当天的天气")
                .font(.system(size: 11))
            if isEditing, draft != nil {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                    ForEach(WeatherKind.allCases) { kind in
                        Button {
                            draft?.condition = kind == .unknown ? "" : kind.rawValue
                            if kind == .unknown { draft?.temperature = "" }
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: kind.symbol).symbolRenderingMode(.multicolor).font(.title3)
                                Text(kind.rawValue).font(.system(size: 11))
                            }.frame(maxWidth: .infinity).padding(.vertical, 5)
                        }.buttonStyle(.plain)
                    }
                }
                TextField("天气状况", text: binding(\.condition)).textFieldStyle(.roundedBorder)
                TextField("温度 ℃", text: binding(\.temperature)).textFieldStyle(.roundedBorder)
                TextField("地点", text: binding(\.place)).textFieldStyle(.roundedBorder)
                DisclosureGroup("详细位置", isExpanded: $showsCoordinates) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("纬度", text: binding(\.latitude))
                        TextField("经度", text: binding(\.longitude))
                        Text("新增地点需要坐标；已有地点可直接修改名称。")
                            .font(.system(size: 11))
                    }.padding(.top, 8)
                }.font(.system(size: 12))
                if let error { Text(error).font(.system(size: 12)).accessibilityAddTraits(.updatesFrequently) }
                HStack {
                    Button("取消", action: cancel)
                    Spacer()
                    Button("保存修改") {
                        guard let draft, let baseline else { return }
                        do {
                            try save(draft, baseline)
                            cancel()
                        } catch {
                            self.error = error.localizedDescription
                            if case MetadataError.invalidCoordinates = error { showsCoordinates = true }
                        }
                    }
                }
            }
        }
        .onExitCommand { if isEditing { cancel() } }
    }

    private func binding(_ key: WritableKeyPath<MetadataDraft, String>) -> Binding<String> {
        Binding(get: { draft?[keyPath: key] ?? "" }, set: { draft?[keyPath: key] = $0 })
    }
    private func cancel() {
        isEditing = false
        draft = nil
        baseline = nil
        error = nil
        editFocused = true
    }
}
