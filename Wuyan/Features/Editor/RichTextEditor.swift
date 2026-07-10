import AppKit
import SwiftUI

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
        let scrollView = NSTextView.scrollableTextView()
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
        textView.font = NSFont(name: WuyanFont.bundledSerifName, size: 18) ?? NSFont.systemFont(ofSize: 18)
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

            let font = NSFont(name: WuyanFont.bundledSerifName, size: 18) ?? NSFont.systemFont(ofSize: 18)
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
            let rtf = try? attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
            return rtfd ?? rtf
        }
    }
}
