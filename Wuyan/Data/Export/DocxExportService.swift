import AppKit
import Foundation

struct DocxExportOptions {
    var includeMetadata = false
    var includeAttachments = false
}

/// Generates an Office Open XML document and atomically replaces the target only after validation.
final class DocxExportService {
    enum ExportError: LocalizedError {
        case cannotCreateArchive
        case cannotReadImage(String)
        case invalidTarget
        case invalidXML

        var errorDescription: String? {
            switch self {
            case .cannotCreateArchive: return "Word 文档打包失败，未写入目标文件。"
            case let .cannotReadImage(name): return "无法读取图片附件：\(name)"
            case .invalidTarget: return "保存位置无效，导出已取消。"
            case .invalidXML: return "Word 文档内容校验失败，未写入目标文件。"
            }
        }
    }

    private struct PackageParts {
        var document: String
        var relationships: String
        var media: [(name: String, data: Data)]
    }

    func export(entry: Entry, boardName: String, assets: [MediaAsset], options: DocxExportOptions, to target: URL) throws {
        guard target.pathExtension.lowercased() == "docx" else { throw ExportError.invalidTarget }
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("wuyan-docx-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("word/_rels"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("word/media"), withIntermediateDirectories: true)

        let parts = try documentParts(entry: entry, boardName: boardName, assets: assets, options: options)
        let xmlParts = [contentTypesXML(media: parts.media), Self.rootRelationshipsXML, Self.stylesXML, parts.document, parts.relationships]
        guard xmlParts.allSatisfy(Self.isValidXML) else { throw ExportError.invalidXML }
        try write(xmlParts[0], to: root.appendingPathComponent("[Content_Types].xml"))
        try write(xmlParts[1], to: root.appendingPathComponent("_rels/.rels"))
        try write(xmlParts[2], to: root.appendingPathComponent("word/styles.xml"))
        try write(xmlParts[3], to: root.appendingPathComponent("word/document.xml"))
        try write(xmlParts[4], to: root.appendingPathComponent("word/_rels/document.xml.rels"))
        for media in parts.media {
            try media.data.write(to: root.appendingPathComponent("word/media/\(media.name)"), options: .atomic)
        }

        let destinationDirectory = target.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let archive = destinationDirectory.appendingPathComponent(".wuyan-\(UUID().uuidString).docx")
        defer { try? fileManager.removeItem(at: archive) }
        do {
            try ZipArchiveWriter.writeDirectory(root, to: archive)
        } catch {
            throw ExportError.cannotCreateArchive
        }

        if fileManager.fileExists(atPath: target.path) {
            _ = try fileManager.replaceItemAt(target, withItemAt: archive)
        } else {
            try fileManager.moveItem(at: archive, to: target)
        }
    }

    private func documentParts(entry: Entry, boardName: String, assets: [MediaAsset], options: DocxExportOptions) throws -> PackageParts {
        var paragraphs: [String] = []
        let title = entry.title?.isEmpty == false ? entry.title! : "无标题日记"
        paragraphs.append(paragraph(text: title, style: "Title"))
        paragraphs.append(paragraph(text: "日期：\(entry.dayDate) · 板块：\(boardName)"))
        if options.includeMetadata {
            if let mood = entry.mood, let moodValue = Mood.from(mood) {
                paragraphs.append(paragraph(text: "心情：\(moodValue.emoji) \(moodValue.label)"))
            }
            if let weather = entry.weather {
                let temperature = String(format: "%.1f", weather.tempC)
                paragraphs.append(paragraph(text: "天气：\(weather.condition) · \(temperature)℃"))
            }
            if !entry.tags.isEmpty {
                paragraphs.append(paragraph(text: "标签：\(entry.tags.joined(separator: "、"))"))
            }
        }

        var media: [(name: String, data: Data)] = []
        var relationships: [(id: String, target: String)] = []
        paragraphs.append(contentsOf: try bodyParagraphs(entry: entry, media: &media, relationships: &relationships))
        if options.includeAttachments, !assets.isEmpty {
            paragraphs.append(paragraph(text: "其他附件", style: "Heading1"))
            for asset in assets {
                switch asset.type {
                case .photo:
                    guard let path = asset.absoluteLocalPath,
                          let image = NSImage(contentsOfFile: path),
                          let data = Self.pngData(image) else {
                        throw ExportError.cannotReadImage(asset.filename)
                    }
                    let index = media.count + 1
                    let name = "image\(index).png"
                    let id = "rIdImage\(index)"
                    media.append((name, data))
                    relationships.append((id, "media/\(name)"))
                    let size = Self.fittedSize(image.size, maxWidth: 600)
                    paragraphs.append("<w:p>\(Self.drawing(relId: id, documentID: index, width: size.width, height: size.height))</w:p>")
                    paragraphs.append(paragraph(text: "图片：\(asset.filename)"))
                case .video:
                    paragraphs.append(paragraph(text: "视频：\(asset.filename)"))
                case .audio:
                    paragraphs.append(paragraph(text: "音频：\(asset.filename)"))
                }
            }
        }

        let bodyXML = paragraphs.joined()
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>\(bodyXML)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr></w:body></w:document>
        """.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageRelationships = relationships.map { relationship in
            "<Relationship Id=\"\(Self.xmlAttribute(relationship.id))\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"\(Self.xmlAttribute(relationship.target))\"/>"
        }.joined()
        let relationshipXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\(imageRelationships)</Relationships>
        """.trimmingCharacters(in: .whitespacesAndNewlines)
        return PackageParts(document: document, relationships: relationshipXML, media: media)
    }

    private func bodyParagraphs(entry: Entry, media: inout [(name: String, data: Data)], relationships: inout [(id: String, target: String)]) throws -> [String] {
        guard let data = entry.bodyRTF,
              let attributed = (try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil))
                ?? (try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)) else {
            return entry.body.split(separator: "\n", omittingEmptySubsequences: false).map { paragraph(text: String($0)) }
        }

