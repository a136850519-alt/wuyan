import AppKit
import Testing
@testable import Wuyan

@Suite("Rich text image paste")
struct RichTextEditorTests {
    @Test("图片粘贴缩放到 720 像素以内")
    func pastedImageIsScaled() {
        let image = NSImage(size: NSSize(width: 1440, height: 720))
        let scaled = RichTextImageSupport.scaled(image, maxWidth: 720)
        #expect(scaled.size.width == 720)
        #expect(scaled.size.height == 360)
    }
}
