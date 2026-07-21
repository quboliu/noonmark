import NoonmarkMacRuntime
import NoonmarkMacUIContract
import NoonmarkZhulong
import SwiftUI

struct ZhulongSessionStreamPage: View {
    @EnvironmentObject private var store: NoonmarkStore
    @ObservedObject var workspace: ZhulongWorkspaceStore
    @State private var entryText = ""
    @State private var briefGoal = ""
    @State private var briefSuccessCriteria = ""
    @State private var briefHardConstraints = ""
    @State private var dailyReviewSummary = ""
    @State private var dailyReviewTomorrow = ""
    @State private var decisionSupplement = ""
    @State private var todoDiffBeingEdited: ZhulongTodoDiffDraft?
    @State private var isWorkflowActionExpanded = false
    @State private var selectedConversationWorkflow: ZhulongConversationWorkflowSelection?
    @State private var selectedConversationWorkflowRecordID: String?

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
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(
                title: copy.name,
                subtitle: copy.homeSubtitle,
                titlePlacement: .centeredInMainSurface,
                centerSubtitleWithTitle: true,
                titleAnchorIdentifier: "zhulong.session.title"
            ) {
                HStack(spacing: 7) {
                    HeaderButton(copy.allSessionsAction) { workspace.showHome() }
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
                .onChange(of: workspace.selectedSession?.events.count) {
                    guard hasCurrentAction else { return }
                    proxy.scrollTo("zhulong-stream-conversation-current-action", anchor: .bottom)
                }
                .onChange(of: workspace.selectedLiveResponse?.content) {
                    guard workspace.selectedLiveResponse != nil else { return }
                    withAnimation(Theme.shouldReduceMotion ? nil : .easeOut(duration: 0.16)) {
                        proxy.scrollTo("zhulong-live-assistant-message", anchor: .bottom)
                    }
                }
                .onAppear {
                    guard hasCurrentAction else { return }
                    proxy.scrollTo("zhulong-stream-conversation-current-action", anchor: .bottom)
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
        .onAppear {
            if briefGoal.isEmpty {
                briefGoal = workspace.selectedSession?.primaryIntent ?? ""
            }
            if dailyReviewSummary.isEmpty {
                dailyReviewSummary = store.engine.days[store.today]?.reviewSummary ?? ""
            }
            if dailyReviewTomorrow.isEmpty {
                dailyReviewTomorrow = store.engine.days[store.today]?.reviewTomorrowNote ?? ""
            }
            openTodoDiffEditorForE2EIfReady()
        }
        .onChange(of: workspace.selectedSession?.currentTodoDiff?.id.rawValue) {
            openTodoDiffEditorForE2EIfReady()
        }
        .onChange(of: workspace.selectedSessionID) {
            isWorkflowActionExpanded = false
            selectedConversationWorkflow = nil
            selectedConversationWorkflowRecordID = nil
        }
        .sheet(
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
            chapterSectionTitle: { copy.chapterSectionTitle(number: $0, section: $1) },
            planningWorkflowTitle: copy.openPlanningWorkflow,
            dailyReviewWorkflowTitle: copy.openDailyReviewWorkflow,
            onWorkflowSelection: openConversationWorkflow
        ) { record in
            inlineConversationWorkflowAction(for: record)
        }
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
                  let workflow = conversationWorkflowForCurrentAction
        {
            conversationWorkflowAction(workflow, session: session)
        } else if let session = workspace.selectedSession,
                  session.phase == .readyForProvider,
                  session.purpose != .freeform
        {
            if let session = decisionRevisionSession {
                decisionGateRevisionAction(session)
            } else if let context = readyPlanningBriefContext {
                planningBriefAction(context.brief, session: context.session)
            } else if let session = readyDailyReviewSession {
                if needsExplicitWorkflowEntry(for: session) {
                    workflowEntryAction(for: session)
                } else {
                    dailyReviewAction(session)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Notice(
                        text: copy.scopeConfirmed(
                            providerEnabled: store.zhulongProviderDraft.enabled
                        ),
                        tone: .future
                    )
                    if store.zhulongProviderDraft.enabled {
                        SmallActionButton(copy.startGenerating, tone: .accent) {
                            store.runCurrentZhulongProvider()
                        }
                        .accessibilityIdentifier("zhulong-run-provider")
                    } else if workspace.selectedSession?.dailyCloseSnapshots.contains(where: { $0.date == store.today }) == false {
                        SmallActionButton(copy.captureTodayFacts) {
                            store.captureCurrentZhulongDailyClose()
                        }
                        .accessibilityIdentifier("zhulong-capture-daily-close")
                    }
                }
            }
        } else if let session = workspace.selectedSession,
                  session.phase == .draftReview,
                  session.purpose != .freeform
        {
            if needsExplicitWorkflowEntry(for: session) {
                workflowEntryAction(for: session)
            } else if isDailyReviewSession(session) {
                dailyReviewAction(session)
            } else {
                draftReviewAction(session)
            }
        }
    }

    @ViewBuilder
    private func inlineConversationWorkflowAction(for record: ZhulongStreamRecord) -> some View {
        if let selectedConversationWorkflow,
           selectedConversationWorkflowRecordID == record.id,
           let session = workspace.selectedSession,
           canPresentConversationWorkflow(for: session)
        {
            conversationWorkflowAction(selectedConversationWorkflow, session: session)
                .accessibilityIdentifier(
                    "zhulong-inline-workflow-\(selectedConversationWorkflow.accessibilityIdentifier)"
                )
                .background {
                    AppE2EViewAnchor(
                        identifier: "zhulong-inline-workflow-\(selectedConversationWorkflow.accessibilityIdentifier)",
                        verificationText: selectedConversationWorkflow == .planning
                            ? copy.openPlanningWorkflow
                            : copy.openDailyReviewWorkflow
                    )
                }
        }
    }

    @ViewBuilder
    private func conversationWorkflowAction(
        _ workflow: ZhulongConversationWorkflowSelection,
        session: ZhulongSession
    ) -> some View {
        switch workflow {
        case .planning:
            if let artifact = session.effectivePlanArtifact {
                planArtifactAction(artifact, session: session)
            } else if let brief = session.currentPlanningBrief {
                planningBriefAction(brief, session: session)
            } else {
                draftReviewAction(session)
            }
        case .dailyReview:
            if session.dailyCloseSnapshots.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(copy.conversationWorkflowBoundary)
                        .font(.noonmarkSystem(size: 12))
                        .foregroundStyle(Theme.text2)
                    SmallActionButton(copy.captureTodayFacts, tone: .accent) {
                        store.captureCurrentZhulongDailyClose()
                    }
                    .accessibilityIdentifier("zhulong-capture-daily-close")
                }
                .padding(.vertical, 4)
            } else {
                dailyReviewAction(session)
            }
        }
    }

