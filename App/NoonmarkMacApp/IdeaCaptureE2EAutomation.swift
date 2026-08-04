import AppKit
import Foundation
import NoonmarkCore
import NoonmarkDiagnostics
import NoonmarkMacRuntime
import NoonmarkStorage
import SQLite3

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

    private static let alphaDraft = "## e2e Flylight alpha\n- second line https://example.com/@user #SwiftUI @\"Client Work\""
    private static let alphaBody = "## e2e Flylight alpha\n- second line https://example.com/@user"
    private static let alphaEditedBody = "## e2e Flylight alpha edited\n- second line https://example.com/@user"
    private static let alphaCategoryName = "Client Work"
    private static let alphaLabelName = "SwiftUI"
    private static let betaBody = "e2e idea beta marker"
    private static let betaEditedBody = "e2e idea beta edited"
    private static let betaSwitchedBody = "e2e idea beta saved before switching cards"
    private static let betaNavigationBody = "e2e idea beta saved before navigation"
    private static let betaAutosavedBody = "e2e idea beta autosaved"
    private static let betaCancelledBody = "e2e idea beta must cancel"
    private static let epsilonBody = "e2e idea epsilon marker"
    private static let discardedDraft = "e2e draft discarded"
    private static let gammaBody = "e2e panel idea gamma"
    private static let gammaSuggestionDraft = "e2e panel idea gamma @工"
    private static let gammaCompletedDraft = "e2e panel idea gamma @工程 "
    private static let deltaBody = "e2e hotkey idea delta"
    private static let cancellationProofBody = "e2e cancellation persistence proof"
    private static let cancellationAttemptBody = "e2e cancellation must not persist"
    private static let restartDraft = "e2e draft survives process restart"
    private static let collapsedDraft = "#Sw"
    private static let sourceBrowseFilter = "alpha edited"

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
        try prepareClassificationFixture(store: store)

        try await openIdeasPageFromSidebar(
            store: store,
            mainWindow: mainWindow,
            input: input,
            expectEmpty: true
        )
        try await captureScreenshot("ideas-empty.png", of: mainWindow)
        try assertCollapsedComposerGeometry(mainWindow: mainWindow, store: store)
        try await assertEmptyComposerGeometry(
            mainWindow: mainWindow,
            input: input
        )
        try await exerciseDirtyComposerCollapse(
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try await exerciseComposerTools(
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        let alpha = try await saveComposerIdea(
            ComposerDraft(
                text: Self.alphaDraft,
                body: Self.alphaBody,
                suggestionsCheckpoint: "## e2e Flylight alpha\n- second line https://example.com/@user #"
            ),
            store: store,
            mainWindow: mainWindow,
            input: input,
            provesPersistenceRetry: true
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
        try await Task.sleep(nanoseconds: 250_000_000)
        try assertComposerDoesNotOverlapCollection(in: mainWindow)
        try await captureScreenshot("ideas-composer-saved.png", of: mainWindow)

        let beta = try await saveComposerIdea(
            ComposerDraft(text: Self.betaBody, body: Self.betaBody),
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try await exerciseFlylightDetailRail(
            expectedIdeaIDs: [beta.id, alpha.id],
            store: store,
            mainWindow: mainWindow,
            input: input
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
            alphaID: alpha.id,
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
        let cancellationProof = try await saveComposerIdea(
            ComposerDraft(
                text: Self.cancellationProofBody,
                body: Self.cancellationProofBody
            ),
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try await exerciseCancellationPersistenceProof(
            idea: cancellationProof,
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
        try await waitUntil("Flylight page did not render four cards after restart") {
            store.page == .ideas && timelineCount(in: mainWindow) == 4
        }
        try await waitUntil("idea composer draft did not survive process restart") {
            guard let editor = AppViewTreeE2E.view(
                identifier: "ideas.composer.input",
                in: mainWindow
            ) as? NSTextView else { return false }
            return store.ideaText == Self.restartDraft
                && editor.string == Self.restartDraft
        }

        for body in [
            Self.alphaEditedBody,
            Self.deltaBody,
            Self.cancellationProofBody,
        ] {
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
            $0.body == Self.alphaEditedBody
        }) else {
            throw Failure.failed("classified idea was missing after restart")
        }
        try assertAlphaClassification(
            alpha,
            expectedBody: Self.alphaEditedBody,
            store: store
        )
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
        }
        guard store.detailRailRoute == .flylight,
              store.hasDetailRailContent
        else {
            throw Failure.failed(
                "Flylight did not register its shared detail rail route"
            )
        }
    }

    private func assertCollapsedComposerGeometry(
        mainWindow: NSWindow,
        store: NoonmarkStore
    ) throws {
        guard let editor = AppViewTreeE2E.view(
            identifier: "ideas.composer.input",
            in: mainWindow
        ) as? NSTextView,
            let scrollView = editor.enclosingScrollView,
            let placeholder = AppViewTreeE2E.view(
                identifier: "ideas.composer.placeholder",
                in: mainWindow
            ),
            let surface = AppViewTreeE2E.view(
                identifier: "ideas.composer.surface",
                in: mainWindow
            ),
            let secondary = AppViewTreeE2E.view(
                identifier: "ideas.composer.secondary",
                in: mainWindow
            )
        else {
            throw Failure.failed("collapsed Flylight composer targets were missing")
        }
        mainWindow.contentView?.layoutSubtreeIfNeeded()
        let editorFrame = AppViewTreeE2E.frameInWindow(for: scrollView)
        let placeholderFrame = AppViewTreeE2E.frameInWindow(for: placeholder)
        let surfaceFrame = AppViewTreeE2E.frameInWindow(for: surface)
        guard mainWindow.firstResponder !== editor,
              (20 ... 26).contains(editorFrame.height),
              editorFrame.contains(placeholderFrame),
              (62 ... 72).contains(surfaceFrame.height),
              editor.accessibilityLabel()
              == store.copy.ideaBodyAccessibilityLabel,
              editor.accessibilityValue() == "",
              AppViewTreeE2E.verificationText(for: secondary)
              == store.copy.ideaExpandComposerAction
        else {
            let secondaryText = AppViewTreeE2E.verificationText(
                for: secondary
            ) ?? "nil"
            throw Failure.failed(
                "idle Flylight composer was not a compact, actionable surface: editor=\(editorFrame), placeholder=\(placeholderFrame), surface=\(surfaceFrame), secondary=\(secondaryText)"
            )
        }
    }

    private func exerciseDirtyComposerCollapse(
        store: NoonmarkStore,
        mainWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws {
        guard let editor = AppViewTreeE2E.view(
            identifier: "ideas.composer.input",
            in: mainWindow
        ) as? NSTextView else {
            throw Failure.failed("Flylight collapse proof lost its editor")
        }
        try await click("ideas.composer.input", in: mainWindow, input: input)
        try input.typeUnicode(Self.collapsedDraft)
        try await waitUntil("Flylight collapse fixture did not become dirty") {
            editor.string == Self.collapsedDraft
                && store.ideaText == Self.collapsedDraft
                && AppViewTreeE2E.view(
                    identifier: "ideas.composer.suggestions",
                    in: mainWindow
                ) != nil
        }
        try await click(
            "ideas.composer.secondary",
            in: mainWindow,
            input: input
        )
        try await waitUntil("dirty Flylight draft did not visibly collapse") {
            mainWindow.contentView?.layoutSubtreeIfNeeded()
            guard let surface = AppViewTreeE2E.view(
                identifier: "ideas.composer.surface",
                in: mainWindow
            ), let secondary = AppViewTreeE2E.view(
                identifier: "ideas.composer.secondary",
                in: mainWindow
            ) else { return false }
            return mainWindow.firstResponder !== editor
                && (62 ... 72).contains(
                    AppViewTreeE2E.frameInWindow(for: surface).height
                )
                && editor.string == Self.collapsedDraft
                && store.ideaText == Self.collapsedDraft
                && editor.accessibilityLabel()
                == store.copy.ideaBodyAccessibilityLabel
                && editor.accessibilityValue() == Self.collapsedDraft
                && AppViewTreeE2E.view(
                    identifier: "ideas.composer.suggestions",
                    in: mainWindow
                ) == nil
                && AppViewTreeE2E.verificationText(for: secondary)
                == store.copy.ideaExpandComposerAction
        }
        try await captureScreenshot(
            "ideas-composer-dirty-collapsed.png",
            of: mainWindow
        )
        try await click(
            "ideas.composer.secondary",
            in: mainWindow,
            input: input
        )
        try await waitUntil("collapsed Flylight draft did not reopen") {
            mainWindow.firstResponder === editor
                && editor.string == Self.collapsedDraft
                && AppViewTreeE2E.view(
                    identifier: "ideas.composer.suggestions",
                    in: mainWindow
                ) != nil
        }
        try input.postKey(keyCode: 0, modifiers: [.command])
        try input.postKey(keyCode: 51)
        try await waitUntil("Flylight collapse fixture did not clear") {
            editor.string.isEmpty && store.ideaText.isEmpty
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
        guard AppViewTreeE2E.view(
            identifier: "ideas.composer.primary",
            in: mainWindow
        ) != nil,
            AppViewTreeE2E.view(
                identifier: "ideas.composer.secondary",
                in: mainWindow
            ) != nil,
            AppViewTreeE2E.view(
                identifier: "ideas.composer.tool.label",
                in: mainWindow
            ) != nil,
            AppViewTreeE2E.view(
                identifier: "ideas.composer.tool.category",
                in: mainWindow
            ) != nil,
            AppViewTreeE2E.view(
                identifier: "ideas.composer.tool.format",
                in: mainWindow
            ) != nil
        else {
            throw Failure.failed(
                "Flylight composer did not expose its integrated actions and tools"
            )
        }
        try await click(
            "ideas.composer.secondary",
            in: mainWindow,
            input: input
        )
        try await waitUntil("empty composer did not take focus") {
            mainWindow.firstResponder === editor
        }
        try await waitUntil("empty composer did not expand after focus") {
            mainWindow.contentView?.layoutSubtreeIfNeeded()
            guard let currentSurface = AppViewTreeE2E.view(
                identifier: "ideas.composer.surface",
                in: mainWindow
            ),
                let currentEditor = AppViewTreeE2E.view(
                    identifier: "ideas.composer.input",
                    in: mainWindow
                ) as? NSTextView,
                let currentScrollView = currentEditor.enclosingScrollView
            else { return false }
            return AppViewTreeE2E.frameInWindow(for: currentSurface).height >= 111
                && AppViewTreeE2E.frameInWindow(for: currentScrollView).height >= 68
        }
        let focusedCaretFrame = editor.firstRect(
            forCharacterRange: NSRange(location: 0, length: 0),
            actualRange: nil
        )
        try await click("ideas.composer.input", in: mainWindow, input: input)
        mainWindow.contentView?.layoutSubtreeIfNeeded()

        guard let scrollView = editor.enclosingScrollView else {
            throw Failure.failed("Flylight composer lost its visible editor surface")
        }
        let editorFrame = AppViewTreeE2E.frameInWindow(for: scrollView)
        let surfaceFrame = AppViewTreeE2E.frameInWindow(for: surface)
        let placeholderFrame = mainWindow.convertToScreen(
            AppViewTreeE2E.frameInWindow(for: placeholder)
        )
        let caretFrame = editor.firstRect(
            forCharacterRange: NSRange(location: 0, length: 0),
            actualRange: nil
        )
        let focusedOffset = abs(
            focusedCaretFrame.maxY - placeholderFrame.maxY
        )
        let verticalOffset = abs(caretFrame.maxY - placeholderFrame.maxY)
        let extraLineFrame = editor.layoutManager?.extraLineFragmentRect ?? .zero
        let extraLineInEditor = extraLineFrame.offsetBy(
            dx: editor.textContainerOrigin.x,
            dy: editor.textContainerOrigin.y
        )
        let extraLineInScreen = mainWindow.convertToScreen(
            editor.convert(extraLineInEditor, to: nil)
        )
        try await captureScreenshot("ideas-empty-focused.png", of: mainWindow)
        let actionChromeHeight = surfaceFrame.height - editorFrame.height
        guard (68 ... 180).contains(editorFrame.height),
              (111 ... 222).contains(surfaceFrame.height),
              (41 ... 52).contains(actionChromeHeight),
              abs(editorFrame.maxY - surfaceFrame.maxY) <= 1,
              focusedOffset <= 2,
              verticalOffset <= 2
        else {
            let clipView = scrollView.contentView
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
                "Flylight composer geometry broke its integrated surface: editor=\(editorFrame), surface=\(surfaceFrame), actionChrome=\(actionChromeHeight), focusedOffset=\(focusedOffset), caretOffset=\(verticalOffset), editorBounds=\(editor.bounds), visible=\(editor.visibleRect), flipped=\(editor.isFlipped), editorTop=\(editorTop), editorBottom=\(editorBottom), inset=\(editor.textContainerInset), containerOrigin=\(editor.textContainerOrigin), extraLine=\(String(describing: extraLine)), extraLineScreen=\(extraLineInScreen), placeholder=\(placeholderFrame), focusedCaret=\(focusedCaretFrame), caret=\(caretFrame), scrollFrame=\(scrollView.frame), scrollBounds=\(scrollView.bounds), clipFrame=\(clipView.frame), clipBounds=\(clipView.bounds), clipFlipped=\(clipView.isFlipped)"
            )
        }
    }

    private func exerciseFlylightDetailRail(
        expectedIdeaIDs: [IdeaID],
        store: NoonmarkStore,
        mainWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws {
        let originalFrame = mainWindow.frame
        if store.isDetailRailExpanded {
            try await click(
                "shell.detail-rail.toggle",
                in: mainWindow,
                input: input
            )
        }
        try await waitUntil("Flylight detail rail did not collapse") {
            mainWindow.contentView?.layoutSubtreeIfNeeded()
            let cards = expectedIdeaIDs.compactMap { id in
                AppViewTreeE2E.view(
                    identifier: "ideas.card.\(id)",
                    in: mainWindow
                )
            }
            return store.detailRailRoute == .flylight
                && store.isDetailRailExpanded == false
                && AppViewTreeE2E.hasNoVisibleView(
                    identifier: "shell.detail-rail"
                )
                && AppViewTreeE2E.view(
                    identifier: "shell.detail-rail.toggle",
                    in: mainWindow
                ) != nil
                && cards.count == expectedIdeaIDs.count
                && AppViewTreeE2E.view(
                    identifier: "ideas.composer.input",
                    in: mainWindow
                ) != nil
        }
        try await captureScreenshot("ideas-detail-collapsed.png", of: mainWindow)

        mainWindow.setContentSize(NSSize(width: 960, height: 720))

        try await click(
            "shell.detail-rail.toggle",
            in: mainWindow,
            input: input
        )
        try await waitUntil("Flylight detail rail did not expand") {
            mainWindow.contentView?.layoutSubtreeIfNeeded()
            guard store.isDetailRailExpanded,
                  AppViewTreeE2E.view(
                      identifier: "shell.detail-rail",
                      in: mainWindow
                  ) != nil,
                  let selectedIdea = store.selectedIdea
            else {
                return false
            }
            return AppViewTreeE2E.view(
                identifier: "ideas.inspector.idea.\(selectedIdea.id)",
                in: mainWindow
            ).flatMap(AppViewTreeE2E.verificationText) == selectedIdea.body
        }
        try assertFlylightRailActionsAreReadable(
            store: store,
            mainWindow: mainWindow
        )
        try await captureScreenshot("ideas-detail-expanded.png", of: mainWindow)

        try await click(
            "shell.detail-rail.toggle",
            in: mainWindow,
            input: input
        )
        try await waitUntil("Flylight detail rail did not collapse after expansion") {
            mainWindow.contentView?.layoutSubtreeIfNeeded()
            let cards = expectedIdeaIDs.compactMap { id in
                AppViewTreeE2E.view(
                    identifier: "ideas.card.\(id)",
                    in: mainWindow
                )
            }
            return store.isDetailRailExpanded == false
                && AppViewTreeE2E.hasNoVisibleView(
                    identifier: "shell.detail-rail"
                )
                && AppViewTreeE2E.view(
                    identifier: "shell.detail-rail.toggle",
                    in: mainWindow
                ) != nil
                && cards.count == expectedIdeaIDs.count
        }
        mainWindow.setFrame(originalFrame, display: true)
    }

    private func assertFlylightRailActionsAreReadable(
        store: NoonmarkStore,
        mainWindow: NSWindow
    ) throws {
        guard let idea = store.selectedIdea,
              let rail = AppViewTreeE2E.view(
                  identifier: "shell.detail-rail",
                  in: mainWindow
              ),
              let edit = AppViewTreeE2E.view(
                  identifier: "ideas.inspector.edit.\(idea.id)",
                  in: mainWindow
              ),
              let sticky = AppViewTreeE2E.view(
                  identifier: "ideas.inspector.sticky.\(idea.id)",
                  in: mainWindow
              )
        else {
            throw Failure.failed("Flylight rail action targets were missing")
        }
        mainWindow.contentView?.layoutSubtreeIfNeeded()
        let railFrame = AppViewTreeE2E.frameInWindow(for: rail)
        let editFrame = AppViewTreeE2E.frameInWindow(for: edit)
        let stickyFrame = AppViewTreeE2E.frameInWindow(for: sticky)
        guard editFrame.width >= 84,
              stickyFrame.width >= 120,
              editFrame.intersects(stickyFrame) == false,
              railFrame.contains(editFrame),
              railFrame.contains(stickyFrame)
        else {
            throw Failure.failed(
                "Flylight rail actions clipped at 960x720: rail=\(railFrame), edit=\(editFrame), sticky=\(stickyFrame)"
            )
        }
    }

    private struct ComposerDraft {
        let text: String
        let body: String
        var suggestionsCheckpoint: String?
    }

    private func prepareClassificationFixture(store: NoonmarkStore) throws {
        guard store.classificationCatalog()?.categories.contains(where: {
            $0.name == Self.alphaCategoryName
        }) == false else { return }
        _ = try store.applyClassificationIntent(
            .createCategory(
                name: Self.alphaCategoryName,
                colorHex: "#2A6FDB"
            ),
            interactionID: UUID(
                uuidString: "91000000-0000-0000-0000-000000000001"
            )!
        )
    }

    private func exerciseComposerTools(
        store: NoonmarkStore,
        mainWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws {
        guard let editor = AppViewTreeE2E.view(
            identifier: "ideas.composer.input",
            in: mainWindow
        ) as? NSTextView else {
            throw Failure.failed("Flylight composer tools lost their editor")
        }

        try input.typeUnicode("toolbar")
        try await waitUntil("Flylight formatting fixture did not reach the editor") {
            editor.string == "toolbar" && store.ideaText == "toolbar"
        }
        try input.postKey(keyCode: 0, modifiers: [.command])

        let formatProbe = MenuTrackingProbe()
        defer { formatProbe.stop() }
        try await click(
            "ideas.composer.tool.format",
            in: mainWindow,
            input: input
        )
        try await waitUntil("Flylight format menu did not begin tracking") {
            formatProbe.didBeginTracking
        }
        try input.postKey(keyCode: 125)
        try input.postKey(keyCode: 36)
        try await waitUntil("Flylight format menu did not apply bold Markdown") {
            formatProbe.didEndTracking
                && editor.string == "**toolbar**"
                && store.ideaText == "**toolbar**"
        }

        try input.postKey(keyCode: 0, modifiers: [.command])
        try input.postKey(keyCode: 51)
        try await waitUntil("Flylight formatting fixture did not clear") {
            editor.string.isEmpty && store.ideaText.isEmpty
        }
        try await click(
            "ideas.composer.tool.label",
            in: mainWindow,
            input: input
        )
        try await waitUntil("Flylight label tool did not insert its token") {
            editor.string == "#" && store.ideaText == "#"
        }
        try await click(
            "ideas.composer.tool.category",
            in: mainWindow,
            input: input
        )
        try await waitUntil("Flylight category tool did not preserve the label token") {
            editor.string == "# @" && store.ideaText == "# @"
        }
        try input.postKey(keyCode: 0, modifiers: [.command])
        try input.postKey(keyCode: 51)
        try await waitUntil("Flylight classification tool fixture did not clear") {
            editor.string.isEmpty && store.ideaText.isEmpty
        }
    }

    private func saveComposerIdea(
        _ draft: ComposerDraft,
        store: NoonmarkStore,
        mainWindow: NSWindow,
        input: WindowServerInputDriver,
        provesPersistenceRetry: Bool = false
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
            editor.string == draft.text
                && store.ideaText == draft.text
                && AppViewTreeE2E.view(
                    identifier: "ideas.composer.surface",
                    in: mainWindow
                ).flatMap(AppViewTreeE2E.verificationText) == "dirty"
        }

        if provesPersistenceRetry {
            try await exerciseRecoverablePersistenceFailure(
                draft: draft,
                editor: editor,
                store: store,
                mainWindow: mainWindow,
                input: input
            )
        } else {
            try input.postKey(keyCode: 36, modifiers: [.command])
        }
        try await waitUntil("Flylight composer saving state was not observable") {
            store.ideaComposerSession.submissionState == .saving
                && AppViewTreeE2E.view(
                    identifier: "ideas.composer.surface",
                    in: mainWindow
                ).flatMap(AppViewTreeE2E.verificationText) == "saving"
        }
        if provesPersistenceRetry {
            try await captureScreenshot(
                "ideas-composer-saving.png",
                of: mainWindow
            )
        }
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
                && AppViewTreeE2E.view(
                    identifier: "ideas.composer.surface",
                    in: mainWindow
                ).flatMap(AppViewTreeE2E.verificationText) == "success"
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

    private func exerciseRecoverablePersistenceFailure(
        draft: ComposerDraft,
        editor: NSTextView,
        store: NoonmarkStore,
        mainWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws {
        guard let databaseURL = store.databaseURL else {
            throw Failure.failed(
                "persistence retry requires the real E2E SQLite database"
            )
        }
        let selectedRange = editor.selectedRange()
        let lock = try SQLiteWriteLock(databaseURL: databaseURL)
        try input.postKey(keyCode: 36, modifiers: [.command])
        try await waitUntil(
            "real SQLite contention did not expose a recoverable publish failure"
        ) {
            guard store.ideaComposerSession.submissionState == .failed,
                  store.ideaText == draft.text,
                  editor.string == draft.text,
                  editor.window?.firstResponder === editor,
                  editor.selectedRange() == selectedRange,
                  store.operationFailureNotice == nil,
                  store.engine.ideaTimeline().contains(where: {
                      $0.body == draft.body
                  }) == false,
                  let retry = AppViewTreeE2E.view(
                      identifier: "ideas.composer.primary",
                      in: mainWindow
                  )
            else { return false }
            return AppViewTreeE2E.verificationText(for: retry)
                == store.copy.ideaRetryAction
                && AppViewTreeE2E.buttonInteractionTarget(
                    overlapping: retry
                ) != nil
                && AppViewTreeE2E.view(
                    identifier: "ideas.composer.message",
                    in: mainWindow
                ) != nil
        }
        guard try SQLiteEngineRepository(databaseURL: databaseURL)
            .load()
            .ideas
            .values
            .contains(where: { $0.body == draft.body }) == false
        else {
            throw Failure.failed(
                "failed Flylight publish leaked into the SQLite snapshot"
            )
        }
        try await assertIdeaPersistenceFailureWasRecorded(store: store)
        try assertCompleteSidebar(
            in: mainWindow,
            checkpoint: "ideas-composer-persistence-failed"
        )
        try await captureScreenshot("ideas-composer-failed.png", of: mainWindow)

        try lock.release()
        try await click("ideas.composer.primary", in: mainWindow, input: input)
    }

    private func assertIdeaPersistenceFailureWasRecorded(
        store: NoonmarkStore
    ) async throws {
        guard let recorder = store.localDiagnosticRecorder else {
            throw Failure.failed(
                "Flylight persistence retry lost its diagnostic recorder"
            )
        }
        for _ in 0 ..< 120 {
            let package = try await recorder.snapshotPackage()
            if package.records.contains(where: { record in
                record.event.code == .mutationRejected
                    && record.event.mutationContext == .idea
                    && record.event.mutationRejectionReason
                    == .persistenceFailure
                    && record.event.failure != nil
            }) {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Failure.failed(
            "Flylight persistence failure was not durably recorded"
        )
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
                && store.ideaClassificationBrowseReturnLocation != nil
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
                && store.ideaClassificationBrowseReturnLocation == nil
                && store.ideaSourceBrowseReturnLocation == nil
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
        alphaID: IdeaID,
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
        try input.typeUnicode(Self.betaSwitchedBody)
        let alphaEditor = try await beginInlineEditor(
            ideaID: alphaID,
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        guard alphaEditor.string
            == "\(Self.alphaBody)\n@\"Client Work\" #SwiftUI"
        else {
            throw Failure.failed(
                "inline Flylight did not reversibly quote classification names"
            )
        }
        try await waitUntil("switching inline cards did not save the first draft") {
            store.editingIdeaID == alphaID
                && store.engine.ideas[betaID]?.body == Self.betaSwitchedBody
        }
        guard let alphaBeforeEdit = store.engine.ideas[alphaID],
              let databaseURL = store.databaseURL
        else {
            throw Failure.failed("classified Flylight edit lost its source identity")
        }
        try input.postKey(keyCode: 0, modifiers: [.command])
        try input.typeUnicode(
            "\(Self.alphaEditedBody)\n@\"Client Work\" #SwiftUI"
        )
        try input.postKey(keyCode: 36, modifiers: [.command])
        try await waitUntil("inline Flylight saving state was not observable") {
            store.ideaInlineEditorSession.saveState == .saving
                && store.editingIdeaID == alphaID
                && AppViewTreeE2E.view(
                    identifier: "ideas.card.edit-field.\(alphaID).surface",
                    in: mainWindow
                ).flatMap(AppViewTreeE2E.verificationText) == "saving"
        }
        try await captureScreenshot("ideas-inline-saving.png", of: mainWindow)
        try await waitUntil("classified inline Flylight did not save") {
            guard store.editingIdeaID == nil,
                  let edited = store.engine.ideas[alphaID]
            else { return false }
            return edited.body == Self.alphaEditedBody
                && edited.categoryID == alphaBeforeEdit.categoryID
                && edited.labelIDs == alphaBeforeEdit.labelIDs
        }
        guard let persistedAlpha = try SQLiteEngineRepository(
            databaseURL: databaseURL
        ).load().ideas[alphaID],
            persistedAlpha.body == Self.alphaEditedBody,
            persistedAlpha.categoryID == alphaBeforeEdit.categoryID,
            persistedAlpha.labelIDs == alphaBeforeEdit.labelIDs
        else {
            throw Failure.failed(
                "classified inline Flylight did not preserve identity in SQLite"
            )
        }

        let betaBeforeTools = store.engine.ideas[betaID]
        editor = try await beginInlineEditor(
            ideaID: betaID,
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try input.postKey(keyCode: 0, modifiers: [.command])
        try await click(
            "ideas.card.edit-field.\(betaID).tool.label",
            in: mainWindow,
            input: input
        )
        try await waitUntil("inline Markdown tool ended the edit session") {
            store.editingIdeaID == betaID
                && editor.string.hasPrefix("#")
                && store.ideaEditText == editor.string
        }
        try await click(
            "ideas.card.edit.cancel.\(betaID)",
            in: mainWindow,
            input: input
        )
        try await waitUntil("cancelling an inline tool edit changed persistence") {
            store.editingIdeaID == nil
                && store.engine.ideas[betaID]?.body == betaBeforeTools?.body
                && store.engine.ideas[betaID]?.updatedAt == betaBeforeTools?.updatedAt
        }

        editor = try await beginInlineEditor(
            ideaID: betaID,
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try await captureScreenshot("ideas-inline-edit.png", of: mainWindow)
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
        try input.typeUnicode("   ")
        try await click(
            "sidebar.nav.stickyNotes",
            in: mainWindow,
            input: input
        )
        try await waitUntil("invalid inline draft did not block navigation") {
            store.page == .ideas
                && store.editingIdeaID == betaID
                && store.engine.ideas[betaID]?.body == Self.betaEditedBody
                && mainWindow.firstResponder === editor
        }
        try await click(
            "ideas.search.toggle",
            in: mainWindow,
            input: input
        )
        try await waitUntil("failed preflight still exposed local search UI") {
            store.ideaFilterText.isEmpty
                && AppViewTreeE2E.view(
                    identifier: "ideas.filter",
                    in: mainWindow
                ) == nil
                && store.editingIdeaID == betaID
                && mainWindow.firstResponder === editor
        }

        if store.isDetailRailExpanded == false {
            try await click(
                "shell.detail-rail.toggle",
                in: mainWindow,
                input: input
            )
        }
        try await waitUntil("invalid edit did not remain visible in the detail rail") {
            store.isDetailRailExpanded
                && store.editingIdeaID == betaID
                && AppViewTreeE2E.view(
                    identifier: "ideas.inspector.menu.\(betaID)",
                    in: mainWindow
                ) != nil
        }
        let deleteProbe = MenuTrackingProbe()
        defer { deleteProbe.stop() }
        try await click(
            "ideas.inspector.menu.\(betaID)",
            in: mainWindow,
            input: input
        )
        try await waitUntil("Flylight inspector menu did not begin tracking") {
            deleteProbe.didBeginTracking
        }
        try input.postKey(keyCode: 125)
        try input.postKey(keyCode: 36)
        try await waitUntil("Flylight inspector menu did not end tracking") {
            deleteProbe.didEndTracking
        }
        guard store.engine.ideas[betaID]?.isDeleted == false,
              store.editingIdeaID == betaID,
              store.ideaEditText.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              mainWindow.firstResponder === editor
        else {
            throw Failure.failed(
                "deleting from the inspector discarded an invalid inline draft"
            )
        }
        try await click(
            "shell.detail-rail.toggle",
            in: mainWindow,
            input: input
        )
        try await waitUntil("Flylight detail rail did not close after delete preflight") {
            store.isDetailRailExpanded == false
                && store.editingIdeaID == betaID
                && mainWindow.firstResponder === editor
        }
        try await click(
            "ideas.card.edit.cancel.\(betaID)",
            in: mainWindow,
            input: input
        )

        editor = try await beginInlineEditor(
            ideaID: betaID,
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try input.postKey(keyCode: 0, modifiers: [.command])
        try input.typeUnicode(Self.betaNavigationBody)
        try await click(
            "sidebar.nav.stickyNotes",
            in: mainWindow,
            input: input
        )
        try await waitUntil("valid inline draft was not saved before navigation") {
            store.page == .stickyNotes
                && store.editingIdeaID == nil
                && store.engine.ideas[betaID]?.body == Self.betaNavigationBody
        }
        try await openIdeasPageFromSidebar(
            store: store,
            mainWindow: mainWindow,
            input: input
        )

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
                ).flatMap(AppViewTreeE2E.verificationText) == Self.alphaEditedBody
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

        try await click(
            "ideas.search.toggle",
            in: mainWindow,
            input: input
        )
        try await waitUntil("Flylight source-navigation search did not appear") {
            AppViewTreeE2E.view(
                identifier: "ideas.filter",
                in: mainWindow
            ) != nil
        }
        try await click("ideas.filter", in: mainWindow, input: input)
        try await waitUntil("Flylight source-navigation search did not take focus") {
            mainWindow.firstResponder is NSTextView
        }
        try input.typeUnicode(Self.sourceBrowseFilter)
        try await waitUntil("Flylight source-navigation filter did not settle") {
            store.ideaFilterText == Self.sourceBrowseFilter
                && timelineCount(in: mainWindow) == 1
        }
        let sourceBrowseSelection = store.selectedIdeaID

        try await openStickyNotesPageFromSidebar(
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try await waitUntil("selected Flylight did not appear in Sticky Note") {
            AppViewTreeE2E.view(
                identifier: "sticky-notes.item.\(alphaID)",
                in: mainWindow
            ).flatMap(AppViewTreeE2E.verificationText) == Self.alphaEditedBody
        }
        try await chooseStickyNotePresentation(
            .wall,
            in: mainWindow,
            input: input
        )
        try await captureScreenshot("sticky-notes-wall.png", of: mainWindow)
        try await chooseStickyNotePresentation(
            .stream,
            in: mainWindow,
            input: input
        )
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
                && store.ideaFilterText.isEmpty
                && store.canRestoreIdeaBrowseLocation
                && AppViewTreeE2E.view(
                    identifier: "ideas.browse.restore",
                    in: mainWindow
                ) != nil
                && AppViewTreeE2E.view(
                    identifier: "ideas.card.\(alphaID)",
                    in: mainWindow
                ).flatMap(AppViewTreeE2E.verificationText) == Self.alphaEditedBody
        }
        try await click(
            "ideas.browse.restore",
            in: mainWindow,
            input: input
        )
        try await waitUntil(
            "Sticky Note source navigation did not restore prior browsing"
        ) {
            store.ideaFilterText == Self.sourceBrowseFilter
                && store.selectedIdeaID == sourceBrowseSelection
                && store.canRestoreIdeaBrowseLocation == false
                && AppViewTreeE2E.view(
                    identifier: "ideas.filter",
                    in: mainWindow
                ) != nil
                && AppViewTreeE2E.view(
                    identifier: "ideas.browse.restore",
                    in: mainWindow
                ) == nil
                && timelineCount(in: mainWindow) == 1
        }
        try await captureScreenshot(
            "ideas-source-browse-restored.png",
            of: mainWindow
        )
        try await click(
            "ideas.search.toggle",
            in: mainWindow,
            input: input
        )
        try await waitUntil("restored Flylight source filter did not dismiss") {
            store.ideaFilterText.isEmpty
                && AppViewTreeE2E.view(
                    identifier: "ideas.filter",
                    in: mainWindow
                ) == nil
                && timelineCount(in: mainWindow) == 1
        }

        guard let labelID = store.engine.ideas[alphaID]?.labelIDs.first else {
            throw Failure.failed(
                "Sticky Note source restoration lost its classification fixture"
            )
        }
        try await click(
            "ideas.card.filter.\(alphaID).label.\(labelID)",
            in: mainWindow,
            input: input
        )
        try await waitUntil("Flylight source proof did not enter a classification") {
            store.ideaBrowseMode == .recent
                && store.ideaClassificationFilter == .label(labelID)
                && store.ideaClassificationBrowseReturnLocation != nil
                && timelineCount(in: mainWindow) == 1
        }
        try await openStickyNotesPageFromSidebar(
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try await doubleClick(
            "sticky-notes.item.\(alphaID)",
            in: mainWindow,
            input: input
        )
        try await waitUntil("classified Sticky Note source did not reveal Flylight") {
            store.page == .ideas
                && store.selectedIdeaID == alphaID
                && store.ideaClassificationFilter == nil
                && store.canRestoreIdeaBrowseLocation
        }
        try await click(
            "ideas.browse.restore",
            in: mainWindow,
            input: input
        )
        try await waitUntil(
            "Sticky Note source did not restore its classification collection"
        ) {
            store.ideaBrowseMode == .recent
                && store.ideaClassificationFilter == .label(labelID)
                && store.ideaClassificationBrowseReturnLocation != nil
                && store.canRestoreIdeaBrowseLocation == false
                && timelineCount(in: mainWindow) == 1
        }
        try await captureScreenshot(
            "ideas-source-classification-restored.png",
            of: mainWindow
        )

        try await click(
            "ideas.review.toggle",
            in: mainWindow,
            input: input
        )
        try await waitUntil("explicit review retained stale Flylight return locations") {
            store.ideaBrowseMode == .review
                && store.ideaClassificationFilter == nil
                && store.ideaClassificationBrowseReturnLocation == nil
                && store.ideaSourceBrowseReturnLocation == nil
        }
        let priorReviewSeed = store.ideaReviewSeed
        try await click(
            "ideas.review.refresh",
            in: mainWindow,
            input: input
        )
        try await waitUntil("Flylight review refresh did not advance its seed") {
            store.ideaBrowseMode == .review
                && store.ideaReviewSeed == priorReviewSeed &+ 1
        }
        let restoredReviewSeed = store.ideaReviewSeed
        try await openStickyNotesPageFromSidebar(
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try await doubleClick(
            "sticky-notes.item.\(alphaID)",
            in: mainWindow,
            input: input
        )
        try await waitUntil("review Sticky Note source did not reveal Flylight") {
            store.page == .ideas
                && store.selectedIdeaID == alphaID
                && store.ideaBrowseMode == .recent
                && store.canRestoreIdeaBrowseLocation
        }
        try await click(
            "ideas.browse.restore",
            in: mainWindow,
            input: input
        )
        try await waitUntil(
            "Sticky Note source did not restore review mode and seed"
        ) {
            store.ideaBrowseMode == .review
                && store.ideaReviewSeed == restoredReviewSeed
                && store.ideaFilterText.isEmpty
                && store.ideaClassificationFilter == nil
                && store.canRestoreIdeaBrowseLocation == false
                && AppViewTreeE2E.view(
                    identifier: "ideas.collection",
                    in: mainWindow
                ).flatMap(AppViewTreeE2E.verificationText) == "review"
        }
        try await captureScreenshot(
            "ideas-source-review-restored.png",
            of: mainWindow
        )
        try await click(
            "ideas.review.toggle",
            in: mainWindow,
            input: input
        )
        try await waitUntil("Flylight review did not return to the source timeline") {
            store.ideaBrowseMode == .recent
                && AppViewTreeE2E.view(
                    identifier: "ideas.card.\(alphaID)",
                    in: mainWindow
                ) != nil
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
        try input.typeUnicode(Self.gammaSuggestionDraft)
        try await waitUntil("global Flylight did not expose category suggestions") {
            editor?.string == Self.gammaSuggestionDraft
                && store.ideaText == Self.gammaSuggestionDraft
                && AppViewTreeE2E.view(
                    identifier: "idea-capture.field.suggestions",
                    in: panel
                ) != nil
        }
        try await click(
            "idea-capture.field.suggestions",
            in: panel,
            input: input
        )
        try await waitUntil("global Flylight category suggestion was not selected") {
            editor?.string == Self.gammaCompletedDraft
                && store.ideaText == Self.gammaCompletedDraft
        }
        try await captureScreenshot("idea-capture-panel.png", of: panel)
        try input.postKey(keyCode: 36, modifiers: [.command])
        try await waitUntil("panel Cmd+Return did not persist the idea") {
            panel.isVisible == false
                && store.engine.ideaTimeline().contains { idea in
                    idea.body == Self.gammaBody
                        && store.ideaClassificationLine(for: idea) == "@工程"
                }
                && timelineCount(in: mainWindow) == 2
        }
    }

    private func assertComposerDoesNotOverlapCollection(
        in mainWindow: NSWindow
    ) throws {
        mainWindow.contentView?.layoutSubtreeIfNeeded()
        guard let surface = AppViewTreeE2E.view(
            identifier: "ideas.composer.surface",
            in: mainWindow
        ), let collection = AppViewTreeE2E.view(
            identifier: "ideas.collection",
            in: mainWindow
        ) else {
            throw Failure.failed("Flylight composer overlap proof lost its views")
        }
        let surfaceFrame = AppViewTreeE2E.frameInWindow(for: surface)
        let collectionFrame = AppViewTreeE2E.frameInWindow(for: collection)
        guard (111 ... 222).contains(surfaceFrame.height),
              surfaceFrame.intersects(collectionFrame) == false,
              collectionFrame.maxY <= surfaceFrame.minY
        else {
            throw Failure.failed(
                "Flylight success collapse overlapped the collection context: "
                    + "surface=\(surfaceFrame) collection=\(collectionFrame)"
            )
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
        try await chooseStickyNotePresentation(
            .wall,
            in: mainWindow,
            input: input
        )
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
                && panel.isKeyWindow
                && NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == ProcessInfo.processInfo.processIdentifier
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

    private func exerciseCancellationPersistenceProof(
        idea: IdeaEntry,
        store: NoonmarkStore,
        mainWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws {
        let expectedUpdatedAtBits = Int64(
            bitPattern: idea.updatedAt.timeIntervalSinceReferenceDate.bitPattern
        )
        let editor = try await beginInlineEditor(
            ideaID: idea.id,
            store: store,
            mainWindow: mainWindow,
            input: input
        )
        try input.postKey(keyCode: 0, modifiers: [.command])
        try input.typeUnicode(Self.cancellationAttemptBody)
        try await waitUntil("cancellation proof draft did not reach the editor") {
            editor.string == Self.cancellationAttemptBody
                && store.ideaEditText == Self.cancellationAttemptBody
        }
        try await click(
            "ideas.card.edit.cancel.\(idea.id)",
            in: mainWindow,
            input: input
        )
        try await waitUntil("cancellation proof changed the in-memory idea") {
            store.editingIdeaID == nil
                && store.engine.ideas[idea.id]?.body == Self.cancellationProofBody
                && store.engine.ideas[idea.id]?.updatedAt == idea.updatedAt
        }
        let proof = "\(idea.id.description)\t\(expectedUpdatedAtBits)\n"
        try proof.write(
            to: screenshotDirectory.appendingPathComponent(
                "cancel-sqlite-proof.tsv"
            ),
            atomically: true,
            encoding: .utf8
        )
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

    private func chooseStickyNotePresentation(
        _ mode: StickyNotePresentationMode,
        in mainWindow: NSWindow,
        input: WindowServerInputDriver
    ) async throws {
        let probe = MenuTrackingProbe()
        defer { probe.stop() }
        try await click("sticky-notes.mode", in: mainWindow, input: input)
        try await waitUntil("Sticky Note presentation menu did not begin tracking") {
            probe.didBeginTracking
        }
        let downArrowCount = mode == .stream ? 1 : 2
        for _ in 0 ..< downArrowCount {
            try input.postKey(keyCode: 125)
        }
        try input.postKey(keyCode: 36)
        try await waitUntil("Sticky Note presentation menu did not end tracking") {
            probe.didEndTracking
        }
        try await waitUntil("Sticky Note presentation did not change to \(mode.rawValue)") {
            AppViewTreeE2E.view(
                identifier: "sticky-notes.presentation",
                in: mainWindow
            ).flatMap(AppViewTreeE2E.verificationText) == mode.rawValue
                && AppViewTreeE2E.view(
                    identifier: "sticky-notes.mode",
                    in: mainWindow
                ).flatMap(AppViewTreeE2E.verificationText) == mode.rawValue
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
        expectedBody: String = Self.alphaBody,
        store: NoonmarkStore
    ) throws {
        guard idea.body == expectedBody,
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
        if AppViewTreeE2E.view(identifier: "shell.sidebar", in: window) != nil {
            try assertCompleteSidebar(in: window, checkpoint: name)
        }
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

    private func assertCompleteSidebar(
        in window: NSWindow,
        checkpoint: String
    ) throws {
        window.contentView?.layoutSubtreeIfNeeded()
        guard let sidebar = AppViewTreeE2E.view(
            identifier: "shell.sidebar",
            in: window
        ) else {
            throw Failure.failed("sidebar disappeared at \(checkpoint)")
        }
        let sidebarFrame = AppViewTreeE2E.frameInWindow(for: sidebar)
        guard let contentView = window.contentView else {
            throw Failure.failed("window content disappeared at \(checkpoint)")
        }
        let contentFrame = AppViewTreeE2E.frameInWindow(for: contentView)
        let pageIDs = [
            "day", "pool", "future", "recurring",
            "unfinished", "completed", "calendar", "zhulong",
            "stickyNotes", "ideas"
        ]
        for pageID in pageIDs {
            let identifier = "sidebar.nav.\(pageID)"
            guard let item = AppViewTreeE2E.view(
                identifier: identifier,
                in: window
            ), item.isHiddenOrHasHiddenAncestor == false,
                item.alphaValue > 0
            else {
                throw Failure.failed(
                    "sidebar item \(pageID) disappeared at \(checkpoint)"
                )
            }
            let itemFrame = AppViewTreeE2E.frameInWindow(for: item)
            guard itemFrame.isEmpty == false,
                  sidebarFrame.contains(itemFrame),
                  contentFrame.contains(itemFrame)
            else {
                throw Failure.failed(
                    "sidebar item \(pageID) was clipped at \(checkpoint): "
                        + "content=\(contentFrame),sidebar=\(sidebarFrame),"
                        + "item=\(itemFrame)"
                )
            }
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
        try await waitUntil("idea capture window did not become active") {
            let hasExpectedWindowRole = window is NSPanel || window.isMainWindow
            return NSApp.isActive && hasExpectedWindowRole && window.isKeyWindow
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
            ),
                currentView.window === expectedWindow,
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
                    let targetReport = (try? resolveTarget())?.report
                        ?? "unavailable"
                    let frontmost = NSWorkspace.shared.frontmostApplication
                    let frontmostReport = [
                        "pid=\(frontmost?.processIdentifier.description ?? "nil")",
                        "bundle=\(frontmost?.bundleIdentifier ?? "nil")",
                        "currentPID=\(ProcessInfo.processInfo.processIdentifier)"
                    ].joined(separator: ",")
                    throw Failure.failed(
                        "idea capture WindowServer click failed for \(identifier): "
                            + error.localizedDescription
                            + ",target={\(targetReport)},frontmost={\(frontmostReport)}"
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

    private final class SQLiteWriteLock {
        private var database: OpaquePointer?

        init(databaseURL: URL) throws {
            var candidate: OpaquePointer?
            let openResult = sqlite3_open_v2(
                databaseURL.path,
                &candidate,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            )
            guard openResult == SQLITE_OK, let candidate else {
                let message = candidate.map {
                    String(cString: sqlite3_errmsg($0))
                } ?? "unknown SQLite open error"
                sqlite3_close(candidate)
                throw Failure.failed(
                    "could not open the E2E SQLite lock holder: \(message)"
                )
            }
            database = candidate
            sqlite3_busy_timeout(candidate, 0)
            guard sqlite3_exec(
                candidate,
                "BEGIN IMMEDIATE",
                nil,
                nil,
                nil
            ) == SQLITE_OK else {
                let message = String(cString: sqlite3_errmsg(candidate))
                sqlite3_close(candidate)
                database = nil
                throw Failure.failed(
                    "could not hold the E2E SQLite writer lock: \(message)"
                )
            }
        }

        func release() throws {
            guard let database else { return }
            guard sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
                == SQLITE_OK
            else {
                throw Failure.failed(
                    "could not release the E2E SQLite writer lock: "
                        + String(cString: sqlite3_errmsg(database))
                )
            }
            guard sqlite3_close(database) == SQLITE_OK else {
                throw Failure.failed(
                    "could not close the E2E SQLite writer lock"
                )
            }
            self.database = nil
        }

        deinit {
            guard let database else { return }
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            sqlite3_close(database)
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
