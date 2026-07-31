import Combine
import Foundation
import SwiftUI

/// Owns one transient input value without broadcasting it through
/// `NoonmarkStore.objectWillChange`.
///
/// A draft is observed only by the editor that renders it. This keeps marked
/// text updates inside the native input surface while preserving the existing
/// store-facing read/write API used by commands and E2E automation.
@MainActor
final class NoonmarkTextInputDraft: ObservableObject {
    @Published var text: String

    init(_ text: String = "") {
        self.text = text
    }
}

/// Isolates a transient Markdown composer from its surrounding detail page.
///
/// Parent views pass the draft by identity but do not observe it. Each IME
/// update therefore invalidates only this small wrapper.
struct NoonmarkTransientMarkdownComposer: View {
    @ObservedObject var draft: NoonmarkTextInputDraft

    let placeholder: String
    var style: MarkdownEditorStyle = .compact
    var warm = false
    var showsSurface = true
    var height: CGFloat?
    var commitsOnReturn = true
    var onCommit: (() -> Void)?
    let nativeAccessibilityIdentifier: String
    var focusRequest = 0

    var body: some View {
        MarkdownEditor(
            text: $draft.text,
            placeholder: placeholder,
            style: style,
            warm: warm,
            showsSurface: showsSurface,
            height: height,
            commitsOnReturn: commitsOnReturn,
            onCommit: onCommit,
            nativeAccessibilityIdentifier:
            nativeAccessibilityIdentifier,
            focusRequest: focusRequest
        )
    }
}
