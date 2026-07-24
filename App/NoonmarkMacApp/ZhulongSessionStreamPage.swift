import Foundation
import NoonmarkMacRuntime
import NoonmarkMacUIContract
import NoonmarkZhulong
import SwiftUI

private enum ZhulongArtifactDraftPersistence<ID> {
    case absent
    case current(ID)
    case failed

    var succeeded: Bool {
        switch self {
        case .absent, .current:
            true
        case .failed:
            false
        }
    }
}

private extension ZhulongTodoDiffSource {
    var isProviderRevision: Bool {
        if case .providerRevision = self {
            return true
        }
        return false
    }
}

struct ZhulongSessionStreamPage: View {
    @EnvironmentObject private var store: NoonmarkStore
    @ObservedObject var workspace: ZhulongWorkspaceStore
    @State private var entryText = ""
    @State private var dailyReviewSummary = ""
    @State private var dailyReviewTomorrow = ""
    @State private var dailyReviewDraftID:
        ZhulongDailyReviewDraftID?
    @State private var decisionSupplement = ""
    @State private var todoDiffBeingEdited: ZhulongTodoDiffDraft?
    @State private var inlineTodoDraft:
        ZhulongInlineTaskDraftState?

    private var copy: ZhulongCopy {
        AppPresentation(language: store.engine.preferences.language).zhulong
    }

    private var records: [ZhulongStreamRecord] {
        workspace.records(using: copy).filter { record in
            record.actor != .system || record.isCriticalSystemNotice || record.isInvalidation
        }
    }

    private var currentRecordID: String? { records.last?.id }

    var body: some View {
        sheetPage
    }

    private var pageSurface: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(
                title: copy.name,
                subtitle: copy.homeSubtitle,
                titlePlacement: .centeredInMainSurface,
                centerSubtitleWithTitle: true,
                titleAnchorIdentifier: "zhulong.session.title"
            ) {
                HStack(spacing: 7) {
                    HeaderButton(copy.allSessionsAction) {
                        guard persistCurrentArtifactEdits() else {
                            return
                        }
                        workspace.showHome()
                    }
                        .accessibilityIdentifier("zhulong-session-show-home")
                        .background {
                            AppE2EViewAnchor(
                                identifier: "zhulong-session-show-home",
                                verificationText: copy.allSessionsAction
                            )
                        }
                    variantMenu(accessibilityIdentifier: "zhulong-stream-variant-menu")
                    if workspace.selectedSession?.workspaceStatus == .paused {
                        HeaderButton(copy.continueAction) { workspace.resumeCurrentSession() }
                    } else if workspace.selectedSession?.phase == .providerRunning {
                        Text(copy.composerProviderRunningHint)
                            .font(.noonmarkSystem(size: 11, weight: .medium))
                            .foregroundStyle(Theme.text3)
                    } else {
                        HeaderButton(copy.pauseAction) { workspace.pauseCurrentSession() }
                    }
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: NoonmarkVisualMetrics.zhulongConversationMessageSpacing) {
                        streamContent
                        if let liveResponse = workspace.selectedLiveResponse {
                            ZhulongLiveAssistantMessage(
                                content: liveResponse.content,
                                waitingText: copy.composerProviderRunningHint
                            )
                            .id("zhulong-live-assistant-message")
                        }
                        if hasCurrentAction {
                            currentAction
                                .id("zhulong-stream-conversation-current-action")
                        }
                        if let notice = workspace.status {
                            Text(copy.notice(notice))
                                .font(.noonmarkSystem(size: 11.5, weight: .medium))
                                .foregroundStyle(Theme.warn)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(
                        maxWidth: NoonmarkVisualMetrics.zhulongConversationContentMaxWidth,
                        alignment: .leading
                    )
                    .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
                    .padding(.top, 28)
                    .padding(.bottom, 36)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .accessibilityIdentifier("zhulong-session-stream")
                .background {
                    AppE2EViewAnchor(
                        identifier: "zhulong-session-stream",
                        verificationText: copy.sessionStreamVerificationTitle
                    )
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if canComposeEntry {
                        entryComposer
                            .frame(maxWidth: NoonmarkVisualMetrics.zhulongConversationContentMaxWidth)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
                            .padding(.bottom, 16)
                    }
                }
                .onChange(of: records.count) {
                    guard let currentRecordID else { return }
                    withAnimation(Theme.shouldReduceMotion ? nil : .easeInOut(duration: 0.32)) {
                        proxy.scrollTo(currentRecordID, anchor: .center)
                    }
                }
                .onChange(of: workspace.variant) {
                    guard let currentRecordID else { return }
                    proxy.scrollTo(currentRecordID, anchor: .center)
                }
                .onChange(of: workspace.selectedLiveResponse?.content) {
                    guard workspace.selectedLiveResponse != nil else { return }
                    withAnimation(Theme.shouldReduceMotion ? nil : .easeOut(duration: 0.16)) {
                        proxy.scrollTo("zhulong-live-assistant-message", anchor: .bottom)
                    }
                }
                .onChange(
                    of: workspace.selectedSession?
                        .currentTodoDiff?.id.rawValue
                ) {
                    guard let draft = workspace.selectedSession?
                        .currentTodoDiff,
                        draft.version == 1
                            || draft.source.isProviderRevision,
                        let recordID =
                        conversationArtifactRecordID(
                            for: draft
                        )
                    else {
                        return
                    }
                    let anchor: UnitPoint =
                        AppLaunchArguments.contains(
                            "--e2e-zhulong-inline-artifact"
                        )
                            ? .bottom
                            : .top
                    DispatchQueue.main.async {
                        proxy.scrollTo(
                            recordID,
                            anchor: anchor
                        )
                    }
                }
                .onAppear {
                    guard hasCurrentAction else { return }
                    proxy.scrollTo(
                        "zhulong-stream-conversation-current-action",
                        anchor: .top
                    )
                }
            }
        }
        .background(Theme.background)
        .accessibilityIdentifier(
            "zhulong-session-purpose-\(workspace.selectedSession?.purpose.rawValue ?? "unknown")"
        )
        .background {
            AppE2EViewAnchor(
                identifier: "zhulong-session-purpose-\(workspace.selectedSession?.purpose.rawValue ?? "unknown")",
                verificationText: workspace.selectedSession?.primaryIntent ?? copy.sessionFallbackTitle
            )
        }
    }

