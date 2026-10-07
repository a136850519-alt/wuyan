import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Intercept image paste/drop so the same 720px down-scaling path is used as
/// the toolbar importer. Plain text continues through NSTextView unchanged.
private final class WuyanTextView: NSTextView {
    override func paste(_ sender: Any?) {
        if insertImages(from: NSPasteboard.general) { return }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if insertImages(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    private func insertImages(from pasteboard: NSPasteboard) -> Bool {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? [])
            .filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        guard !urls.isEmpty else { return false }
        for url in urls {
            guard let image = NSImage(contentsOf: url) else { continue }
            let attachment = NSTextAttachment()
            attachment.image = scaled(image, maxWidth: 720)
            let attributed = NSMutableAttributedString(attachment: attachment)
            attributed.append(NSAttributedString(string: "\n"))
            textStorage?.replaceCharacters(in: selectedRange(), with: attributed)
            setSelectedRange(NSRange(location: selectedRange().location + attributed.length, length: 0))
        }
        didChangeText()
        return true
    }

    private func scaled(_ image: NSImage, maxWidth: CGFloat) -> NSImage {
        guard image.size.width > maxWidth else { return image }
        let ratio = maxWidth / image.size.width
        let size = NSSize(width: maxWidth, height: image.size.height * ratio)
        let output = NSImage(size: size)
        output.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        output.unlockFocus()
        return output
    }
}

/// UI-09④：按设置页「正文字体」构造 NSFont，使字体设置贯穿正文输入框，
/// 而不是只影响周边文本。霞鹜文楷 → 内嵌字体；系统衬线 → 系统字体 + serif 特征。
enum EditorBodyFont {
    static func nsFont(size: CGFloat) -> NSFont {
        if AppSettings.bodyFont == "serif" {
            let base = NSFont.systemFont(ofSize: size)
            let descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
            return NSFont(descriptor: descriptor, size: size) ?? base
        }
        return NSFont(name: WuyanFont.bundledSerifName, size: size) ?? NSFont.systemFont(ofSize: size)
    }
}

@MainActor
final class RichTextEditorController: ObservableObject {
    fileprivate weak var textView: NSTextView?

    func applyFontSize(_ size: CGFloat) {
        guard let textView else { return }
        let range = textView.selectedRange()
        let currentFont = textView.typingAttributes[.font] as? NSFont
            ?? NSFont(name: WuyanFont.bundledSerifName, size: size)
            ?? NSFont.systemFont(ofSize: size)
        let font = NSFontManager.shared.convert(currentFont, toSize: size)
        applyAttribute(.font, value: font, range: range)
    }

    func applyColor(_ color: NSColor) {
        guard let textView else { return }
        applyAttribute(.foregroundColor, value: color, range: textView.selectedRange())
    }

    func applyAlignment(_ alignment: NSTextAlignment) {
        guard let textView else { return }
        let selectedRange = textView.selectedRange()
        let paragraphRange = (textView.string as NSString).paragraphRange(for: selectedRange)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment

        if paragraphRange.length > 0 {
            textView.textStorage?.addAttribute(.paragraphStyle, value: paragraphStyle, range: paragraphRange)
        } else {
            textView.typingAttributes[.paragraphStyle] = paragraphStyle
        }
        textView.didChangeText()
    }

    func insertImages(_ urls: [URL]) {
        guard let textView else { return }
        for url in urls {
            guard let image = NSImage(contentsOf: url) else { continue }
            let attachment = NSTextAttachment()
            attachment.image = scaledImage(image, maxWidth: 720)
            let attributedImage = NSMutableAttributedString(attachment: attachment)
            attributedImage.append(NSAttributedString(string: "\n"))
            textView.textStorage?.replaceCharacters(in: textView.selectedRange(), with: attributedImage)
            let cursor = textView.selectedRange().location + attributedImage.length
            textView.setSelectedRange(NSRange(location: cursor, length: 0))
        }
        textView.didChangeText()
    }

    private func applyAttribute(_ key: NSAttributedString.Key, value: Any, range: NSRange) {
        guard let textView else { return }
        if range.length > 0 {
            textView.textStorage?.addAttribute(key, value: value, range: range)
        } else {
            textView.typingAttributes[key] = value
        }
        textView.didChangeText()
    }

    private func scaledImage(_ image: NSImage, maxWidth: CGFloat) -> NSImage {
        guard image.size.width > maxWidth else { return image }
        let ratio = maxWidth / image.size.width
        let size = NSSize(width: maxWidth, height: image.size.height * ratio)
        let output = NSImage(size: size)
        output.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        output.unlockFocus()
        return output
    }
}

struct RichTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var rtfData: Data?
    var controller: RichTextEditorController

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = WuyanTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsImageEditing = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 0, height: 8)
        textView.textContainer?.widthTracksTextView = true
        // UI-09④：跟随设置页「正文字体」
        textView.font = EditorBodyFont.nsFont(size: 18)
        textView.typingAttributes[.font] = textView.font
        controller.textView = textView
        context.coordinator.load(textView: textView, text: text, rtfData: rtfData)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        controller.textView = textView
        context.coordinator.parent = self
        context.coordinator.loadIfNeeded(textView: textView, text: text, rtfData: rtfData)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        private var lastRTFData: Data?
        private var isApplyingExternalValue = false

        init(_ parent: RichTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalValue,
                  let textView = notification.object as? NSTextView
            else { return }
            parent.text = textView.string
            let data = Self.rtfData(from: textView)
            lastRTFData = data
            parent.rtfData = data
        }

        func loadIfNeeded(textView: NSTextView, text: String, rtfData: Data?) {
            if let rtfData, rtfData != lastRTFData {
                load(textView: textView, text: text, rtfData: rtfData)
            } else if rtfData == nil, textView.string != text {
                load(textView: textView, text: text, rtfData: nil)
            }
        }

        func load(textView: NSTextView, text: String, rtfData: Data?) {
            isApplyingExternalValue = true
            // 切换条目前清空撤销栈，防止跨条目 ⌘Z 串档
            textView.undoManager?.removeAllActions()
            defer { isApplyingExternalValue = false }

            if let rtfData {
                // 优先尝试 RTFD（保留内嵌图片），失败回退 RTF（旧格式兼容）
                let rtfd = try? NSAttributedString(
                    data: rtfData,
                    options: [.documentType: NSAttributedString.DocumentType.rtfd],
                    documentAttributes: nil
                )
                let rtf = try? NSAttributedString(
                    data: rtfData,
                    options: [.documentType: NSAttributedString.DocumentType.rtf],
                    documentAttributes: nil
                )
                if let attributed = rtfd ?? rtf {
                    textView.textStorage?.setAttributedString(attributed)
                    lastRTFData = rtfData
                    return
                }
            }

            let font = EditorBodyFont.nsFont(size: 18)
            let attributed = NSAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor
                ]
            )
            textView.textStorage?.setAttributedString(attributed)
            lastRTFData = Self.rtfData(from: textView)
        }

        private static func rtfData(from textView: NSTextView) -> Data? {
            let attributed = textView.attributedString()
            // 优先使用 RTFD 格式（保留内嵌图片附件），回退到 RTF（纯文本旧格式兼容）
            let rtfd = try? attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
            )
            return rtfd
        }
    }
}
