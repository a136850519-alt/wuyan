import SwiftUI
import UniformTypeIdentifiers
import Quartz

struct EditorView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = EditorViewModel()
    @StateObject private var richTextController = RichTextEditorController()
    @State private var boards: [Board] = []
    @State private var immersive = false
    @State private var showAIPopover = false
    @State private var selectedFontSize = 18.0
    @State private var selectedTextColor = Color.primary

    var body: some View {
        Group {
            if viewModel.entry == nil {
                ContentUnavailableView("选择一篇日记", systemImage: "square.and.pencil", description: Text("或按 ⌘N 开始新的记录。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if immersive {
                    immersivePane
                } else {
                    HStack(spacing: 0) {
                        writingPane
                        Divider()
                        metadataPane
                            .frame(width: 250)
                    }
                }
            }
        }
        .navigationTitle(viewModel.title.isEmpty ? "未命名" : viewModel.title)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    viewModel.isFavorite.toggle()
                } label: {
                    Label("收藏", systemImage: viewModel.isFavorite ? "heart.fill" : "heart")
                }
                Button(role: .destructive) {
                    viewModel.delete(appState: appState)
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .disabled(viewModel.entry == nil)
                Button {
                    importMedia()
                } label: {
                    Label("附件", systemImage: "paperclip")
                }
                .disabled(viewModel.entry == nil)
                Button {
                    insertImages()
                } label: {
                    Label("图片", systemImage: "photo")
                }
                .disabled(viewModel.entry == nil)
                Button {
                    toggleRecording()
                } label: {
                    Label("录音", systemImage: appState.audioRecorder.isRecording ? "stop.circle" : "mic")
                }
                .disabled(viewModel.entry == nil)
                Button {
                    immersive.toggle()
                } label: {
                    Label("沉浸", systemImage: immersive ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                }
            }
        }
        .onAppear {
            reloadBoards()
            viewModel.configure(appState: appState)
            viewModel.load(id: appState.selectedEntryId, appState: appState)
        }
        .onChange(of: appState.selectedEntryId) {
            viewModel.load(id: appState.selectedEntryId, appState: appState)
        }
        .onReceive(NotificationCenter.default.publisher(for: .wuyanWillTerminate)) { _ in
            viewModel.flushIfNeeded(appState: appState)
        }
        .onDisappear {
            // 切到设置、日历或其它窗口时也要落盘最后一段输入，不能只依赖
            // 进程退出通知；视图移除本身不会触发保存任务完成。
            viewModel.flushIfNeeded(appState: appState)
        }
    }

    private var writingPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            dateAnchor
            TextField("题目", text: $viewModel.title)
                .font(WuyanFont.title(30))
                .textFieldStyle(.plain)

            editorFormattingBar

            RichTextEditor(text: $viewModel.body, rtfData: $viewModel.bodyRTF, controller: richTextController)
                .background(Palette.paper)
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleDrop(providers)
                }

            HStack {
                Text("\(viewModel.nonWhitespaceCount) 字")
                Spacer()
                if viewModel.isDirty {
                    Text("正在保存…")
                } else if let savedAt = viewModel.lastSavedAt {
                    Text("已保存 \(savedAt, style: .time)")
                } else {
                    Text("已保存")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 28)
        .background(Palette.paper)
    }

    private var immersivePane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { immersive = false } label: { Label("完成", systemImage: "checkmark") }
                Spacer()
                Text("\(viewModel.nonWhitespaceCount) 字")
                    .foregroundStyle(.secondary)
                Button { importMedia() } label: { Label("附件", systemImage: "paperclip") }
                Button { insertImages() } label: { Label("插图", systemImage: "photo") }
                Button { toggleRecording() } label: { Label("录音", systemImage: appState.audioRecorder.isRecording ? "stop.circle" : "mic") }
                Button { showAIPopover = true } label: { Label("AI", systemImage: "sparkles") }
            }
            .labelStyle(.iconOnly)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.thinMaterial)
            .popover(isPresented: $showAIPopover) {
                AIAssistantView(entry: viewModel.entry)
                    .environmentObject(appState)
                    .padding()
                    .frame(width: 360)
            }

            writingPane
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                if viewModel.isDirty {
                    Text("正在保存…")
                } else if let savedAt = viewModel.lastSavedAt {
                    Text("已保存 \(savedAt, style: .time)")
                } else {
                    Text("本地已保存")
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(.thinMaterial)
        }
    }

    private var editorFormattingBar: some View {
        HStack(spacing: 8) {
            Stepper(value: $selectedFontSize, in: 12...42, step: 1) {
                Label("\(Int(selectedFontSize))", systemImage: "textformat.size")
                    .labelStyle(.titleAndIcon)
                    .frame(minWidth: 54, alignment: .leading)
            }
            .onChange(of: selectedFontSize) {
                richTextController.applyFontSize(selectedFontSize)
            }
            ColorPicker("文字颜色", selection: $selectedTextColor, supportsOpacity: false)
                .labelsHidden()
                .onChange(of: selectedTextColor) {
                    richTextController.applyColor(NSColor(selectedTextColor))
                }
            Divider()
                .frame(height: 18)
            Button {
                richTextController.applyAlignment(.left)
            } label: {
                Label("左对齐", systemImage: "text.alignleft")
            }
            Button {
                richTextController.applyAlignment(.center)
            } label: {
                Label("居中", systemImage: "text.aligncenter")
            }
            Button {
                richTextController.applyAlignment(.right)
            } label: {
                Label("右对齐", systemImage: "text.alignright")
            }
            Divider()
                .frame(height: 18)
            Button {
                insertImages()
            } label: {
                Label("添加图片", systemImage: "photo.badge.plus")
            }
            Spacer()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var dateAnchor: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(Calendar.current.component(.day, from: viewModel.journalDate))")
                .font(.system(size: 54, weight: .semibold, design: .serif))
                .foregroundStyle(.primary.opacity(0.72))
            VStack(alignment: .leading) {
                Text(viewModel.journalDate, format: .dateTime.year().month(.wide))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let board = boards.first(where: { $0.id == viewModel.boardId }) {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: board.colorHex)).frame(width: 7, height: 7)
                        Text(board.name)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var metadataPane: some View {
        Form {
            Section("归档") {
                Picker("板块", selection: Binding(
                    get: { viewModel.boardId ?? boards.first?.id },
                    set: { viewModel.boardId = $0 }
                )) {
                    ForEach(boards) { board in
                        Text(board.name).tag(Optional(board.id))
                    }
                }

                DatePicker("日期", selection: $viewModel.journalDate, displayedComponents: [.date, .hourAndMinute])
            }

            Section("心绪") {
                Picker("情绪", selection: $viewModel.mood) {
                    Text("未设置").tag(Optional<Int>.none)
                    ForEach(1...5, id: \.self) { value in
                        Text("\(value)").tag(Optional(value))
                    }
                }
                .pickerStyle(.segmented)

                Toggle("收藏", isOn: $viewModel.isFavorite)
                    .tint(Palette.cinnabar)
            }

            Section("标签") {
                TextField("用逗号分隔", text: $viewModel.tagsText, axis: .vertical)
                    .lineLimit(2...4)
            }

            Section("Meta") {
                TextField("天气", text: $viewModel.weatherCondition)
                TextField("温度 ℃", text: $viewModel.weatherTemp)
                TextField("地点", text: $viewModel.placeName)
                HStack {
                    TextField("纬度", text: $viewModel.latitude)
                    TextField("经度", text: $viewModel.longitude)
                }
                Button("保存元数据") {
                    viewModel.saveMetadata(appState: appState)
                }
                if !viewModel.tagsText.isEmpty {
                    WuyanPill(text: viewModel.tagsText)
                }
            }

            Section("AI 辅助") {
                AIAssistantView(entry: viewModel.entry)
            }

            if let board = boards.first(where: { $0.id == viewModel.boardId }),
               let age = board.ageText(on: viewModel.journalDate) {
                Section("成长") {
                    Text(age)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Palette.babyPink)
                        .foregroundStyle(Palette.babyPinkText)
                        .clipShape(Capsule())
                }
            }

            if !viewModel.mediaAssets.isEmpty {
                Section("附件") {
                    ForEach(viewModel.mediaAssets) { asset in
                        Button {
                            preview(asset)
                        } label: {
                            HStack {
                                MediaThumb(asset: asset)
                            VStack(alignment: .leading) {
                                Text(asset.filename)
                                    .lineLimit(1)
                                Text(ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func reloadBoards() {
        do {
            boards = try appState.boards.all()
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }

    private func importMedia() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie, .audio]
        if panel.runModal() == .OK {
            viewModel.importMedia(urls: panel.urls, appState: appState)
        }
    }

    private func insertImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK {
            richTextController.insertImages(panel.urls)
            viewModel.importMedia(urls: panel.urls, appState: appState)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil)
                else { return }
                Task { @MainActor in
                    viewModel.importMedia(urls: [url], appState: appState)
                }
            }
        }
        return true
    }

    private func icon(for asset: MediaAsset) -> String {
        switch asset.type {
        case .photo:
            return "photo"
        case .video:
            return "film"
        case .audio:
            return "waveform"
        }
    }

    private func preview(_ asset: MediaAsset) {
        Task {
            do {
                if let url = try await appState.syncCoordinator.downloadMediaIfNeeded(asset) {
                    await MainActor.run {
                        QuickLookPreviewer.shared.preview(url: url)
                    }
                }
            } catch {
                await MainActor.run {
                    appState.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func toggleRecording() {
        do {
            // UI-09③：录音导入到「录音开始时绑定的条目」，与停止时正在编辑哪条无关。
            if let recording = try appState.audioRecorder.toggle(for: viewModel.entry?.id) {
                viewModel.importMedia(
                    urls: [recording.url],
                    appState: appState,
                    entryId: recording.entryId,
                    cleanupAfterImport: [recording.url]
                )
            }
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }
}

private final class QuickLookPreviewer: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPreviewer()
    private var url: URL?

    func preview(url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else {
            NSWorkspace.shared.open(url)
            return
        }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        url as NSURL?
    }
}

// R2-8: MediaThumb 不再内联 NSImage(contentsOfFile:)，改通过 EnvironmentObject 调用 mediaStore
private struct MediaThumb: View {
    var asset: MediaAsset
    @EnvironmentObject private var appState: AppState
    @State private var thumbnailImage: NSImage?

    var body: some View {
        Group {
            if let thumbnailImage {
                Image(nsImage: thumbnailImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: icon)
                    .foregroundStyle(Palette.cinnabar)
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task {
            // R2-8: 通过 mediaStore 协议方法异步加载缩略图
            thumbnailImage = await appState.mediaStore.thumbnail(for: asset)
        }
    }

    private var icon: String {
        switch asset.type {
        case .photo: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        }
    }
}