    private func openConversationWorkflow(
        _ workflow: ZhulongConversationWorkflowSelection,
        from record: ZhulongStreamRecord
    ) {
        guard record.actor == .user else { return }
        selectedConversationWorkflow = workflow
        selectedConversationWorkflowRecordID = record.id
        let content = conversationRecordContent(record)
        switch workflow {
        case .planning:
            if briefGoal.isEmpty {
                briefGoal = content
            }
        case .dailyReview:
            if dailyReviewSummary.isEmpty {
                dailyReviewSummary = content
            }
        }
    }

    private func conversationRecordContent(_ record: ZhulongStreamRecord) -> String {
        let content = record.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        return content?.isEmpty == false ? content! : record.title
    }

    private var conversationWorkflowForCurrentAction: ZhulongConversationWorkflowSelection? {
        guard selectedConversationWorkflowRecordID == nil,
              let session = workspace.selectedSession,
              session.purpose == .freeform,
              canPresentConversationWorkflow(for: session)
        else { return nil }
        if let selectedConversationWorkflow {
            return selectedConversationWorkflow
        }
        if session.currentPlanningBrief != nil || session.effectivePlanArtifact != nil {
            return .planning
        }
        if session.dailyCloseSnapshots.isEmpty == false,
           session.dailyReviewReceipts.isEmpty
        {
            return .dailyReview
        }
        return nil
    }

    private func canPresentConversationWorkflow(for session: ZhulongSession) -> Bool {
        session.workspaceStatus == .active &&
            needsScopeAuthorization == false &&
            (session.phase == .readyForProvider || session.phase == .draftReview)
    }

