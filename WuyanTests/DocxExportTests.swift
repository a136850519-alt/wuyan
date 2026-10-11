import AppKit
import Foundation
import Testing
@testable import Wuyan

extension GlobalStateSuite {
@Suite("Word export")
struct DocxExportTests {
    @Test("DOCX filters XML control characters and writes parseable parts")
    func exportProducesParseableXML() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wuyan-docx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent("日记.docx")
        let entry = Entry(
            boardId: UUID(),
            dayDate: "2026-10-11",
            title: "标题 & <测试>",
            body: "第一段\u{000B}\u{000C} & <第二段>",
            isDraft: false
        )

        try DocxExportService().export(
            entry: entry,
            boardName: "成长",
            assets: [],
            options: DocxExportOptions(includeMetadata: false, includeAttachments: false),
            to: target
        )

        let extractRoot = root.appendingPathComponent("extract")
        try FileManager.default.createDirectory(at: extractRoot, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-qq", target.path, "-d", extractRoot.path]
        try unzip.run()
        unzip.waitUntilExit()
        #expect(unzip.terminationStatus == 0)

        for relativePath in ["[Content_Types].xml", "_rels/.rels", "word/styles.xml", "word/document.xml", "word/_rels/document.xml.rels"] {
            let data = try Data(contentsOf: extractRoot.appendingPathComponent(relativePath))
            #expect(XMLParser(data: data).parse(), "(relativePath) must be valid XML")
        }
        let document = try String(contentsOf: extractRoot.appendingPathComponent("word/document.xml"), encoding: .utf8)
        #expect(document.contains("标题 &amp; &lt;测试&gt;"))
        #expect(!document.unicodeScalars.contains { $0.value == 0x0B || $0.value == 0x0C })
        #expect(!document.contains("(bodyXML)"))

        let textURL = root.appendingPathComponent("日记.txt")
        let textutil = Process()
        textutil.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        textutil.arguments = ["-convert", "txt", "-output", textURL.path, target.path]
        try textutil.run()
        textutil.waitUntilExit()
        #expect(textutil.terminationStatus == 0)
        let converted = try String(contentsOf: textURL, encoding: .utf8)
        #expect(converted.contains("标题 & <测试>"))
        #expect(converted.contains("第一段"))
    }

    @Test("invalid target leaves an existing file untouched")
    func invalidTargetDoesNotOverwrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wuyan-docx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent("existing.txt")
        try Data("keep".utf8).write(to: target)
        let entry = Entry(boardId: UUID(), body: "正文", isDraft: false)
        #expect(throws: DocxExportService.ExportError.self) {
            try DocxExportService().export(
                entry: entry,
                boardName: "日记",
                assets: [],
                options: DocxExportOptions(),
                to: target
            )
        }
        #expect(String(data: try Data(contentsOf: target), encoding: .utf8) == "keep")
    }

    @Test("export failure preserves an existing DOCX")
    func failedExportDoesNotOverwrite() throws {
        try TestIsolation.withIsolatedDefaults { _ in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("wuyan-docx-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let target = root.appendingPathComponent("existing.docx")
            try Data("existing document".utf8).write(to: target)
            let asset = MediaAsset(
                entryId: UUID(), type: .photo, filename: "missing.png", mime: "image/png",
                size: 1, sha256: "missing", localPath: "media/missing.png"
            )
            let entry = Entry(boardId: UUID(), body: "正文", isDraft: false)
            #expect(throws: DocxExportService.ExportError.self) {
                try DocxExportService().export(
                    entry: entry,
                    boardName: "日记",
                    assets: [asset],
                    options: DocxExportOptions(includeAttachments: true),
                    to: target
                )
            }
            #expect(try Data(contentsOf: target) == Data("existing document".utf8))
        }
    }

    @Test("rich text formatting and inline images are embedded")
    func richTextAndInlineImageAreEmbedded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wuyan-docx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let richText = NSMutableAttributedString(
            string: "加粗斜体",
            attributes: [
                .font: NSFontManager.shared.convert(NSFont.systemFont(ofSize: 20), toHaveTrait: [.boldFontMask, .italicFontMask]),
                .foregroundColor: NSColor.systemRed,
                .paragraphStyle: paragraph
            ]
        )
        let image = NSImage(size: NSSize(width: 20, height: 10))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(origin: .zero, size: image.size)
        richText.append(NSAttributedString(attachment: attachment))

        var entry = Entry(boardId: UUID(), body: "加粗斜体\u{FFFC}", isDraft: false)
        entry.bodyRTF = try richText.data(
            from: NSRange(location: 0, length: richText.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
        let target = root.appendingPathComponent("rich.docx")
        try DocxExportService().export(entry: entry, boardName: "日记", assets: [], options: DocxExportOptions(), to: target)

        let extractRoot = root.appendingPathComponent("extract")
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-qq", target.path, "-d", extractRoot.path]
        try unzip.run()
        unzip.waitUntilExit()
        #expect(unzip.terminationStatus == 0)

        let document = try String(contentsOf: extractRoot.appendingPathComponent("word/document.xml"), encoding: .utf8)
        #expect(document.contains("<w:b/>"))
        #expect(document.contains("<w:i/>"))
        #expect(document.contains("<w:sz w:val=\"40\"/>"))
        #expect(document.contains("<w:color w:val=\""))
        #expect(document.contains("<w:jc w:val=\"center\"/>"))
        #expect(document.contains("<w:drawing>"))
        #expect(FileManager.default.fileExists(atPath: extractRoot.appendingPathComponent("word/media/image1.png").path))
    }

    @Test("photo attachments are embedded in the DOCX package")
    func photoAttachmentIsEmbedded() throws {
        try TestIsolation.withIsolatedDefaults { _ in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("wuyan-docx-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let image = NSImage(size: NSSize(width: 20, height: 10))
            image.lockFocus()
            NSColor.systemRed.setFill()
            NSRect(origin: .zero, size: image.size).fill()
            image.unlockFocus()
            let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let imageURL = LocalMediaStore.mediaRootURL.appendingPathComponent("media/photo.png")
            try FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])!.write(to: imageURL)

            let asset = MediaAsset(entryId: UUID(), type: .photo, filename: "photo.png", mime: "image/png", size: 1, sha256: "photo", localPath: "media/photo.png")
            let target = root.appendingPathComponent("photo.docx")
            let entry = Entry(boardId: UUID(), body: "正文", isDraft: false)
            try DocxExportService().export(entry: entry, boardName: "日记", assets: [asset], options: DocxExportOptions(includeAttachments: true), to: target)

            let extractRoot = root.appendingPathComponent("extract")
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-qq", target.path, "-d", extractRoot.path]
            try unzip.run()
            unzip.waitUntilExit()
            #expect(unzip.terminationStatus == 0)
            #expect(FileManager.default.fileExists(atPath: extractRoot.appendingPathComponent("word/media/image1.png").path))
            let relationships = try String(contentsOf: extractRoot.appendingPathComponent("word/_rels/document.xml.rels"), encoding: .utf8)
            #expect(relationships.contains("Target=\"media/image1.png\""))
        }
    }
}
}
