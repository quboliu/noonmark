import AppKit
import Foundation
import NoonmarkCore
import NoonmarkMacRuntime

/// Drives Flylight, Sticky Note, and global capture through the signed
/// App and physical WindowServer input. Store access is limited to assertions;
/// every idea mutation goes through the real composer, the card overflow menu,
/// the File menu command, or the Carbon hotkey path.
@MainActor
struct IdeaCaptureE2EAutomation: LaunchAutomationRunnable {
    private enum Mode: String {
        case exercise
        case verify
    }

    private static let alphaDraft = "## e2e Flylight alpha\n- second line https://example.com/@user #SwiftUI @工程"
    private static let alphaBody = "## e2e Flylight alpha\n- second line https://example.com/@user"
    private static let alphaCategoryName = "工程"
    private static let alphaLabelName = "SwiftUI"
    private static let betaBody = "e2e idea beta marker"
    private static let betaEditedBody = "e2e idea beta edited"
    private static let betaAutosavedBody = "e2e idea beta autosaved"
    private static let betaCancelledBody = "e2e idea beta must cancel"
    private static let epsilonBody = "e2e idea epsilon marker"
    private static let discardedDraft = "e2e draft discarded"
    private static let gammaBody = "e2e panel idea gamma"
    private static let deltaBody = "e2e hotkey idea delta"
    private static let restartDraft = "e2e draft survives process restart"

    // Card overflow menu order is Sticky Note intent, edit, delete; the first down
    // arrow highlights the first item once tracking begins.
    private static let cardMenuPinArrowCount = 1
    private static let cardMenuDeleteArrowCount = 3

    private let mode: Mode
    private let resultURL: URL
    private let screenshotDirectory: URL

    static func fromCommandLine() -> Self? {
        guard let rawMode = AppLaunchArguments.value(after: "--e2e-idea-capture"),
              let mode = Mode(rawValue: rawMode),
              let resultPath = AppLaunchArguments.value(
                  after: "--e2e-idea-capture-result-url"
              ),
              let screenshotPath = AppLaunchArguments.value(
                  after: "--e2e-idea-capture-screenshot-dir"
              )
        else {
            return nil
        }
        return Self(
            mode: mode,
            resultURL: URL(fileURLWithPath: resultPath),
            screenshotDirectory: URL(fileURLWithPath: screenshotPath)
        )
    }

    func run(on store: NoonmarkStore) {
        Task { @MainActor in
            do {
                switch mode {
                case .exercise:
                    try await exercise(on: store)
                case .verify:
                    try await verify(on: store)
                }
                try writeResult("ok")
            } catch {
                AppViewTreeE2E.writeDump(beside: resultURL)
                try? writeResult("failed: \(error.localizedDescription)")
            }
            store.persist()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
        }
    }