        var result: [String] = []
        let string = attributed.string as NSString
        var paragraphStart = 0
        while paragraphStart <= string.length {
            let range = string.paragraphRange(for: NSRange(location: min(paragraphStart, string.length), length: 0))
            let hasNewline = range.length > 0 && string.substring(with: range).hasSuffix("\n")
            let contentRange = NSRange(location: range.location, length: max(0, range.length - (hasNewline ? 1 : 0)))
            result.append(try richParagraph(attributed, range: contentRange, media: &media, relationships: &relationships))
            if range.length == 0 || range.upperBound >= string.length { break }
            paragraphStart = range.upperBound
        }
        return result.isEmpty ? [paragraph(text: "")] : result
    }

    private func richParagraph(_ attributed: NSAttributedString, range: NSRange, media: inout [(name: String, data: Data)], relationships: inout [(id: String, target: String)]) throws -> String {
        var runs: [String] = []
        attributed.enumerateAttributes(in: range, options: []) { attributes, subrange, _ in
            let value = attributed.attributedSubstring(from: subrange)
            if let attachment = attributes[.attachment] as? NSTextAttachment {
                if let imageData = Self.imageData(for: attachment) {
                    let index = media.count + 1
                    let name = "image\(index).png"
                    let id = "rIdImage\(index)"
                    media.append((name, imageData))
                    relationships.append((id, "media/\(name)"))
                    runs.append(Self.drawing(relId: id, documentID: index, width: attachment.bounds.width, height: attachment.bounds.height))
                }
                return
            }
            let text = value.string.replacingOccurrences(of: "\n", with: "")
            guard !text.isEmpty else { return }
            runs.append(Self.run(text: text, attributes: attributes))
        }

        let paragraphStyle = range.location < attributed.length ? attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle : nil
        let alignment: String
        switch paragraphStyle?.alignment {
        case .center: alignment = "center"
        case .right: alignment = "right"
        case .justified: alignment = "both"
        default: alignment = "left"
        }
        return "<w:p><w:pPr><w:jc w:val=\"\(alignment)\"/></w:pPr>\(runs.joined())</w:p>"
    }

    private func paragraph(text: String, style: String? = nil) -> String {
        let styleXML = style.map { "<w:pPr><w:pStyle w:val=\"\(Self.xmlAttribute($0))\"/></w:pPr>" } ?? ""
        return "<w:p>\(styleXML)<w:r><w:t xml:space=\"preserve\">\(Self.xmlSafe(text))</w:t></w:r></w:p>"
    }

    private static func run(text: String, attributes: [NSAttributedString.Key: Any]) -> String {
        var properties = ""
        if (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true { properties += "<w:b/>" }
        if (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.italic) == true { properties += "<w:i/>" }
        if let font = attributes[.font] as? NSFont { properties += "<w:sz w:val=\"\(Int(font.pointSize * 2))\"/>" }
        if let color = attributes[.foregroundColor] as? NSColor, let rgb = color.usingColorSpace(.deviceRGB) {
            properties += String(format: "<w:color w:val=\"%02X%02X%02X\"/>", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
        }
        let propertyXML = properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>"
        return "<w:r>\(propertyXML)<w:t xml:space=\"preserve\">\(xmlSafe(text))</w:t></w:r>"
    }

    private static func drawing(relId: String, documentID: Int, width: CGFloat, height: CGFloat) -> String {
        let cx = max(1, Int((width > 0 ? width : 240) * 9525))
        let cy = max(1, Int((height > 0 ? height : 180) * 9525))
        return "<w:r><w:drawing><wp:inline xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\"><wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/><wp:docPr id=\"\(documentID)\" name=\"图片 \(documentID)\"/><a:graphic xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\"><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:nvPicPr><pic:cNvPr id=\"\(documentID)\" name=\"图片 \(documentID)\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"\(xmlAttribute(relId))\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"
    }

    private static func fittedSize(_ size: NSSize, maxWidth: CGFloat) -> NSSize {
        guard size.width > 0, size.height > 0, size.width > maxWidth else {
            return size.width > 0 && size.height > 0 ? size : NSSize(width: 240, height: 180)
        }
        let ratio = maxWidth / size.width
        return NSSize(width: maxWidth, height: size.height * ratio)
    }

    private static func imageData(for attachment: NSTextAttachment) -> Data? {
        if let data = attachment.fileWrapper?.regularFileContents, let image = NSImage(data: data) { return pngData(image) }
        if let image = attachment.image { return pngData(image) }
        return nil
    }

    private static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func xmlSafe(_ value: String) -> String {
        let filtered = value.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x9, 0xA, 0xD, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: return true
            default: return false
            }
        }
        return String(String.UnicodeScalarView(filtered))
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func xmlAttribute(_ value: String) -> String { xmlSafe(value) }

    private static func isValidXML(_ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return XMLParser(data: data).parse()
    }

    private func write(_ value: String, to url: URL) throws {
        guard let data = value.data(using: .utf8) else { throw ExportError.invalidXML }
        try data.write(to: url, options: .atomic)
    }

    private func contentTypesXML(media: [(name: String, data: Data)]) -> String {
        let mediaDefault = media.isEmpty ? "" : "<Default Extension=\"png\" ContentType=\"image/png\"/>"
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>\(mediaDefault)<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/><Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/></Types>"
    }

    private static let rootRelationshipsXML = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>"

    private static let stylesXML = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"LXGW WenKai\" w:hAnsi=\"LXGW WenKai\" w:eastAsia=\"霞鹜文楷\"/></w:rPr></w:rPrDefault></w:docDefaults><w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/></w:style><w:style w:type=\"paragraph\" w:styleId=\"Title\"><w:name w:val=\"Title\"/><w:basedOn w:val=\"Normal\"/><w:rPr><w:b/><w:sz w:val=\"32\"/></w:rPr></w:style><w:style w:type=\"paragraph\" w:styleId=\"Heading1\"><w:name w:val=\"heading 1\"/><w:basedOn w:val=\"Normal\"/><w:rPr><w:b/><w:sz w:val=\"26\"/></w:rPr></w:style></w:styles>"
}

