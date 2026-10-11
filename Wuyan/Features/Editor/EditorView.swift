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
    @State private var showsInspector = true
    @State private var editingGrowthBoard: Board?
    @State private var archiveEditing = false
    @State private var wordExportSnapshot: WordExportSnapshot?

    private struct WordExportSnapshot: Identifiable {
        let id = UUID()
        var entry: Entry
        var boardName: String
        var assets: [MediaAsset]
    }

    var body: some View {
        Group {
            if viewModel.entry == nil {
                ContentUnavailableView("选择一篇日记", systemImage: "square.and.pencil", description: Text("或按 ⌘N 开始新的记录。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if immersive {
                    immersivePane
                } else {
                    GeometryReader { geometry in
                        HStack(spacing: 0) {
                            writingPane
                                .frame(minWidth: 320, maxWidth: 720)
                                .frame(maxWidth: .infinity)
                            if showsInspector, geometry.size.width >= 680 {
                                Divider()
                                metadataPane.frame(width: 320)
                            }
                        }
                        .overlay(alignment: .trailing) {
                            if showsInspector, geometry.size.width < 680 {
                                metadataPane.frame(width: min(320, geometry.size.width))
                                    .shadow(color: .black.opacity(0.15), radius: 12, x: -4, y: 4)
                            }
                        }
                        .onChange(of: geometry.size.width < 680, initial: true) { _, narrow in
                            showsInspector = !narrow
                        }
                    }
                }
            }
        }
        .navigationTitle(viewModel.title.isEmpty ? "未命名" : viewModel.title)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showsInspector.toggle()
                } label: {
                    Label(showsInspector ? "隐藏日记信息" : "显示日记信息", systemImage: "sidebar.right")
                }
                .help("显示或隐藏日记信息")
                Button {
                    viewModel.isFavorite.toggle()
                } label: {
                    Label("收藏", systemImage: viewModel.isFavorite ? "heart.fill" : "heart")
                }
                Button(role: .destructive) {
                    appState.requestDeleteCurrentEntry()
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
            viewModel.commitPendingRichText = { richTextController.commitPendingRTF() }
            viewModel.load(id: appState.selectedEntryId, appState: appState)
        }
        .onChange(of: appState.selectedEntryId) {
            viewModel.load(id: appState.selectedEntryId, appState: appState)
        }
        .sheet(item: $editingGrowthBoard, onDismiss: reloadBoards) { board in
            BoardEditorSheet(board: board).environmentObject(appState)
        }
        .sheet(item: $wordExportSnapshot) { snapshot in
            WordExportSheet(entry: snapshot.entry, boardName: snapshot.boardName, assets: snapshot.assets)
        }
        .onReceive(NotificationCenter.default.publisher(for: .wuyanWillTerminate)) { _ in
            viewModel.flushIfNeeded(appState: appState)
        }
        .onReceive(NotificationCenter.default.publisher(for: .wuyanDiaryLockRequested)) { _ in
            wordExportSnapshot = nil
            editingGrowthBoard = nil
            showAIPopover = false
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
            if viewModel.archiveLocked || viewModel.externalUpdateDetected || viewModel.externalConflictCopyDetected || viewModel.switchBlockedMessage != nil {
                externalUpdateBanner
            }
            dateAnchor
            TextField("题目", text: $viewModel.title, axis: .vertical)
                .font(WuyanFont.title(30))
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 44)

            editorFormattingBar

            RichTextEditor(
                text: $viewModel.body,
                rtfData: $viewModel.bodyRTF,
                controller: richTextController,
                identity: viewModel.entry?.id,
                onImagePasted: handlePastedImage
            )
                .id(viewModel.entry?.id)
                .background(Palette.paper)
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleDrop(providers)
                }

            HStack {
                Text("\(viewModel.nonWhitespaceCount) 字")
                Spacer()
                if viewModel.archiveLocked || viewModel.externalUpdateDetected || viewModel.externalConflictCopyDetected {
                    Text("已暂停自动保存")
                } else if viewModel.isDirty {
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

    /// 外部更新横幅：同时覆盖未保存编辑暂停和已保存版本冲突留档两种情况。
    private var externalUpdateBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.archiveLocked ? "该年份正在归档，暂不保存" : (viewModel.switchBlockedMessage ?? (viewModel.externalConflictCopyDetected ? "你刚才的版本已另存到冲突列表" : "该条目在后台已被更新（同步或天气/定位写入）")))
                    .font(.callout.weight(.semibold))
                Text(viewModel.archiveLocked ? "归档完成后即可继续编辑。" : (viewModel.externalConflictCopyDetected ? "当前编辑器已显示远端版本，可在设置 › 冲突列表中查看并恢复。" : "自动保存已暂停，你的编辑仍在编辑器中。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if viewModel.archiveLocked {
                EmptyView()
            } else if viewModel.externalConflictCopyDetected {
                Button("查看冲突列表") { appState.sidebarSelection = .settings }
                Button("关闭提示") { viewModel.externalConflictCopyDetected = false }
            } else {
                Button("以我的编辑为准") {
                    viewModel.keepCurrentEdits(appState: appState)
                }
                Button("重新载入") {
                    viewModel.reloadFromDatabase(appState: appState)
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                aiAssistant
                    .environmentObject(appState)
                    .padding()
                    .frame(width: 360)
            }

            writingPane
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                if viewModel.externalUpdateDetected {
                    Text("已暂停自动保存")
                } else if viewModel.isDirty {
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
        .background(Palette.inspectorSurface)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("日记信息").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    if viewModel.isDirty { Text("正在保存…").font(.system(size: 11)) }
                }.padding(.bottom, 2)
                InspectorCard(title: "") {
                    HStack {
                        Circle().fill(Color(hex: currentBoard?.colorHex ?? "#D85A30")).frame(width: 7, height: 7)
                        Text(currentBoard?.name ?? "日记").lineLimit(2)
                        Spacer()
                        Button(archiveEditing ? "完成" : "更改") { archiveEditing.toggle() }
                            .buttonStyle(.plain).font(.system(size: 11))
                    }
                    Text(viewModel.journalDate, format: .dateTime.year().month().day().hour().minute())
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    if archiveEditing {
                        Picker("板块", selection: $viewModel.boardId) {
                            ForEach(boards) { board in Text(board.name).tag(Optional(board.id)) }
                        }
                        DatePicker("日期", selection: $viewModel.journalDate, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                    }
                }
                DayMoodCard(viewModel: viewModel).id(metadataIdentity)
                if let entry = viewModel.entry {
                    WeatherCardView(entry: entry) { draft, baseline in
                        try viewModel.saveMetadata(draft, baseline: baseline, appState: appState)
                    }.id(metadataIdentity)
                }
                aiAssistant
                if let board = currentBoard, board.kind == .growth {
                    InspectorCard(title: "成长信息", background: Palette.growthSurface, foreground: Palette.babyPinkText) {
                        if let age = board.ageText(in: articleYear) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(age).font(.system(size: 28, weight: .medium, design: .serif))
                                Text("\(String(articleYear)) 年的你").font(.system(size: 12))
                            }
                            Text("按当年生日后的岁数显示").font(.system(size: 11))
                        } else {
                            Button("设置生日") { editingGrowthBoard = board }
                        }
                    }
                }
                InspectorCard(title: "标签与收藏") {
                    TextField("用逗号分隔标签", text: $viewModel.tagsText, axis: .vertical).lineLimit(2...4)
                    Toggle("收藏这篇日记", isOn: $viewModel.isFavorite).tint(Palette.cinnabar)
                }
                InspectorCard(title: "附件") {
                    if viewModel.mediaAssets.isEmpty {
                        Label("还没有附件", systemImage: "paperclip").foregroundStyle(Palette.muted)
                    }
                    ForEach(viewModel.mediaAssets) { asset in
                        Button { preview(asset) } label: {
                            HStack {
                                MediaThumb(asset: asset)
                                VStack(alignment: .leading) {
                                    Text(asset.filename).lineLimit(1)
                                    Text(ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file))
                                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                    Button { importMedia() } label: { Label("添加附件", systemImage: "plus") }.buttonStyle(.borderless)
                }
                Divider().padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 7) {
                    Button {
                        guard viewModel.saveNow(appState: appState), let entry = viewModel.draftEntry else {
                            appState.errorMessage = "当前日记尚未保存成功，请先处理保存问题后再导出。"
                            return
                        }
                        wordExportSnapshot = WordExportSnapshot(entry: entry, boardName: currentBoard?.name ?? "日记", assets: viewModel.mediaAssets)
                    } label: {
                        Label("导出为 Word", systemImage: "doc.text")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .tint(Palette.cinnabar)
                    .disabled(viewModel.entry == nil || viewModel.isDirty && viewModel.externalUpdateDetected)
                    Text("仅导出当前这篇日记")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }.padding(16)
        }
        .background(Palette.inspectorSurface)
        .foregroundStyle(Palette.ink)
    }

    private var currentBoard: Board? { boards.first { $0.id == viewModel.boardId } }
    private var articleYear: Int { AppState.year(fromDayKey: viewModel.draftEntry?.dayDate ?? DayKey.today) }
    private var metadataIdentity: String { "\(viewModel.entry?.id.uuidString ?? "")-\(viewModel.draftEntry?.dayDate ?? "")" }
    private var aiAssistant: some View {
        AIAssistantView(entry: viewModel.draftEntry, insertPrompt: { richTextController.insertOutline($0) },
                        applyTitle: { viewModel.title = $0 }, applyTags: { viewModel.tagsText = $0 })
            .id("\(metadataIdentity)-\(viewModel.boardId?.uuidString ?? "")")
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

    private func handlePastedImage(_ image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:])
        else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wuyan-paste-\(UUID().uuidString).png")
        do {
            try data.write(to: url, options: .atomic)
            viewModel.importMedia(urls: [url], appState: appState, cleanupAfterImport: [url])
        } catch {
            appState.errorMessage = "剪贴板图片无法导入媒体库：\(error.localizedDescription)"
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