    private func exercise(on store: NoonmarkStore) async throws {
        let input = try WindowServerInputDriver()
        let mainWindow = try await visibleMainWindow()
        try await activate(mainWindow)

        try await openIdeasPageFromSidebar(
            store: store,
            mainWindow: mainWindow,
            input: input,
            expectEmpty: true
        )
        try await captureScreenshot("ideas-empty.png", of: mainWindow)

        let alpha = try await saveComposerIdea(
            ComposerDraft(
                text: Self.alphaDraft,
                body: Self.alphaBody,
                suggestionsCheckpoint: "## e2e Flylight alpha\n- second line https://example.com/@user #"
            ),
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try assertAlphaClassification(alpha, store: store)
        guard AppViewTreeE2E.view(
            identifier: "ideas.card.markdown.\(alpha.id).0",
            in: mainWindow
        ).flatMap(AppViewTreeE2E.verificationText) == "heading-2",
            AppViewTreeE2E.view(
                identifier: "ideas.card.markdown.\(alpha.id).1",
                in: mainWindow
            ).flatMap(AppViewTreeE2E.verificationText) == "list"
        else {
            throw Failure.failed("Flylight card did not render Markdown blocks")
        }
        try await captureScreenshot("ideas-composer-saved.png", of: mainWindow)

        let beta = try await saveComposerIdea(
            ComposerDraft(text: Self.betaBody, body: Self.betaBody),
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try await exerciseResponsiveLayout(
            expectedIdeaIDs: [beta.id, alpha.id],
            store: store,
            mainWindow: mainWindow
        )
        try await exerciseFilter(
            alphaID: alpha.id,
            betaID: beta.id,
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try await exerciseClassificationFilter(
            alpha: alpha,
            betaID: beta.id,
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try await exerciseReview(
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try await exerciseInlineEdit(
            betaID: beta.id,
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try await captureScreenshot("ideas-edited.png", of: mainWindow)
        try await exerciseDelete(
            betaID: beta.id,
            expectedTimelineCount: 1,
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try await exerciseHiddenTrash(
            betaID: beta.id,
            store: store,
            mainWindow: mainWindow
        )
        try await exerciseStickyNoteLifecycle(
            alphaID: alpha.id,
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        let epsilon = try await saveComposerIdea(
            ComposerDraft(text: Self.epsilonBody, body: Self.epsilonBody),
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try await exerciseDelete(
            betaID: epsilon.id,
            expectedTimelineCount: 1,
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try await exerciseMenuPanel(
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try await exerciseStickyNoteGamma(
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try await exerciseGlobalHotkey(
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try await leaveDraftForRestart(
            store: store,
            input: input
        )
    }

    private func exerciseReview(
        store: NoonmarkStore,
        mainWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws {
        try await click(
            "ideas.review.toggle",
            in: mainWindow,
            input: input
        )
        try await waitUntil("idea review did not replace the recent collection") {
            store.ideaBrowseMode == .review
                && AppViewTreeE2E.view(
                    identifier: "ideas.collection",
                    in: mainWindow
                ).flatMap(AppViewTreeE2E.verificationText) == "review"
                && timelineCount(in: mainWindow) == 0
                && AppViewTreeE2E.view(
                    identifier: "ideas.empty",
                    in: mainWindow
                ).flatMap(AppViewTreeE2E.verificationText) == "review-empty"
        }
        try await click(
            "ideas.review.toggle",
            in: mainWindow,
            input: input
        )
        try await waitUntil("idea review did not return to recent ideas") {
            store.ideaBrowseMode == .recent
                && AppViewTreeE2E.view(
                    identifier: "ideas.collection",
                    in: mainWindow
                ).flatMap(AppViewTreeE2E.verificationText) == "recent"
                && timelineCount(in: mainWindow) == 2
                && AppViewTreeE2E.view(
                    identifier: "ideas.empty",
                    in: mainWindow
                ) == nil
        }
    }

    private func verify(on store: NoonmarkStore) async throws {
        let mainWindow = try await visibleMainWindow()
        try await activate(mainWindow)
        try await waitUntil("Flylight page did not render three cards after restart") {
            store.page == .ideas && timelineCount(in: mainWindow) == 3
        }
        try await waitUntil("idea composer draft did not survive process restart") {
            guard let editor = AppViewTreeE2E.view(
                identifier: "ideas.composer.input",
                in: mainWindow
            ) as? NSTextView else { return false }
            return store.ideaText == Self.restartDraft
                && editor.string == Self.restartDraft
        }

        for body in [Self.alphaBody, Self.deltaBody] {
            guard let idea = store.engine.ideaTimeline().first(where: {
                $0.body == body
            }), let card = AppViewTreeE2E.view(
                identifier: "ideas.card.\(idea.id)",
                in: mainWindow
            ), AppViewTreeE2E.verificationText(for: card) == body
            else {
                throw Failure.failed("idea \"\(body)\" did not survive restart")
            }
        }

        let stickyNotes = store.stickyNoteIdeas
        guard stickyNotes.count == 1, let gamma = stickyNotes.first,
              gamma.body == Self.gammaBody,
              gamma.pinnedAt != nil,
              store.ideaTimelineGroups.flatMap(\.ideas)
                  .contains(where: { $0.id == gamma.id }),
              let gammaCard = AppViewTreeE2E.view(
                  identifier: "ideas.card.\(gamma.id)",
                  in: mainWindow
              ),
              AppViewTreeE2E.verificationText(for: gammaCard) == Self.gammaBody
        else {
            throw Failure.failed("Sticky Note projection did not survive restart")
        }

        try await openStickyNotesPageFromSidebar(
            store: store,
            mainWindow: mainWindow,
            input: try WindowServerInputDriver()
        )
        try await waitUntil("Sticky Note page or wall mode did not survive restart") {
            AppViewTreeE2E.view(
                identifier: "sticky-notes.item.\(gamma.id)",
                in: mainWindow
            ).flatMap(AppViewTreeE2E.verificationText) == Self.gammaBody
                && AppViewTreeE2E.view(
                    identifier: "sticky-notes.presentation",
                    in: mainWindow
                ).flatMap(AppViewTreeE2E.verificationText) == "wall"
        }
        try await captureScreenshot("sticky-notes-restart.png", of: mainWindow)
        try await openIdeasPageFromSidebar(
            store: store,
            mainWindow: mainWindow,
            input: try WindowServerInputDriver()
        )

        let tombstones = store.engine.ideas.values.filter(\.isDeleted)
        guard tombstones.count == 2,
              tombstones.allSatisfy({ tombstone in
                  tombstone.body == ""
                      && tombstone.deletedAt.map {
                          tombstone.updatedAt == $0
                      } == true
                      && AppViewTreeE2E.view(
                          identifier: "ideas.card.\(tombstone.id)",
                          in: mainWindow
                      ) == nil
              })
        else {
            throw Failure.failed("Flylight tombstones did not survive restart")
        }
        guard store.engine.ideaTimeline().contains(where: {
            $0.body == Self.betaEditedBody || $0.body == Self.betaAutosavedBody
                || $0.body == Self.discardedDraft
                || $0.body == Self.epsilonBody
        }) == false else {
            throw Failure.failed("deleted or discarded idea reappeared after restart")
        }

        guard AppViewTreeE2E.view(
            identifier: "sidebar.nav.memoTrash",
            in: mainWindow
        ) == nil,
            AppViewTreeE2E.view(
                identifier: "ideas.trash",
                in: mainWindow
            ) == nil,
            AppViewTreeE2E.identifiers(
                withPrefix: "ideas.trash.item."
            )?.isEmpty != false
        else {
            throw Failure.failed("Flylight trash UI became visible after restart")
        }

        guard let alpha = store.engine.ideaTimeline().first(where: {
            $0.body == Self.alphaBody
        }) else {
            throw Failure.failed("classified idea was missing after restart")
        }
        try assertAlphaClassification(alpha, store: store)
        try await captureScreenshot("ideas-restart.png", of: mainWindow)
    }

    private func openIdeasPageFromSidebar(
        store: NoonmarkStore,
        mainWindow: NSWindow,
        input: WindowServerInputDriver,
        expectEmpty: Bool = false
    ) async throws {
        try await waitUntil("sidebar Flylight row did not render") {
            AppViewTreeE2E.view(identifier: "sidebar.nav.ideas", in: mainWindow)
                != nil
        }
        try await click("sidebar.nav.ideas", in: mainWindow, input: input)
        try await waitUntil("sidebar navigation did not open the Flylight page") {
            guard store.page == .ideas,
                  let pageAnchor = AppViewTreeE2E.view(
                      identifier: "ideas.page",
                      in: mainWindow
                  )
            else {
                return false
            }
            guard AppViewTreeE2E.verificationText(for: pageAnchor)
                == store.copy.navIdeas else { return false }
            guard expectEmpty else { return true }
            return AppViewTreeE2E.view(
                identifier: "ideas.empty",
                in: mainWindow
            ).flatMap(AppViewTreeE2E.verificationText) == "empty"
        }
        if expectEmpty {
            guard AppViewTreeE2E.view(
                identifier: "ideas.composer.placeholder",
                in: mainWindow
            ) != nil else {
                throw Failure.failed("Flylight composer placeholder was missing")
            }
            try await assertEmptyComposerGeometry(
                mainWindow: mainWindow,
                input: input
            )
        }
        guard AppViewTreeE2E.view(
            identifier: "ideas.layout",
            in: mainWindow
        ).flatMap(AppViewTreeE2E.verificationText) == "wide",
            AppViewTreeE2E.view(
                identifier: "ideas.inspector",
                in: mainWindow
            ) != nil
        else {
            throw Failure.failed(
                "default Flylight window did not use the wide timeline-inspector skeleton"
            )
        }
    }

    private func openStickyNotesPageFromSidebar(
        store: NoonmarkStore,
        mainWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws {
        try await waitUntil("sidebar Sticky Note row did not render") {
            AppViewTreeE2E.view(
                identifier: "sidebar.nav.stickyNotes",
                in: mainWindow
            ) != nil
        }
        try await click("sidebar.nav.stickyNotes", in: mainWindow, input: input)
        try await waitUntil("sidebar navigation did not open Sticky Note") {
            store.page == .stickyNotes
                && AppViewTreeE2E.view(
                    identifier: "sticky-notes.page",
                    in: mainWindow
                ).flatMap(AppViewTreeE2E.verificationText)
                == "\(store.stickyNoteIdeas.count)"
        }
    }

    private func assertEmptyComposerGeometry(
        mainWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws {
        guard let editor = AppViewTreeE2E.view(
            identifier: "ideas.composer.input",
            in: mainWindow
        ) as? NSTextView,
            let placeholder = AppViewTreeE2E.view(
                identifier: "ideas.composer.placeholder",
                in: mainWindow
            ),
            let surface = AppViewTreeE2E.view(
                identifier: "ideas.composer.surface",
                in: mainWindow
            )
        else {
            throw Failure.failed("empty composer geometry targets were missing")
        }
        if mainWindow.firstResponder !== editor {
            _ = mainWindow.makeFirstResponder(editor)
        }
        try await waitUntil("empty composer did not take focus") {
            mainWindow.firstResponder === editor
        }
        let focusedCaretFrame = editor.firstRect(
            forCharacterRange: NSRange(location: 0, length: 0),
            actualRange: nil
        )
        try await click("ideas.composer.input", in: mainWindow, input: input)
        try await Task.sleep(nanoseconds: 20_000_000)

        let editorFrame = AppViewTreeE2E.frameInWindow(for: editor)
        let surfaceFrame = AppViewTreeE2E.frameInWindow(for: surface)
        let placeholderFrame = mainWindow.convertToScreen(
            AppViewTreeE2E.frameInWindow(for: placeholder)
        )
        let caretFrame = editor.firstRect(
            forCharacterRange: NSRange(location: 0, length: 0),
            actualRange: nil
        )
        let focusedOffset = abs(
            focusedCaretFrame.midY - placeholderFrame.midY
        )
        let verticalOffset = abs(caretFrame.midY - placeholderFrame.midY)
        let extraLineFrame = editor.layoutManager?.extraLineFragmentRect ?? .zero
        let extraLineInEditor = extraLineFrame.offsetBy(
            dx: editor.textContainerOrigin.x,
            dy: editor.textContainerOrigin.y
        )
        let extraLineInScreen = mainWindow.convertToScreen(
            editor.convert(extraLineInEditor, to: nil)
        )
        try await captureScreenshot("ideas-empty-focused.png", of: mainWindow)
        guard editorFrame.height <= 60,
              surfaceFrame.height <= 60,
              abs(editorFrame.minY - surfaceFrame.minY) <= 1,
              verticalOffset <= 6
        else {
            let scrollView = editor.enclosingScrollView
            let clipView = scrollView?.contentView
            let extraLine = editor.layoutManager?.extraLineFragmentRect
            let editorTop = editor.convert(
                NSRect(x: 0, y: 0, width: 1, height: 1),
                to: nil
            )
            let editorBottom = editor.convert(
                NSRect(x: 0, y: editor.bounds.height - 1, width: 1, height: 1),
                to: nil
            )
            throw Failure.failed(
                "empty composer left phantom space: editor=\(editorFrame), surface=\(surfaceFrame), focusedOffset=\(focusedOffset), caretOffset=\(verticalOffset), editorBounds=\(editor.bounds), visible=\(editor.visibleRect), flipped=\(editor.isFlipped), editorTop=\(editorTop), editorBottom=\(editorBottom), inset=\(editor.textContainerInset), containerOrigin=\(editor.textContainerOrigin), extraLine=\(String(describing: extraLine)), extraLineScreen=\(extraLineInScreen), placeholder=\(placeholderFrame), focusedCaret=\(focusedCaretFrame), caret=\(caretFrame), scrollFrame=\(String(describing: scrollView?.frame)), scrollBounds=\(String(describing: scrollView?.bounds)), clipFrame=\(String(describing: clipView?.frame)), clipBounds=\(String(describing: clipView?.bounds)), clipFlipped=\(String(describing: clipView?.isFlipped))"
            )
        }
    }

    private func exerciseResponsiveLayout(
        expectedIdeaIDs: [IdeaID],
        store: NoonmarkStore,
        mainWindow: NSWindow
    ) async throws {
        let originalFrame = mainWindow.frame
        var compactFrame = originalFrame
        compactFrame.origin.x = originalFrame.maxX
            - NoonmarkVisualMetrics.minimumSize.width
        compactFrame.size.width = NoonmarkVisualMetrics.minimumSize.width
        mainWindow.setFrame(compactFrame, display: true)

        do {
            try await waitUntil("Flylight window did not enter compact continuous flow") {
                mainWindow.contentView?.layoutSubtreeIfNeeded()
                let cards = expectedIdeaIDs.compactMap { id in
                    AppViewTreeE2E.view(
                        identifier: "ideas.card.\(id)",
                        in: mainWindow
                    )
                }
                return store.displayedIdeaGroups.flatMap(\.ideas).map(\.id)
                    == expectedIdeaIDs
                    && cards.count == expectedIdeaIDs.count
                    && cards.allSatisfy {
                        $0.isHiddenOrHasHiddenAncestor == false
                            && AppViewTreeE2E.frameInWindow(for: $0).isEmpty == false
                    }
                    && AppViewTreeE2E.view(
                        identifier: "ideas.layout",
                        in: mainWindow
                    ).flatMap(AppViewTreeE2E.verificationText) == "compact"
                    && AppViewTreeE2E.view(
                        identifier: "ideas.inspector",
                        in: mainWindow
                    ) == nil
                    && AppViewTreeE2E.view(
                        identifier: "ideas.composer.input",
                        in: mainWindow
                    ) != nil
            }
            try await captureScreenshot("ideas-compact-stream.png", of: mainWindow)
        } catch {
            mainWindow.setFrame(originalFrame, display: true)
            throw error
        }

        mainWindow.setFrame(originalFrame, display: true)
        try await waitUntil("Flylight window did not restore its wide inspector layout") {
            mainWindow.contentView?.layoutSubtreeIfNeeded()
            return AppViewTreeE2E.view(
                identifier: "ideas.layout",
                in: mainWindow
            ).flatMap(AppViewTreeE2E.verificationText) == "wide"
                && AppViewTreeE2E.view(
                    identifier: "ideas.inspector",
                    in: mainWindow
                ) != nil
        }
    }

    private struct ComposerDraft {
        let text: String
        let body: String
        var suggestionsCheckpoint: String?
    }

    private func saveComposerIdea(
        _ draft: ComposerDraft,
        store: NoonmarkStore,
        mainWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws -> IdeaEntry {
        var editor: NSTextView?
        try await waitUntil("ideas composer editor did not render") {
            editor = AppViewTreeE2E.view(
                identifier: "ideas.composer.input",
                in: mainWindow
            ) as? NSTextView
            return editor != nil
        }
        guard let editor else {
            throw Failure.failed("ideas composer editor disappeared")
        }
        try await click("ideas.composer.input", in: mainWindow, input: input)
        try await Task.sleep(nanoseconds: 20_000_000)
        if mainWindow.firstResponder as? NSTextView == nil {
            _ = mainWindow.makeFirstResponder(editor)
        }
        try await waitUntil("ideas composer did not become first responder") {
            editor.window?.firstResponder === editor
        }

        if let checkpoint = draft.suggestionsCheckpoint {
            try input.typeUnicode(checkpoint)
            try await waitUntil(
                "ideas composer token suggestions did not appear"
            ) {
                store.ideaText == checkpoint
                    && AppViewTreeE2E.view(
                        identifier: "ideas.composer.suggestions",
                        in: mainWindow
                    ) != nil
            }
            try input.typeUnicode(String(draft.text.dropFirst(checkpoint.count)))
        } else {
            try input.typeUnicode(draft.text)
        }
        try await waitUntil("ideas composer did not receive real text input") {
            editor.string == draft.text && store.ideaText == draft.text
        }

        try input.postKey(keyCode: 36, modifiers: [.command])
        var created: IdeaEntry?
        try await waitUntil("Cmd+Enter did not save the idea draft") {
            created = store.engine.ideaTimeline().first {
                $0.body == draft.body
            }
            guard let created,
                  store.ideaText == "",
                  editor.string == "",
                  let card = AppViewTreeE2E.view(
                      identifier: "ideas.card.\(created.id)",
                      in: mainWindow
                  )
            else {
                return false
            }
            return AppViewTreeE2E.verificationText(for: card) == draft.body
                && timelineCount(in: mainWindow)
                == store.visibleIdeaCount
        }
        guard let created else {
            throw Failure.failed("saved idea disappeared from the timeline")
        }
        guard let group = store.ideaTimelineGroups.first,
              AppViewTreeE2E.view(
                  identifier: "ideas.day.\(group.date)",
                  in: mainWindow
              ) != nil
        else {
            throw Failure.failed("ideas day section header was missing")
        }
        return created
    }

    private func exerciseFilter(
        alphaID: IdeaID,
        betaID: IdeaID,
        store: NoonmarkStore,
        mainWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws {
        try await click(
            "ideas.search.toggle",
            in: mainWindow,
            input: input
        )
        try await waitUntil("ideas search field did not appear") {
            AppViewTreeE2E.view(
                identifier: "ideas.filter",
                in: mainWindow
            ) != nil
        }
        try await click("ideas.filter", in: mainWindow, input: input)
        try await waitUntil("ideas filter field did not accept focus") {
            mainWindow.firstResponder is NSTextView
        }
        try input.typeUnicode("alpha")
        try await waitUntil("ideas filter did not narrow the timeline") {
            store.ideaFilterText == "alpha"
                && timelineCount(in: mainWindow) == 1
                && AppViewTreeE2E.view(
                    identifier: "ideas.card.\(alphaID)",
                    in: mainWindow
                ) != nil
                && AppViewTreeE2E.view(
                    identifier: "ideas.card.\(betaID)",
                    in: mainWindow
                ) == nil
        }
        try await captureScreenshot("ideas-filtered.png", of: mainWindow)

        try input.postKey(keyCode: 0, modifiers: [.command])
        try input.postKey(keyCode: 51)
        try await waitUntil("clearing the ideas filter did not restore the timeline") {
            store.ideaFilterText == "" && timelineCount(in: mainWindow) == 2
        }

        try input.typeUnicode(Self.alphaLabelName.lowercased())
        try await waitUntil("ideas search did not match a label name") {
            store.ideaFilterText == Self.alphaLabelName.lowercased()
                && timelineCount(in: mainWindow) == 1
                && AppViewTreeE2E.view(
                    identifier: "ideas.card.\(alphaID)",
                    in: mainWindow
                ) != nil
                && AppViewTreeE2E.view(
                    identifier: "ideas.card.\(betaID)",
                    in: mainWindow
                ) == nil
        }
        try await click(
            "ideas.search.toggle",
            in: mainWindow,
            input: input
        )
        try await waitUntil("closing search left an invisible filter active") {
            store.ideaFilterText == ""
                && timelineCount(in: mainWindow) == 2
                && AppViewTreeE2E.view(
                    identifier: "ideas.filter",
                    in: mainWindow
                ) == nil
        }
    }

    private func exerciseClassificationFilter(
        alpha: IdeaEntry,
        betaID: IdeaID,
        store: NoonmarkStore,
        mainWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws {
        guard let labelID = alpha.labelIDs.first else {
            throw Failure.failed("classified idea had no label to filter by")
        }
        try await click(
            "ideas.card.filter.\(alpha.id).label.\(labelID)",
            in: mainWindow,
            input: input
        )
        try await waitUntil(
            "idea label click did not activate the classification filter"
        ) {
            store.ideaClassificationFilter == .label(labelID)
                && AppViewTreeE2E.view(
                    identifier: "ideas.filter.classification",
                    in: mainWindow
                ).flatMap(AppViewTreeE2E.verificationText)
                == "#\(Self.alphaLabelName)"
                && timelineCount(in: mainWindow) == 1
                && AppViewTreeE2E.view(
                    identifier: "ideas.card.\(alpha.id)",
                    in: mainWindow
                ) != nil
                && AppViewTreeE2E.view(
                    identifier: "ideas.card.\(betaID)",
                    in: mainWindow
                ) == nil
        }
        try await captureScreenshot(
            "ideas-classification-filtered.png",
            of: mainWindow
        )

        try await click(
            "ideas.search.toggle",
            in: mainWindow,
            input: input
        )
        try await waitUntil("ideas search field did not reopen") {
            AppViewTreeE2E.view(
                identifier: "ideas.filter",
                in: mainWindow
            ) != nil
        }
        try await click("ideas.filter", in: mainWindow, input: input)
        try await waitUntil("ideas filter field did not accept focus") {
            mainWindow.firstResponder is NSTextView
        }
        try input.typeUnicode("beta")
        try await waitUntil(
            "classification and text filters did not AND-combine"
        ) {
            store.ideaFilterText == "beta"
                && timelineCount(in: mainWindow) == 0
                && AppViewTreeE2E.view(
                    identifier: "ideas.empty",
                    in: mainWindow
                ).flatMap(AppViewTreeE2E.verificationText)
                == "no-filter-match"
        }
        try input.postKey(keyCode: 0, modifiers: [.command])
        try input.postKey(keyCode: 51)
        try await waitUntil(
            "clearing the text filter did not restore label matches"
        ) {
            store.ideaFilterText == "" && timelineCount(in: mainWindow) == 1
        }

        try await click(
            "ideas.filter.classification.clear",
            in: mainWindow,
            input: input
        )
        try await waitUntil(
            "clearing the classification filter did not restore the timeline"
        ) {
            store.ideaClassificationFilter == nil
                && AppViewTreeE2E.view(
                    identifier: "ideas.filter.classification",
                    in: mainWindow
                ) == nil
                && timelineCount(in: mainWindow) == 2
        }
    }

    private func exerciseInlineEdit(
        betaID: IdeaID,
        store: NoonmarkStore,
        mainWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws {
        var editor = try await beginInlineEditor(
            ideaID: betaID,
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try input.postKey(keyCode: 0, modifiers: [.command])
        try input.typeUnicode(Self.betaEditedBody)
        try await waitUntil("idea inline edit did not receive typed text") {
            editor.string == Self.betaEditedBody
                && store.ideaEditText == Self.betaEditedBody
        }
        try input.postKey(keyCode: 36, modifiers: [.command])
        try await waitUntil("idea inline edit save did not update the card") {
            guard store.editingIdeaID == nil,
                  store.engine.ideas[betaID]?.body == Self.betaEditedBody,
                  let card = AppViewTreeE2E.view(
                      identifier: "ideas.card.\(betaID)",
                      in: mainWindow
                  )
            else {
                return false
            }
            return AppViewTreeE2E.verificationText(for: card)
                == Self.betaEditedBody
        }

        editor = try await beginInlineEditor(
            ideaID: betaID,
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try input.postKey(keyCode: 0, modifiers: [.command])
        try input.typeUnicode(Self.betaCancelledBody)
        try input.postKey(keyCode: 53)
        try await waitUntil("Escape did not cancel the inline edit") {
            store.editingIdeaID == nil
                && store.engine.ideas[betaID]?.body == Self.betaEditedBody
                && AppViewTreeE2E.view(
                    identifier: "ideas.card.\(betaID)",
                    in: mainWindow
                ).flatMap(AppViewTreeE2E.verificationText)
                == Self.betaEditedBody
        }

        editor = try await beginInlineEditor(
            ideaID: betaID,
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try input.postKey(keyCode: 0, modifiers: [.command])
        try input.typeUnicode(Self.betaAutosavedBody)
        try await waitUntil("inline edit autosave body did not reach the editor") {
            editor.string == Self.betaAutosavedBody
                && store.ideaEditText == Self.betaAutosavedBody
        }
        try await click(
            "ideas.search.toggle",
            in: mainWindow,
            input: input
        )
        try await waitUntil("search field did not appear for inline edit blur") {
            AppViewTreeE2E.view(
                identifier: "ideas.filter",
                in: mainWindow
            ) != nil
        }
        try await click(
            "ideas.filter",
            in: mainWindow,
            input: input
        )
        try await waitUntil("inline edit did not save after losing focus") {
            store.editingIdeaID == nil
                && store.engine.ideas[betaID]?.body == Self.betaAutosavedBody
                && mainWindow.firstResponder !== editor
        }
        try await click(
            "ideas.search.toggle",
            in: mainWindow,
            input: input
        )
        try await waitUntil("inline edit autosave left search expanded") {
            AppViewTreeE2E.view(
                identifier: "ideas.filter",
                in: mainWindow
            ) == nil
        }
    }

    private func beginInlineEditor(
        ideaID: IdeaID,
        store: NoonmarkStore,
        mainWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws -> NSTextView {
        try await waitUntil("idea body did not render before inline editing") {
            guard let body = AppViewTreeE2E.view(
                identifier: "ideas.card.body.\(ideaID)",
                in: mainWindow
            ) else { return false }
            return body.isHiddenOrHasHiddenAncestor == false
                && body.visibleRect.isEmpty == false
        }
        try await doubleClick(
            "ideas.card.body.\(ideaID)",
            in: mainWindow,
            input: input
        )
        var editor: NSTextView?
        try await waitUntil("idea inline edit field did not take focus") {
            guard store.editingIdeaID == ideaID else { return false }
            editor = AppViewTreeE2E.view(
                identifier: "ideas.card.edit-field.\(ideaID).input",
                in: mainWindow
            ) as? NSTextView
            return editor != nil && editor?.window?.firstResponder === editor
        }
        guard let editor else {
            throw Failure.failed("idea inline edit field disappeared")
        }
        return editor
    }

    private func exerciseDelete(
        betaID: IdeaID,
        expectedTimelineCount: Int,
        store: NoonmarkStore,
        mainWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws {
        try await chooseCardMenuItem(
            cardID: betaID,
            downArrowCount: Self.cardMenuDeleteArrowCount,
            in: mainWindow,
            input: input
        )
        try await waitUntil("idea delete did not leave a tombstone") {
            store.engine.ideas[betaID]?.isDeleted == true
                && timelineCount(in: mainWindow) == expectedTimelineCount
                && AppViewTreeE2E.view(
                    identifier: "ideas.card.\(betaID)",
                    in: mainWindow
                ) == nil
        }
    }

    private func exerciseHiddenTrash(
        betaID: IdeaID,
        store: NoonmarkStore,
        mainWindow: NSWindow
    ) async throws {
        try await waitUntil("Flylight deletion did not register a tombstone") {
            store.engine.ideaTrash().map(\.id) == [betaID]
        }
        guard store.page == .ideas,
              AppViewTreeE2E.view(
                  identifier: "sidebar.nav.memoTrash",
                  in: mainWindow
              ) == nil,
              AppViewTreeE2E.view(
                  identifier: "ideas.trash",
                  in: mainWindow
              ) == nil,
              AppViewTreeE2E.view(
                  identifier: "ideas.trash.item.\(betaID)",
                  in: mainWindow
              ) == nil
        else {
            throw Failure.failed("Flylight trash or restore UI was exposed")
        }
    }

    private func exerciseStickyNoteLifecycle(
        alphaID: IdeaID,
        store: NoonmarkStore,
        mainWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws {
        let prePinMenuView = AppViewTreeE2E.view(
            identifier: "ideas.card.menu.\(alphaID)",
            in: mainWindow
        )
        try await chooseCardMenuItem(
            cardID: alphaID,
            downArrowCount: Self.cardMenuPinArrowCount,
            in: mainWindow,
            input: input
        )
        try await waitUntil(
            "Flylight did not join Sticky Note while remaining in its source timeline"
        ) {
            store.engine.ideas[alphaID]?.pinnedAt != nil
                && store.stickyNoteIdeas.map(\.id) == [alphaID]
                && AppViewTreeE2E.view(
                    identifier: "ideas.card.\(alphaID)",
                    in: mainWindow
                ).flatMap(AppViewTreeE2E.verificationText) == Self.alphaBody
                && store.ideaTimelineGroups.flatMap(\.ideas).contains {
                    $0.id == alphaID
                }
                && AppViewTreeE2E.view(
                    identifier: "ideas.pinned",
                    in: mainWindow
                ) == nil
                && timelineCount(in: mainWindow) == 1
        }
        try await waitUntil("Sticky membership did not refresh the card menu") {
            AppViewTreeE2E.view(
                identifier: "ideas.card.menu.\(alphaID)",
                in: mainWindow
            ) !== prePinMenuView
        }

        try await openStickyNotesPageFromSidebar(
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try await waitUntil("selected Flylight did not appear in Sticky Note") {
            AppViewTreeE2E.view(
                identifier: "sticky-notes.item.\(alphaID)",
                in: mainWindow
            ).flatMap(AppViewTreeE2E.verificationText) == Self.alphaBody
        }
        try await click("sticky-notes.mode.wall", in: mainWindow, input: input)
        try await waitUntil("Sticky Note did not switch to note wall") {
            AppViewTreeE2E.view(
                identifier: "sticky-notes.presentation",
                in: mainWindow
            ).flatMap(AppViewTreeE2E.verificationText) == "wall"
        }
        try await captureScreenshot("sticky-notes-wall.png", of: mainWindow)
        try await click("sticky-notes.mode.stream", in: mainWindow, input: input)
        try await waitUntil("Sticky Note did not switch back to stream") {
            AppViewTreeE2E.view(
                identifier: "sticky-notes.presentation",
                in: mainWindow
            ).flatMap(AppViewTreeE2E.verificationText) == "stream"
        }
        try await doubleClick(
            "sticky-notes.item.\(alphaID)",
            in: mainWindow,
            input: input
        )
        try await waitUntil(
            "Sticky Note source navigation did not reveal its Flylight card"
        ) {
            store.page == .ideas
                && store.selectedIdeaID == alphaID
                && AppViewTreeE2E.view(
                    identifier: "ideas.card.\(alphaID)",
                    in: mainWindow
                ).flatMap(AppViewTreeE2E.verificationText) == Self.alphaBody
        }
        try await chooseCardMenuItem(
            cardID: alphaID,
            downArrowCount: Self.cardMenuPinArrowCount,
            in: mainWindow,
            input: input
        )
        try await waitUntil(
            "removing Sticky Note also removed or hid its Flylight source"
        ) {
            store.engine.ideas[alphaID]?.pinnedAt == nil
                && store.stickyNoteIdeas.isEmpty
                && AppViewTreeE2E.view(
                    identifier: "ideas.pinned",
                    in: mainWindow
                ) == nil
                && store.ideaTimelineGroups.flatMap(\.ideas).contains {
                    $0.id == alphaID
                }
                && timelineCount(in: mainWindow) == 1
        }
    }

    private func exerciseMenuPanel(
        store: NoonmarkStore,
        mainWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws {
        let captureItem = try ideaCaptureMenuItem(store: store)

        NSApp.sendAction(
            NoonmarkMenuAction.showIdeaCapture,
            to: captureItem.target,
            from: captureItem
        )
        var panel = try await waitForPanel(expectedTitle: store.copy.ideaCapturePanelTitle)
        var editor: NSTextView?
        try await waitUntil("idea capture panel did not focus its field") {
            editor = panel.firstResponder as? NSTextView
            return panel.isKeyWindow && editor != nil
        }
        try input.typeUnicode(Self.discardedDraft)
        try input.postKey(keyCode: 53)
        try await waitUntil("Escape did not close the panel without saving") {
            panel.isVisible == false
                && store.ideaText == Self.discardedDraft
                && store.engine.ideaTimeline().contains {
                    $0.body == Self.discardedDraft
                } == false
                && store.engine.ideaTimeline().count == 1
        }

        NSApp.sendAction(
            NoonmarkMenuAction.showIdeaCapture,
            to: captureItem.target,
            from: captureItem
        )
        panel = try await waitForPanel(expectedTitle: store.copy.ideaCapturePanelTitle)
        try await waitUntil("reopened panel did not restore and focus its draft") {
            editor = panel.firstResponder as? NSTextView
            return panel.isKeyWindow
                && editor?.string == Self.discardedDraft
                && store.ideaText == Self.discardedDraft
        }
        try input.postKey(keyCode: 0, modifiers: [.command])
        try input.typeUnicode(Self.gammaBody)
        try await waitUntil("restored panel draft was not replaced") {
            editor?.string == Self.gammaBody
                && store.ideaText == Self.gammaBody
        }
        try await captureScreenshot("idea-capture-panel.png", of: panel)
        try input.postKey(keyCode: 36, modifiers: [.command])
        try await waitUntil("panel Cmd+Return did not persist the idea") {
            panel.isVisible == false
                && store.engine.ideaTimeline().contains {
                    $0.body == Self.gammaBody
                }
                && timelineCount(in: mainWindow) == 2
        }
    }

    private func exerciseStickyNoteGamma(
        store: NoonmarkStore,
        mainWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws {
        guard let gamma = store.engine.ideaTimeline().first(where: {
            $0.body == Self.gammaBody
        }) else {
            throw Failure.failed("panel Flylight was missing before Sticky selection")
        }
        try await chooseCardMenuItem(
            cardID: gamma.id,
            downArrowCount: Self.cardMenuPinArrowCount,
            in: mainWindow,
            input: input
        )
        try await waitUntil("panel Flylight did not join Sticky Note") {
            store.engine.ideas[gamma.id]?.pinnedAt != nil
                && store.stickyNoteIdeas.map(\.id) == [gamma.id]
                && AppViewTreeE2E.view(
                    identifier: "ideas.card.\(gamma.id)",
                    in: mainWindow
                ).flatMap(AppViewTreeE2E.verificationText) == Self.gammaBody
                && store.ideaTimelineGroups.flatMap(\.ideas).contains {
                    $0.id == gamma.id
                }
                && timelineCount(in: mainWindow) == 2
        }
        try await openStickyNotesPageFromSidebar(
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try await click("sticky-notes.mode.wall", in: mainWindow, input: input)
        try await waitUntil("Sticky Note wall did not render the panel Flylight") {
            AppViewTreeE2E.view(
                identifier: "sticky-notes.presentation",
                in: mainWindow
            ).flatMap(AppViewTreeE2E.verificationText) == "wall"
                && AppViewTreeE2E.view(
                    identifier: "sticky-notes.item.\(gamma.id)",
                    in: mainWindow
                ).flatMap(AppViewTreeE2E.verificationText) == Self.gammaBody
        }
        try await captureScreenshot("sticky-notes-selected.png", of: mainWindow)
        try await openIdeasPageFromSidebar(
            store: store,
            mainWindow: mainWindow,
            input: input
        )
    }

    private func exerciseGlobalHotkey(
        store: NoonmarkStore,
        mainWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws {
        try await activate(mainWindow)
        try input.postKey(keyCode: 13, modifiers: [.command])
        try await waitUntil("Command-W did not close the main window") {
            mainWindow.isVisible == false
                && NSApp.windows.contains {
                    $0.identifier
                        == NoonmarkIdeaCaptureWindowController.windowIdentifier
                        && $0.isVisible
                } == false
        }

        let finder = try finderApplication()
        guard finder.activate(options: []) else {
            throw Failure.failed("Finder rejected foreground activation")
        }
        try await waitUntil("Finder did not become the foreground app") {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
                == finder.processIdentifier
        }

        try input.postKey(keyCode: 34, modifiers: [.control, .shift])
        let panel = try await waitForPanel(
            expectedTitle: store.copy.ideaCapturePanelTitle
        )
        guard panel is NSPanel,
              panel.isKeyWindow,
              mainWindow.isVisible == false
        else {
            throw Failure.failed(
                "global idea hotkey did not open only the capture panel"
            )
        }

        var editor: NSTextView?
        try await waitUntil("idea capture field did not become first responder") {
            editor = panel.firstResponder as? NSTextView
            return editor != nil
        }
        try input.typeUnicode(Self.deltaBody)
        try await waitUntil("idea capture panel did not receive real text input") {
            editor?.string == Self.deltaBody
        }

        try input.postKey(keyCode: 34, modifiers: [.control, .shift])
        try await waitUntil("repeated idea hotkey lost the in-progress draft") {
            panel.isVisible && panel.isKeyWindow && editor?.string == Self.deltaBody
        }

        try input.postKey(keyCode: 36, modifiers: [.command])
        try await waitUntil("Cmd+Return did not submit the global idea capture") {
            panel.isVisible == false
                && mainWindow.isVisible == false
                && store.engine.ideaTimeline().contains {
                    $0.body == Self.deltaBody
                }
        }
        try await waitUntil("idea capture did not restore Finder focus") {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
                == finder.processIdentifier
        }
    }

    private func leaveDraftForRestart(
        store: NoonmarkStore,
        input: WindowServerInputDriver
    ) async throws {
        try input.postKey(keyCode: 34, modifiers: [.control, .shift])
        let panel = try await waitForPanel(
            expectedTitle: store.copy.ideaCapturePanelTitle
        )
        var editor: NSTextView?
        try await waitUntil("restart draft panel did not focus its editor") {
            editor = panel.firstResponder as? NSTextView
            return panel.isKeyWindow && editor != nil
        }
        try input.typeUnicode(Self.restartDraft)
        try await waitUntil("restart draft did not reach the shared composer") {
            editor?.string == Self.restartDraft
                && store.ideaText == Self.restartDraft
        }
        try input.postKey(keyCode: 53)
        try await waitUntil("restart draft panel did not close safely") {
            panel.isVisible == false
                && store.ideaText == Self.restartDraft
                && store.engine.ideaTimeline().contains {
                    $0.body == Self.restartDraft
                } == false
        }
    }

    private func chooseCardMenuItem(
        cardID: IdeaID,
        downArrowCount: Int,
        in mainWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws {
        let probe = MenuTrackingProbe()
        defer { probe.stop() }
        try await click("ideas.card.menu.\(cardID)", in: mainWindow, input: input)
        try await waitUntil("idea card overflow menu did not begin tracking") {
            probe.didBeginTracking
        }
        for _ in 0 ..< downArrowCount {
            try input.postKey(keyCode: 125)
        }
        try input.postKey(keyCode: 36)
        // Reopening the same card's menu while the previous presentation is
        // still tearing down can surface the pre-mutation item list, so
        // every selection waits for tracking to fully end before returning.
        try await waitUntil("idea card overflow menu did not end tracking") {
            probe.didEndTracking
        }
    }

    private func ideaCaptureMenuItem(store: NoonmarkStore) throws -> NSMenuItem {
        guard let mainMenu = NSApp.mainMenu,
              let fileItem = mainMenu.items.first(where: {
                  $0.submenu?.title == store.copy.fileMenu
              }),
              let item = fileItem.submenu?.items.first(where: {
                  $0.action == NoonmarkMenuAction.showIdeaCapture
              })
        else {
            throw Failure.failed("File menu did not expose the idea capture command")
        }
        guard item.title == store.copy.ideaCaptureCommand else {
            throw Failure.failed(
                "idea capture menu title was \"\(item.title)\", "
                    + "expected \"\(store.copy.ideaCaptureCommand)\""
            )
        }
        return item
    }

    private func assertAlphaClassification(
        _ idea: IdeaEntry,
        store: NoonmarkStore
    ) throws {
        guard idea.body == Self.alphaBody,
              let categoryID = idea.categoryID,
              idea.labelIDs.count == 1
        else {
            throw Failure.failed("idea #/@ tokens did not resolve to a classification")
        }
        let catalog = store.classificationCatalog()
        guard let category = catalog?.categories.first(where: {
            $0.id == categoryID.description
        }), category.name == Self.alphaCategoryName,
            let label = catalog?.labels.first(where: {
                $0.id == idea.labelIDs[0].description
            }), label.name == Self.alphaLabelName,
            store.ideaClassificationLine(for: idea) != nil
        else {
            throw Failure.failed(
                "idea classification did not reference "
                    + "@\(Self.alphaCategoryName)/#\(Self.alphaLabelName)"
            )
        }
    }

    private func timelineCount(in window: NSWindow) -> Int? {
        guard let anchor = AppViewTreeE2E.view(
            identifier: "ideas.timeline",
            in: window
        ), let text = AppViewTreeE2E.verificationText(for: anchor)
        else {
            return nil
        }
        return Int(text)
    }

    private func waitForPanel(expectedTitle: String) async throws -> NSWindow {
        var panel: NSWindow?
        try await waitUntil("idea capture panel did not become visible") {
            panel = NSApp.windows.first {
                $0.identifier
                    == NoonmarkIdeaCaptureWindowController.windowIdentifier
                    && $0.isVisible
            }
            guard let panel,
                  let anchor = AppViewTreeE2E.view(
                      identifier: "idea-capture.window",
                      in: panel
                  )
            else {
                return false
            }
            return AppViewTreeE2E.verificationText(for: anchor) == expectedTitle
        }
        guard let panel else {
            throw Failure.failed("idea capture panel disappeared after opening")
        }
        return panel
    }

    private func captureScreenshot(_ name: String, of window: NSWindow) async throws {
        do {
            try AppE2EScreenshot.captureContent(
                of: window,
                to: screenshotDirectory.appendingPathComponent(name)
            )
        } catch {
            throw Failure.failed(
                "idea capture screenshot \(name) failed: "
                    + error.localizedDescription
            )
        }
    }

    private func visibleMainWindow() async throws -> NSWindow {
        var window: NSWindow?
        try await waitUntil("idea capture main window was not visible") {
            window = NSApp.windows.first {
                $0 is NoonmarkWindow
                    && $0.isVisible
                    && $0.isMiniaturized == false
            }
            return window != nil
        }
        guard let window else {
            throw Failure.failed("idea capture main window disappeared")
        }
        return window
    }

    private func activate(_ window: NSWindow) async throws {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        try await waitUntil("idea capture main window did not become active") {
            NSApp.isActive && window.isMainWindow && window.isKeyWindow
        }
    }

    private func click(
        _ identifier: String,
        in expectedWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws {
        let resolveTarget:
            @MainActor @Sendable () throws
            -> WindowServerInputDriver.PointerCoordinate = {
            guard let currentView = AppViewTreeE2E.view(
                identifier: identifier,
                in: expectedWindow
            ), currentView.window === expectedWindow,
                currentView.isHiddenOrHasHiddenAncestor == false
            else {
                throw Failure.failed(
                    "idea capture target changed before mouseDown: \(identifier)"
                )
            }
            let frame = AppViewTreeE2E.frameInWindow(for: currentView)
            let visibleFrame = currentView.convert(
                currentView.visibleRect,
                to: nil
            )
            let clickableFrame = frame.intersection(visibleFrame)
            guard clickableFrame.isNull == false,
                  clickableFrame.isEmpty == false
            else {
                throw Failure.failed(
                    "idea capture target has no clickable visible area: \(identifier)"
                )
            }
            return try input.pointerCoordinate(
                windowPoint: NSPoint(
                    x: clickableFrame.midX,
                    y: clickableFrame.midY
                ),
                in: expectedWindow
            )
        }
        for attempt in 0 ..< 3 {
            try await activate(expectedWindow)
            do {
                try await input.postClick(
                    at: try resolveTarget(),
                    modifiers: [],
                    resolveTarget: resolveTarget
                )
                return
            } catch {
                guard attempt < 2,
                      isActivationInterruption(error)
                else {
                    throw Failure.failed(
                        "idea capture WindowServer click failed for \(identifier): "
                            + error.localizedDescription
                    )
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func doubleClick(
        _ identifier: String,
        in expectedWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws {
        let resolveTarget:
            @MainActor @Sendable () throws
            -> WindowServerInputDriver.PointerCoordinate = {
            guard let currentView = AppViewTreeE2E.view(
                identifier: identifier,
                in: expectedWindow
            ), currentView.window === expectedWindow,
                currentView.isHiddenOrHasHiddenAncestor == false
            else {
                throw Failure.failed(
                    "idea edit target changed before double click: \(identifier)"
                )
            }
            let frame = AppViewTreeE2E.frameInWindow(for: currentView)
            let visibleFrame = currentView.convert(
                currentView.visibleRect,
                to: nil
            )
            let clickableFrame = frame.intersection(visibleFrame)
            guard clickableFrame.isNull == false,
                  clickableFrame.isEmpty == false
            else {
                throw Failure.failed(
                    "idea edit target has no visible area: \(identifier)"
                )
            }
            return try input.pointerCoordinate(
                windowPoint: NSPoint(
                    x: clickableFrame.midX,
                    y: clickableFrame.midY
                ),
                in: expectedWindow
            )
        }
        try await activate(expectedWindow)
        try await input.postDoubleClick(
            at: try resolveTarget(),
            modifiers: [],
            resolveTarget: resolveTarget
        )
    }

    private func isActivationInterruption(_ error: Error) -> Bool {
        guard let failure = error as? WindowServerInputDriver.Failure,
              case let .inputContextUnavailable(report) = failure
        else {
            return false
        }
        return report.expectedWindowVisible
            && report.expectedWindowMiniaturized == false
            && (report.appActive == false || report.expectedWindowIsKey == false)
    }

    private func finderApplication() throws -> NSRunningApplication {
        guard let finder = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.finder"
        ).first else {
            throw Failure.failed("Finder was not running")
        }
        return finder
    }

    private func waitUntil(
        _ failure: String,
        attempts: Int = 120,
        condition: @MainActor () throws -> Bool
    ) async throws {
        for _ in 0 ..< attempts {
            if try condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Failure.failed(failure)
    }

    private func writeResult(_ result: String) throws {
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
    }

    @MainActor
    private final class MenuTrackingProbe: @unchecked Sendable {
        private(set) var didBeginTracking = false
        private(set) var didEndTracking = false
        private var observers: [NSObjectProtocol] = []

        init() {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSMenu.didBeginTrackingNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.didBeginTracking = true
                    }
                }
            )
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSMenu.didEndTrackingNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.didEndTracking = true
                    }
                }
            )
        }

        func stop() {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers = []
        }
    }

    private enum Failure: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message):
                message
            }
        }
    }
}