    private var initializedPage: some View {
        pageSurface
            .onAppear {
                if dailyReviewSummary.isEmpty {
                    dailyReviewSummary = store.engine.days[store.today]?
                        .reviewSummary ?? ""
                }
                if dailyReviewTomorrow.isEmpty {
                    dailyReviewTomorrow = store.engine.days[store.today]?
                        .reviewTomorrowNote ?? ""
                }
                openTodoDiffEditorForE2EIfReady()
                synchronizeInlineTodoDraft()
                synchronizeDailyReviewDraft()
            }
            .onChange(
                of: workspace.selectedSession?
                    .currentTodoDiff?.id.rawValue
            ) {
                openTodoDiffEditorForE2EIfReady()
                synchronizeInlineTodoDraft()
            }
            .onChange(
                of: workspace.selectedSession?
                    .todoDiffDrafts.count
            ) {
                synchronizeInlineTodoDraft()
            }
            .onChange(
                of: workspace.selectedSession?
                    .todoApplyReceipts.count
            ) {
                synchronizeInlineTodoDraft()
            }
    }

    private var synchronizedPage: some View {
        initializedPage
            .onChange(
                of: workspace.selectedSession?
                    .dailyReviewDrafts.last?.id.rawValue
            ) {
                synchronizeDailyReviewDraft()
            }
            .onChange(of: workspace.selectedSessionID) {
                guard persistCurrentArtifactEdits(
                    reportValidationError: false
                ) else {
                    return
                }
                synchronizeInlineTodoDraft()
                synchronizeDailyReviewDraft()
            }
    }