    private func decisionGateAction(_ gate: ZhulongDecisionGate) -> some View {
        VStack(alignment: .leading, spacing: 11) {
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

    private func decisionGateRevisionAction(_ session: ZhulongSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(copy.incorporateDecisionTitle)
                .font(.noonmarkSystem(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.text1)
            Text(copy.decisionRevisionNotice)
                .font(.noonmarkSystem(size: 11))
                .foregroundStyle(Theme.text2)
                .lineSpacing(3)
            SmallActionButton(copy.createRevisedBrief, tone: .accent) {
                workspace.incorporateDecisionGateResolution()
            }
            .accessibilityIdentifier("zhulong-revise-brief-after-decision")
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 8).fill(actionSurfaceFill))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(actionSurfaceStroke))
    }

    private func dailyReviewAction(_ session: ZhulongSession) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(copy.dailyReviewTitle)
                    .font(.noonmarkSystem(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Spacer()
                StatusPill(
                    text: session.dailyReviewReceipts.isEmpty ? copy.awaitingConfirmation : copy.saved,
                    color: session.dailyReviewReceipts.isEmpty ? Theme.warn : Theme.ok
                )
            }
            if let suggestion = latestProviderSuggestion(session) {
                Text(copy.providerSuggestion(suggestion))
                    .font(.noonmarkSystem(size: 11))
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(3)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
            }
            if session.dailyReviewReceipts.isEmpty == false {
                Notice(text: copy.dailyReviewSavedNotice, tone: .future)
            } else if session.dailyReviewDrafts.isEmpty {
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
                SmallActionButton(copy.createReviewDraft, tone: .accent) {
                    store.publishCurrentZhulongDailyReview(
                        summary: optionalText(dailyReviewSummary),
                        tomorrowNote: optionalText(dailyReviewTomorrow)
                    )
                }
                .disabled(optionalText(dailyReviewSummary) == nil && optionalText(dailyReviewTomorrow) == nil)
                .accessibilityIdentifier("zhulong-publish-daily-review")
            } else {
                let draft = session.dailyReviewDrafts.last
                MarkdownText(draft?.summary ?? draft?.tomorrowNote ?? "")
                    .font(.noonmarkSystem(size: 11.5))
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(3)
                SmallActionButton(copy.confirmAndSaveReview, tone: .accent) {
                    store.confirmAndSaveCurrentZhulongDailyReview()
                }
                .accessibilityIdentifier("zhulong-confirm-save-daily-review")
            }
            Text(copy.reviewBoundaryNotice)
                .font(.noonmarkSystem(size: 10.5))
                .foregroundStyle(Theme.text3)
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 8).fill(actionSurfaceFill))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(actionSurfaceStroke))
    }

    private func isDailyReviewSession(_ session: ZhulongSession) -> Bool {
        session.purpose == .dailyClose
    }

    private func needsExplicitWorkflowEntry(for session: ZhulongSession) -> Bool {
        guard session.purpose != .freeform,
              isWorkflowActionExpanded == false
        else { return false }
        if isDailyReviewSession(session) {
            return session.dailyReviewDrafts.isEmpty
        }
        return session.currentPlanningBrief == nil && session.effectivePlanArtifact == nil
    }

    private func workflowEntryAction(for session: ZhulongSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(copy.conversationWorkflowBoundary)
                .font(.noonmarkSystem(size: 12))
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
            SmallActionButton(
                isDailyReviewSession(session)
                    ? copy.openDailyReviewWorkflow
                    : copy.openPlanningWorkflow
            ) {
                isWorkflowActionExpanded = true
            }
        }
        .padding(.vertical, 4)
    }

    private var readyDailyReviewSession: ZhulongSession? {
        guard let session = workspace.selectedSession,
              isDailyReviewSession(session),
              session.dailyCloseSnapshots.isEmpty == false
        else { return nil }
        return session
    }

    private var decisionRevisionSession: ZhulongSession? {
        guard let session = workspace.selectedSession,
              session.currentBriefRequiresDecisionGateRevision
        else { return nil }
        return session
    }

    private var readyPlanningBriefContext: (
        session: ZhulongSession,
        brief: ZhulongPlanningBrief
    )? {
        guard let session = workspace.selectedSession,
              let brief = session.currentPlanningBrief
        else { return nil }
        return (session, brief)
    }

    private func latestProviderSuggestion(_ session: ZhulongSession) -> String? {
        session.providerSends.reversed().compactMap(\.response?.content).first
    }

    private func optionalText(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    @ViewBuilder
    private func draftReviewAction(_ session: ZhulongSession) -> some View {
        if let artifact = session.effectivePlanArtifact {
            planArtifactAction(artifact, session: session)
        } else if let brief = session.currentPlanningBrief {
            planningBriefAction(brief, session: session)
        } else {
            VStack(alignment: .leading, spacing: 11) {
                Text(copy.condenseBriefTitle)
                    .font(.noonmarkSystem(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                MarkdownEditor(text: $briefGoal, placeholder: copy.goalPlaceholder, style: .compact)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                MarkdownEditor(
                    text: $briefSuccessCriteria,
                    placeholder: copy.successCriteriaPlaceholder,
                    style: .body
                )
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                MarkdownEditor(
                    text: $briefHardConstraints,
                    placeholder: copy.hardConstraintsPlaceholder,
                    style: .body
                )
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                SmallActionButton(copy.savePlanningBrief, tone: .accent) {
                    publishPlanningBrief(for: session)
                }
                .disabled(normalizedLines(briefSuccessCriteria).isEmpty)
                .accessibilityIdentifier("zhulong-publish-planning-brief")
            }
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 8).fill(actionSurfaceFill))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(actionSurfaceStroke))
        }
    }

    private func planningBriefAction(
        _ brief: ZhulongPlanningBrief,
        session: ZhulongSession
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(copy.planningBriefTitle(version: brief.version))
                    .font(.noonmarkSystem(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Spacer()
                StatusPill(
                    text: session.reviewedPlanningBrief?.id == brief.id ? copy.reviewed : copy.awaitingReview,
                    color: session.reviewedPlanningBrief?.id == brief.id ? Theme.ok : Theme.warn
                )
            }
            MarkdownText(brief.goal)
                .font(.noonmarkSystem(size: 12))
                .foregroundStyle(Theme.text1)
            VStack(alignment: .leading, spacing: 4) {
                Text(copy.successCriteriaTitle)
                    .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                ForEach(brief.successCriteria, id: \.self) { criterion in
                    MarkdownText("- \(criterion)")
                        .font(.noonmarkSystem(size: 11))
                        .foregroundStyle(Theme.text2)
                }
            }
            if session.reviewedPlanningBrief?.id != brief.id {
                SmallActionButton(copy.confirmBrief, tone: .accent) {
                    workspace.reviewCurrentPlanningBrief()
                }
                .accessibilityIdentifier("zhulong-review-planning-brief")
            } else if session.activePlanningDelegation == nil {
                SmallActionButton(copy.delegatePlanningOnce, tone: .accent) {
                    workspace.delegateCurrentPlanningBrief()
                }
                .accessibilityIdentifier("zhulong-delegate-planning")
            } else if store.zhulongProviderDraft.enabled {
                SmallActionButton(copy.runThisPlanning, tone: .accent) {
                    store.runCurrentZhulongPlanningProvider()
                }
                .accessibilityIdentifier("zhulong-run-planning-provider")
            } else {
                Notice(text: copy.providerRequiredForPlanning, tone: .future)
            }
            Text(copy.planningDelegationBoundary)
                .font(.noonmarkSystem(size: 10.5))
                .foregroundStyle(Theme.text3)
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 8).fill(actionSurfaceFill))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(actionSurfaceStroke))
    }

    private func planArtifactAction(
        _ artifact: ZhulongPlanArtifact,
        session: ZhulongSession
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(copy.planArtifactTitle(version: artifact.version))
                    .font(.noonmarkSystem(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Spacer()
                StatusPill(
                    text: copy.todoDiffReviewStatus(hasDiff: session.currentTodoDiff != nil),
                    color: Theme.warn
                )
            }
            MarkdownText(artifact.proposal.summary)
                .font(.noonmarkSystem(size: 11.5))
                .foregroundStyle(Theme.text2)
                .lineSpacing(3)
            ForEach(artifact.proposal.stages, id: \.id) { stage in
                VStack(alignment: .leading, spacing: 3) {
                    Text(stage.title)
                        .font(.noonmarkSystem(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                    Text(stage.objective)
                        .font(.noonmarkSystem(size: 10.5))
                        .foregroundStyle(Theme.text3)
                    if stage.deliverables.isEmpty == false {
                        Text(copy.deliverables(stage.deliverables))
                            .font(.noonmarkSystem(size: 10.5))
                            .foregroundStyle(Theme.text2)
                    }
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel2))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
            }
            if let diff = session.currentTodoDiff {
                VStack(alignment: .leading, spacing: 6) {
                    Text(copy.todoDiffTitle(version: diff.version, count: diff.items.count))
                        .font(.noonmarkSystem(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                    ForEach(diff.items, id: \.id) { item in
                        Label(todoOperationLabel(item.operation), systemImage: "plus.circle")
                            .font(.noonmarkSystem(size: 10.8))
                            .foregroundStyle(Theme.text2)
                    }
                }
                HStack(spacing: 8) {
                    SmallActionButton(copy.reviewAndRevise) {
                        todoDiffBeingEdited = diff
                    }
                    .disabled(workspace.hasActiveTodoAuthorization)
                    .accessibilityIdentifier("zhulong-edit-todo-diff")
                    SmallActionButton(copy.confirmAndApplyAtomically, tone: .accent) {
                        store.confirmAndApplyCurrentZhulongTodoDiff()
                    }
                    .accessibilityIdentifier("zhulong-confirm-apply-todo-diff")
                    .background {
                        AppE2EViewAnchor(
                            identifier: "zhulong-confirm-apply-todo-diff",
                            verificationText: copy.confirmAndApplyAtomically
                        )
                    }
                }
            } else {
                SmallActionButton(copy.createReviewableTodoDiff, tone: .accent) {
                    store.publishCurrentZhulongTodoDiff()
                }
                .accessibilityIdentifier("zhulong-publish-todo-diff")
            }
            Text(copy.todoAtomicBoundary)
                .font(.noonmarkSystem(size: 10.5))
                .foregroundStyle(Theme.text3)
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 8).fill(actionSurfaceFill))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(actionSurfaceStroke))
    }

    private func todoOperationLabel(_ operation: ZhulongTodoDiffOperation) -> String {
        switch operation {
        case let .createTask(title, _, _, _, targetDate):
            copy.createTaskOperation(
                title: title,
                targetDate: targetDate?.description
            )
        case let .addSubtask(_, title, _):
            copy.addSubtaskOperation(title: title)
        case let .scheduleFromPool(_, targetDate):
            copy.scheduleFromPoolOperation(targetDate: targetDate.description)
        case let .continueTrace(_, targetDate):
            copy.continueTraceOperation(targetDate: targetDate.description)
        case .abandonChain:
            copy.abandonChainOperation
        }
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
            || conversationWorkflowForCurrentAction != nil
            || (session.purpose != .freeform
                && (session.phase == .readyForProvider || session.phase == .draftReview))
    }

    private func sendMessage() {
        let content = entryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.isEmpty == false, canSubmitEntry else { return }
        guard store.sendZhulongConversationMessage(content) else { return }
        isWorkflowActionExpanded = false
        entryText = ""
    }

    private func publishPlanningBrief(for session: ZhulongSession) {
        do {
            let draft = try ZhulongPlanningBriefDraft(
                goal: briefGoal,
                successCriteria: normalizedLines(briefSuccessCriteria),
                hardConstraints: normalizedLines(briefHardConstraints),
                userDecisions: session.entries.filter { $0.kind == .decision }.map(\.content),
                delegatedActivities: [.taskDecomposition, .sequencing, .riskReview, .initialScheduling],
                assumptions: [],
                openQuestions: [],
                dataScopes: session.proposedScopes,
                sourceEntryIDs: Set(session.entries.filter { $0.correctsEntryID == nil }.map(\.id))
            )
            workspace.publishPlanningBrief(draft)
        } catch {
            workspace.reportUIError(.planningBriefSaveFailed)
        }
    }

    private func normalizedLines(_ value: String) -> [String] {
        value.components(separatedBy: .newlines)
            .flatMap { $0.components(separatedBy: "；") }
            .flatMap { $0.components(separatedBy: ";") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    private var needsScopeAuthorization: Bool {
        store.currentZhulongSessionNeedsScopeAuthorization
    }

    private var actionSurfaceFill: Color {
        .clear
    }

    private var actionSurfaceStroke: Color {
        .clear
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

private extension ZhulongConversationWorkflowSelection {
    var accessibilityIdentifier: String {
        switch self {
        case .planning: "planning"
        case .dailyReview: "daily-review"
        }
    }
}
