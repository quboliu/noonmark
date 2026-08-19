import Foundation
@testable import NoonmarkMacUIContract
import XCTest

final class MacUIMarkdownInlineRendererTests: XCTestCase {
    func testPreservesAuthoredLineBreaksWhileRenderingInlineMarkdown() throws {
        let rendered = MacUIMarkdownInlineRenderer.attributed(
            "**第一行**\n第二行 [链接](https://example.com)"
        )

        XCTAssertEqual(String(rendered.characters), "第一行\n第二行 链接")
        XCTAssertTrue(
            rendered.runs.contains {
                $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            }
        )
        XCTAssertTrue(rendered.runs.contains { $0.link?.absoluteString == "https://example.com" })
    }
}