    private var autosavingPage: some View {
        synchronizedPage
            .task(id: inlineTodoDraft?.tasks) {
                guard inlineTodoDraft?.isModified(
                    today: store.today
                ) == true else {
                    return
                }
                do {
                    try await Task.sleep(
                        nanoseconds: 350_000_000
                    )
                } catch {
                    return
                }
                guard Task.isCancelled == false else { return }
                _ = persistInlineTodoDraftIfNeeded(
                    reportValidationError: false
                )
            }
            .onDisappear {
                _ = persistInlineTodoDraftIfNeeded(
                    reportValidationError: false
                )
                _ = persistDailyReviewDraftIfNeeded(
                    reportValidationError: false
                )
            }
    }

    private var artifactAutosavingPage: some View {
        autosavingPage.task(
            id: dailyReviewAutosaveToken
        ) {
            guard dailyReviewDraftID != nil else { return }
            do {
                try await Task.sleep(
                    nanoseconds: 350_000_000
                )
            } catch {
                return
            }
            guard Task.isCancelled == false else { return }
            _ = persistDailyReviewDraftIfNeeded(
                reportValidationError: false
            )
        }
    }

    private var sheetPage: some View {
        artifactAutosavingPage.sheet(
            isPresented: Binding(
                get: { todoDiffBeingEdited != nil },
                set: { if $0 == false { todoDiffBeingEdited = nil } }
            )
        ) {
            if let diff = todoDiffBeingEdited {
                ZhulongTodoDiffEditor(diff: diff) { items in
                    workspace.reviseCurrentTodoDiff(items: items)
                }
            }
        }
    }

