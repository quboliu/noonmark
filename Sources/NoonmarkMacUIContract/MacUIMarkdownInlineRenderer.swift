import Foundation

/// Shared inline Markdown projection used inside block-level Mac UI rendering.
public enum MacUIMarkdownInlineRenderer {
    public static func attributed(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(source)
    }
}