/// Minimal ZIP writer for DOCX packages. Storing entries without compression
/// keeps the exporter self-contained and works inside the App Sandbox without
/// starting an external process.
private enum ZipArchiveWriter {
    enum Error: Swift.Error {
        case entryTooLarge
        case archiveWriteFailed
    }

    private struct CentralEntry {
        let name: Data
        let crc32: UInt32
        let size: UInt32
        let offset: UInt32
    }

    static func writeDirectory(_ directory: URL, to archive: URL) throws {
        let fileManager = FileManager.default
        // DOCX requires relationship parts whose filename is `.rels`; do not
        // use `.skipsHiddenFiles` here or those required parts disappear.
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            throw Error.archiveWriteFailed
        }

        var output = Data()
        var central: [CentralEntry] = []
        let rootPath = directory.resolvingSymlinksInPath().path + "/"
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true { continue }
            let filePath = fileURL.resolvingSymlinksInPath().path
            guard filePath.hasPrefix(rootPath) else { throw Error.archiveWriteFailed }
            let relative = String(filePath.dropFirst(rootPath.count))
            let name = Data(relative.utf8)
            let contents = try Data(contentsOf: fileURL)
            guard name.count <= UInt16.max, contents.count <= UInt32.max, output.count <= UInt32.max else {
                throw Error.entryTooLarge
            }
            let crc = crc32(contents)
            let offset = UInt32(output.count)
            output.append(contentsOf: littleEndian(UInt32(0x04034b50)))
            output.append(contentsOf: littleEndian(UInt16(20)))
            output.append(contentsOf: littleEndian(UInt16(0x0800))) // UTF-8 filenames
            output.append(contentsOf: littleEndian(UInt16(0))) // store, no compression
            output.append(contentsOf: littleEndian(UInt16(0)))
            output.append(contentsOf: littleEndian(UInt16(0)))
            output.append(contentsOf: littleEndian(crc))
            output.append(contentsOf: littleEndian(UInt32(contents.count)))
            output.append(contentsOf: littleEndian(UInt32(contents.count)))
            output.append(contentsOf: littleEndian(UInt16(name.count)))
            output.append(contentsOf: littleEndian(UInt16(0)))
            output.append(name)
            output.append(contents)
            central.append(CentralEntry(name: name, crc32: crc, size: UInt32(contents.count), offset: offset))
        }

        guard central.count <= UInt16.max, output.count <= UInt32.max else { throw Error.entryTooLarge }
        let centralOffset = UInt32(output.count)
        for entry in central {
            output.append(contentsOf: littleEndian(UInt32(0x02014b50)))
            output.append(contentsOf: littleEndian(UInt16(20)))
            output.append(contentsOf: littleEndian(UInt16(20)))
            output.append(contentsOf: littleEndian(UInt16(0x0800)))
            output.append(contentsOf: littleEndian(UInt16(0)))
            output.append(contentsOf: littleEndian(UInt16(0)))
            output.append(contentsOf: littleEndian(UInt16(0)))
            output.append(contentsOf: littleEndian(entry.crc32))
            output.append(contentsOf: littleEndian(entry.size))
            output.append(contentsOf: littleEndian(entry.size))
            output.append(contentsOf: littleEndian(UInt16(entry.name.count)))
            output.append(contentsOf: littleEndian(UInt16(0)))
            output.append(contentsOf: littleEndian(UInt16(0)))
            output.append(contentsOf: littleEndian(UInt16(0)))
            output.append(contentsOf: littleEndian(UInt16(0)))
            output.append(contentsOf: littleEndian(UInt32(0)))
            output.append(contentsOf: littleEndian(entry.offset))
            output.append(entry.name)
        }
        let centralSize = UInt32(output.count) - centralOffset
        output.append(contentsOf: littleEndian(UInt32(0x06054b50)))
        output.append(contentsOf: littleEndian(UInt16(0)))
        output.append(contentsOf: littleEndian(UInt16(0)))
        output.append(contentsOf: littleEndian(UInt16(central.count)))
        output.append(contentsOf: littleEndian(UInt16(central.count)))
        output.append(contentsOf: littleEndian(centralSize))
        output.append(contentsOf: littleEndian(centralOffset))
        output.append(contentsOf: littleEndian(UInt16(0)))
        try output.write(to: archive, options: .atomic)
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1
            }
        }
        return ~crc
    }
}