    private func variantMenu(accessibilityIdentifier: String) -> some View {
        let language = store.engine.preferences.language
        return Menu {
            ForEach(ZhulongStreamView.allCases) { variant in
                Button {
                    workspace.variant = variant
                } label: {
                    Label(
                        "\(variant.title(language: language)) — \(variant.purpose(language: language))",
                        systemImage: workspace.variant == variant ? "checkmark.circle.fill" : "circle"
                    )
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text("\(language == .chinese ? "视图" : "View") · \(workspace.variant.title(language: language))")
                Image(systemName: "chevron.down")
                    .font(.noonmarkSystem(size: 8, weight: .bold))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var streamContent: some View {
        ZhulongChatTranscript(
            records: records,
            variant: workspace.variant,
            sectionTitle: { sectionTitle($0) },
            dossierSectionTitle: { copy.dossierSectionTitle($0) },
            chapterSectionTitle: {
                copy.chapterSectionTitle(number: $0, section: $1)
            },
            artifactContent: { draftID in
                conversationTodoArtifactContent(draftID)
            }
        )
    }

    @ViewBuilder
    private var currentAction: some View {
        if let session = workspace.selectedSession, needsScopeAuthorization {
            VStack(alignment: .leading, spacing: 8) {
                Text(copy.confirmScopeTitle)
                    .font(.noonmarkSystem(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Text(copy.scopeDisclosure)
                    .font(.noonmarkSystem(size: 12))
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(3)
                HStack(spacing: 6) {
                    ForEach(session.proposedScopes.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { scope in
                        Text(scopeLabel(scope))
                            .font(.noonmarkSystem(size: 11, weight: .medium))
                            .foregroundStyle(Theme.text3)
                            .accessibilityIdentifier("zhulong-session-scope-\(scope.rawValue)")
                            .background {
                                AppE2EViewAnchor(
                                    identifier: "zhulong-session-scope-\(scope.rawValue)",
                                    verificationText: scopeLabel(scope)
                                )
                            }
                    }
                }
                SmallActionButton(copy.useThisSessionOnly, tone: .accent) {
                    store.authorizeCurrentZhulongWorkspaceSession()
                }
                .accessibilityIdentifier("zhulong-authorize-scope")
                .background {
                    AppE2EViewAnchor(
                        identifier: "zhulong-authorize-scope",
                        verificationText: copy.useThisSessionOnly
                    )
                }
            }
            .padding(.vertical, 4)
        } else if let gate = workspace.selectedSession?.currentDecisionGate {
            decisionGateAction(gate)
        } else if let session = workspace.selectedSession,
                  hasPendingDailyReview(in: session)
        {
            dailyReviewAction(session)
        }
    }

    private func decisionGateAction(_ gate: ZhulongDecisionGate) -> some View {
        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(copy.sharedDecisionTitle)
                    .font(.noonmarkSystem(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Spacer()
                StatusPill(text: copy.waitingForYou, color: Theme.warn)
            }
            Text(gate.draft.prompt)
                .font(.noonmarkSystem(size: 12))
                .foregroundStyle(Theme.text1)
            Text(gate.draft.reason)
                .font(.noonmarkSystem(size: 11))
                .foregroundStyle(Theme.text2)
                .lineSpacing(3)
            ForEach(gate.draft.options, id: \.id) { option in
                Button {
                    workspace.resolveCurrentDecisionGate(
                        selectedOptionID: option.id,
                        supplementalDecision: optionalText(decisionSupplement)
                    )
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "circle")
                            .font(.noonmarkSystem(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.title)
                                .font(.noonmarkSystem(size: 11.5, weight: .semibold))
                                .foregroundStyle(Theme.text1)
                            Text(option.impact)
                                .font(.noonmarkSystem(size: 10.5))
                                .foregroundStyle(Theme.text3)
                                .lineSpacing(2)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("zhulong-decision-option-\(option.id)")
            }
            MarkdownEditor(
                text: $decisionSupplement,
                placeholder: copy.decisionSupplementPlaceholder,
                style: .body
            )
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
            Text(copy.decisionChoiceNotice)
                .font(.noonmarkSystem(size: 10.5))
                .foregroundStyle(Theme.text3)
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 8).fill(actionEmphasisFill))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(actionEmphasisStroke.opacity(0.24)))
    }

    private func dailyReviewAction(_ session: ZhulongSession) -> some View {
        let draft = session.dailyReviewDrafts.last
        let isSaved = draft.map { draft in
            session.dailyReviewReceipts.contains {
                $0.draftID == draft.id
            }
        } ?? false
        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(copy.dailyReviewTitle)
                    .font(.noonmarkSystem(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Spacer()
                StatusPill(
                    text:
                    isSaved
                        ? copy.saved
                        : copy.awaitingConfirmation,
                    color: isSaved ? Theme.ok : Theme.accent
                )
            }
            if isSaved {
                Notice(text: copy.dailyReviewSavedNotice, tone: .future)
            } else {
                MarkdownEditor(
                    text: $dailyReviewSummary,
                    placeholder: copy.dailyReviewSummaryPlaceholder,
                    style: .body
                )
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                MarkdownEditor(
                    text: $dailyReviewTomorrow,
                    placeholder: copy.dailyReviewTomorrowPlaceholder,
                    style: .body
                )
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                HStack(spacing: 10) {
                    Text(
                        store.engine.preferences.language == .chinese
                            ? "可以直接编辑，也可以说“提交”保存当前版本。"
                            : "Edit directly, or say “commit” to save this version."
                    )
                    .font(.noonmarkSystem(size: 10.5))
                    .foregroundStyle(Theme.text3)
                    Spacer()
                    SmallActionButton(
                        copy.confirmAndSaveReview,
                        tone: .accent
                    ) {
                        submitDailyReviewDraft()
                    }
                    .accessibilityIdentifier(
                        "zhulong-confirm-save-daily-review"
                    )
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isSaved
                        ? Theme.ok.opacity(0.25)
                        : Theme.accent.opacity(0.22)
                )
        )
        .disabled(isSaved)
        .accessibilityIdentifier(
            "zhulong-inline-daily-review-draft"
        )
    }

    private func optionalText(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func openTodoDiffEditorForE2EIfReady() {
        guard AppLaunchArguments.contains("--e2e-open-zhulong-todo-diff-editor"),
              todoDiffBeingEdited == nil,
              let diff = workspace.selectedSession?.currentTodoDiff
        else { return }
        todoDiffBeingEdited = diff
    }

    private var entryComposer: some View {
        ZhulongChatComposer(
            text: $entryText,
            placeholder: copy.messageComposerPlaceholder,
            keyboardHint: composerHint,
            sendAccessibilityLabel: copy.sendMessageAccessibilityLabel,
            canSubmit: canSubmitEntry,
            onSend: sendMessage
        )
    }

    private var canComposeEntry: Bool {
        workspace.selectedSession != nil
    }

    private var canSubmitEntry: Bool {
        guard let session = workspace.selectedSession else { return false }
        return session.workspaceStatus == .active &&
            needsScopeAuthorization == false &&
            (session.phase == .readyForProvider || session.phase == .draftReview)
    }

    private var composerHint: String {
        guard let session = workspace.selectedSession else {
            return copy.messageComposerKeyboardHint
        }
        if needsScopeAuthorization {
            return copy.composerScopeAuthorizationHint
        }
        if session.workspaceStatus == .paused {
            return copy.composerPausedHint
        }
        switch session.phase {
        case .providerRunning:
            return copy.composerProviderRunningHint
        case .decisionGate:
            return copy.composerDecisionGateHint
        case .scopeReview:
            return copy.composerScopeAuthorizationHint
        case .readyForProvider, .draftReview:
            return copy.messageComposerKeyboardHint
        }
    }

    private var hasCurrentAction: Bool {
        guard let session = workspace.selectedSession else { return false }
        return needsScopeAuthorization
            || session.currentDecisionGate != nil
            || hasPendingDailyReview(in: session)
    }

    private func sendMessage() {
        let content = entryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.isEmpty == false, canSubmitEntry else { return }
        let todoPersistence = persistInlineTodoDraftIfNeeded()
        guard todoPersistence.succeeded else {
            return
        }
        let reviewPersistence = persistDailyReviewDraftIfNeeded()
        guard reviewPersistence.succeeded else { return }
        if ZhulongConversationCommand.isCommit(content),
           case let .current(draftID) = todoPersistence,
           workspace.selectedSession?.currentTodoDiff?.id
           == draftID
        {
            guard store.confirmCurrentZhulongArtifact(
                expectedDraftID: draftID,
                userCommand: content
            ) else {
                return
            }
            entryText = ""
            return
        }
        if ZhulongConversationCommand.isCommit(content),
           case let .current(draftID) = reviewPersistence,
           workspace.selectedSession?.dailyReviewDrafts
           .last?.id == draftID
        {
            guard store.confirmCurrentZhulongDailyReviewArtifact(
                expectedDraftID: draftID,
                userCommand: content
            )
            else {
                return
            }
            entryText = ""
            return
        }
        guard store.sendZhulongConversationMessage(content) else { return }
        entryText = ""
    }

    @ViewBuilder
    private func inlineTodoDraftAction(
        _ draft: ZhulongTodoDiffDraft,
        artifactIdentifier: String
    ) -> some View {
        if let binding = inlineTodoDraftBinding(for: draft) {
            ZhulongInlineTaskDraftCard(
                state: binding,
                language: store.engine.preferences.language,
                artifactIdentifier: artifactIdentifier,
                isApplied: false,
                isUpdating:
                workspace.selectedSession?.phase
                    == .providerRunning,
                onSubmit: submitInlineTodoDraft
            )
        } else {
            Color.clear
                .frame(height: 1)
                .onAppear {
                    inlineTodoDraft = ZhulongInlineTaskDraftState(
                        draft: draft,
                        today: store.today
                    )
                }
        }
    }

    @ViewBuilder
    private func conversationTodoArtifactContent(
        _ draftID: ZhulongTodoDiffID
    ) -> some View {
        if let artifact = workspace.selectedSession?
            .conversationTodoArtifacts.first(where: {
                $0.draft.id == draftID
            })
        {
            let identifier =
                artifact.anchorRunID.rawValue.uuidString
            if artifact.receipt == nil,
               workspace.selectedSession?.currentTodoDiff?.id
               == artifact.draft.id
            {
                inlineTodoDraftAction(
                    artifact.draft,
                    artifactIdentifier: identifier
                )
            } else if let state = ZhulongInlineTaskDraftState(
                draft: artifact.draft,
                today: store.today
            ) {
                ZhulongInlineTaskDraftCard(
                    state: .constant(state),
                    language:
                    store.engine.preferences.language,
                    artifactIdentifier: identifier,
                    isApplied: artifact.receipt != nil,
                    isUpdating: false,
                    onSubmit: {}
                )
            }
        }
    }

    private func conversationArtifactRecordID(
        for draft: ZhulongTodoDiffDraft
    ) -> String? {
        guard let runID = draft.conversationRunID else {
            return nil
        }
        return "conversation-todo-artifact-\(runID.rawValue.uuidString)"
    }

    private func pendingConversationTodoDraft(
        _ session: ZhulongSession
    ) -> ZhulongTodoDiffDraft? {
        guard let draft = session.currentTodoDiff,
              draft.conversationRunID != nil
        else {
            return nil
        }
        return draft
    }

    private func hasPendingDailyReview(
        in session: ZhulongSession
    ) -> Bool {
        guard let draft = session.dailyReviewDrafts.last else {
            return false
        }
        return session.dailyReviewReceipts.contains {
            $0.draftID == draft.id
        } == false
    }

    private func synchronizeInlineTodoDraft() {
        guard let session = workspace.selectedSession,
              let draft = pendingConversationTodoDraft(session)
        else {
            inlineTodoDraft = nil
            return
        }
        guard inlineTodoDraft?.sourceDraftID != draft.id else {
            return
        }
        if let retained = workspace
            .retainedInlineTodoEdit(for: draft.id)
        {
            inlineTodoDraft = retained
            return
        }
        inlineTodoDraft = ZhulongInlineTaskDraftState(
            draft: draft,
            today: store.today
        )
    }

    private func inlineTodoDraftBinding(
        for draft: ZhulongTodoDiffDraft
    ) -> Binding<ZhulongInlineTaskDraftState>? {
        guard inlineTodoDraft?.sourceDraftID == draft.id else {
            return nil
        }
        return Binding(
            get: {
                guard let inlineTodoDraft else {
                    preconditionFailure(
                        "Missing synchronized inline Todo draft"
                    )
                }
                return inlineTodoDraft
            },
            set: { inlineTodoDraft = $0 }
        )
    }

    private func persistInlineTodoDraftIfNeeded(
        reportValidationError: Bool = true
    ) -> ZhulongArtifactDraftPersistence<
        ZhulongTodoDiffID
    > {
        guard let inlineTodoDraft else {
            return .absent
        }
        do {
            guard let draftID = workspace.reviseTodoDiff(
                draftID: inlineTodoDraft.sourceDraftID,
                items: try inlineTodoDraft.makeItems(
                    today: store.today
                )
            ) else {
                workspace.retainInlineTodoEdit(
                    inlineTodoDraft
                )
                return .failed
            }
            workspace.clearRetainedInlineTodoEdit(
                for: inlineTodoDraft.sourceDraftID
            )
            return .current(draftID)
        } catch {
            workspace.retainInlineTodoEdit(
                inlineTodoDraft
            )
            if reportValidationError {
                workspace.reportUIError(
                    store.engine.preferences.language == .chinese
                        ? "请补全任务标题、子任务标题和有效日期。"
                        : "Complete every title and use a valid date."
                )
            }
            return .failed
        }
    }

    private func submitInlineTodoDraft() {
        guard case let .current(draftID) =
            persistInlineTodoDraftIfNeeded()
        else {
            return
        }
        store.confirmCurrentZhulongArtifact(
            expectedDraftID: draftID,
            userCommand:
            store.engine.preferences.language == .chinese
                ? "提交"
                : "Commit"
        )
    }

    private func synchronizeDailyReviewDraft() {
        guard let draft = workspace.selectedSession?
            .dailyReviewDrafts.last
        else {
            dailyReviewDraftID = nil
            return
        }
        guard dailyReviewDraftID != draft.id else {
            return
        }
        dailyReviewDraftID = draft.id
        if let retained = workspace
            .retainedDailyReviewEdit(for: draft.id)
        {
            dailyReviewSummary = retained.summary
            dailyReviewTomorrow = retained.tomorrowNote
            return
        }
        dailyReviewSummary = draft.summary ?? ""
        dailyReviewTomorrow = draft.tomorrowNote ?? ""
    }

    private var dailyReviewAutosaveToken: String {
        [
            dailyReviewDraftID?.rawValue.uuidString ?? "none",
            dailyReviewSummary,
            dailyReviewTomorrow
        ].joined(separator: "\u{0}")
    }

    private func persistDailyReviewDraftIfNeeded(
        reportValidationError: Bool = true
    ) -> ZhulongArtifactDraftPersistence<
        ZhulongDailyReviewDraftID
    > {
        guard let draftID = dailyReviewDraftID
        else {
            return .absent
        }
        let summary = optionalText(dailyReviewSummary)
        let tomorrow = optionalText(dailyReviewTomorrow)
        guard summary != nil || tomorrow != nil else {
            workspace.retainDailyReviewEdit(
                draftID: draftID,
                summary: dailyReviewSummary,
                tomorrowNote: dailyReviewTomorrow
            )
            if reportValidationError {
                workspace.reportUIError(
                    store.engine.preferences.language == .chinese
                        ? "复盘内容不能为空。"
                        : "The review cannot be empty."
                )
            }
            return .failed
        }
        guard let persistedDraftID =
            workspace.reviseDailyReviewDraft(
                draftID: draftID,
                summary: summary,
                tomorrowNote: tomorrow
            )
        else {
            workspace.retainDailyReviewEdit(
                draftID: draftID,
                summary: dailyReviewSummary,
                tomorrowNote: dailyReviewTomorrow
            )
            return .failed
        }
        workspace.clearRetainedDailyReviewEdit(
            for: draftID
        )
        return .current(persistedDraftID)
    }

    private func submitDailyReviewDraft() {
        guard case let .current(draftID) =
            persistDailyReviewDraftIfNeeded()
        else {
            return
        }
        store.confirmCurrentZhulongDailyReviewArtifact(
            expectedDraftID: draftID,
            userCommand:
            store.engine.preferences.language == .chinese
                ? "提交"
                : "Commit"
        )
    }

    private func persistCurrentArtifactEdits(
        reportValidationError: Bool = true
    ) -> Bool {
        let todo = persistInlineTodoDraftIfNeeded(
            reportValidationError: reportValidationError
        )
        let review = persistDailyReviewDraftIfNeeded(
            reportValidationError: reportValidationError
        )
        return todo.succeeded && review.succeeded
    }

    private var needsScopeAuthorization: Bool {
        store.currentZhulongSessionNeedsScopeAuthorization
    }

    private var actionEmphasisFill: Color {
        .clear
    }

    private var actionEmphasisStroke: Color {
        .clear
    }

    private func sectionTitle(_ section: ZhulongStreamSection) -> String {
        switch (section, store.engine.preferences.language) {
        case (.intent, .chinese): "意图与范围"
        case (.intent, .english): "Intent and scope"
        case (.brief, .chinese): "活简报"
        case (.brief, .english): "Living brief"
        case (.planning, .chinese): "规划运行"
        case (.planning, .english): "Planning run"
        case (.decision, .chinese): "决定与授权"
        case (.decision, .english): "Decisions and authority"
        case (.todo, .chinese): "Todo 应用"
        case (.todo, .english): "Todo application"
        case (.dailyClose, .chinese): "每日收尾"
        case (.dailyClose, .english): "Daily close"
        case (.lifecycle, .chinese): "会话状态"
        case (.lifecycle, .english): "Session state"
        }
    }

    private func scopeLabel(_ scope: ZhulongDataScope) -> String {
        copy.scopeTitle(scope.presentationCopyKey)
    }
}
