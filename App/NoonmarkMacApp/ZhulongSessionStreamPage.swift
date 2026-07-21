import NoonmarkMacRuntime
import NoonmarkMacUIContract
import NoonmarkZhulong
import SwiftUI

struct ZhulongSessionStreamPage: View {
    @EnvironmentObject private var store: NoonmarkStore
    @ObservedObject var workspace: ZhulongWorkspaceStore
    @State private var expandedSections: Set<ZhulongStreamSection> = []
    @State private var entryText = ""
    @State private var briefGoal = ""
    @State private var briefSuccessCriteria = ""
    @State private var briefHardConstraints = ""
    @State private var dailyReviewSummary = ""
    @State private var dailyReviewTomorrow = ""
    @State private var decisionSupplement = ""
    @State private var todoDiffBeingEdited: ZhulongTodoDiffDraft?

    private var copy: ZhulongCopy {
        AppPresentation(language: store.engine.preferences.language).zhulong
    }

    private var dateTimeFormatter: AppDateTimeFormatter {
        AppDateTimeFormatter(language: store.engine.preferences.language)
    }

    private var records: [ZhulongStreamRecord] { workspace.records(using: copy) }
    private var currentRecordID: String? { records.last?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(
                title: copy.name,
                subtitle: workspace.selectedSession?.primaryIntent,
                badge: workspace.selectedSessionStatus(using: copy),
                badgeColor: statusColor,
                titlePlacement: .centeredInMainSurface,
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
                    } else {
                        HeaderButton(copy.pauseAction) { workspace.pauseCurrentSession() }
                    }
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        streamContent
                        if workspace.variant != .conversation {
                            currentAction
                        }
                        if workspace.variant != .conversation {
                            entryComposer
                        }
                        if let notice = workspace.status {
                            Notice(text: copy.notice(notice), tone: .locked)
                        }
                    }
                    .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
                    .padding(.top, 18)
                    .padding(
                        .bottom,
                        workspace.variant == .conversation ? 112 : 40
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .accessibilityIdentifier("zhulong-session-stream")
                .background {
                    AppE2EViewAnchor(
                        identifier: "zhulong-session-stream",
                        verificationText: copy.sessionStreamVerificationTitle
                    )
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
                    guard workspace.variant == .conversation, hasCurrentAction else { return }
                    proxy.scrollTo("zhulong-stream-conversation-current-action", anchor: .bottom)
                }
                .onAppear {
                    guard workspace.variant == .conversation, hasCurrentAction else { return }
                    proxy.scrollTo("zhulong-stream-conversation-current-action", anchor: .bottom)
                }
            }
            if workspace.variant == .conversation {
                entryComposer
                    .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
                    .padding(.vertical, 10)
                    .background(Theme.background)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Theme.line.opacity(0.7)).frame(height: 1)
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
            if expandedSections.isEmpty, let section = records.last?.section {
                expandedSections.insert(section)
            }
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

    @ViewBuilder
    private var streamContent: some View {
        switch workspace.variant {
        case .conversation:
            conversationView
        case .dossier:
            dossierView
        case .chapters:
            chapterView
        case .weave:
            weaveView
        }
    }

    private var conversationView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(records) { record in
                conversationRow(record)
                    .id(record.id)
            }
            if hasCurrentAction {
                currentAction
                    .padding(.top, 12)
                    .accessibilityIdentifier("zhulong-stream-conversation-current-action")
                    .id("zhulong-stream-conversation-current-action")
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("zhulong-stream-conversation")
    }

    @ViewBuilder
    private func conversationRow(_ record: ZhulongStreamRecord) -> some View {
        switch record.actor {
        case .user:
            HStack {
                Spacer(minLength: 84)
                VStack(alignment: .leading, spacing: 5) {
                    Text(record.title)
                        .font(.noonmarkSystem(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text1)
                    if let body = record.body {
                        Text(body)
                            .font(.noonmarkSystem(size: 12))
                            .foregroundStyle(Theme.text2)
                            .lineSpacing(3)
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.controlFill))
            }
            .padding(.vertical, 8)
        case .zhulong:
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.navZhulong)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(record.title)
                            .font(.noonmarkSystem(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.text1)
                        Spacer()
                        Text(shortTime(record.occurredAt))
                            .font(.noonmarkSystem(size: 9.5).monospacedDigit())
                            .foregroundStyle(Theme.text3)
                    }
                    if let body = record.body {
                        Text(body)
                            .font(.noonmarkSystem(size: 12))
                            .foregroundStyle(Theme.text2)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.vertical, 11)
            .opacity(record.isInvalidation ? 0.62 : 1)
        case .system:
            HStack(spacing: 8) {
                Image(systemName: record.isInvalidation ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundStyle(record.isInvalidation ? Theme.warn : Theme.text3)
                Text(record.title)
                    .font(.noonmarkSystem(size: 11.5, weight: .medium))
                    .foregroundStyle(record.isInvalidation ? Theme.warn : Theme.text2)
                if let body = record.body {
                    Text(body)
                        .font(.noonmarkSystem(size: 11))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(2)
                }
                Spacer()
                Text(shortTime(record.occurredAt))
                    .font(.noonmarkSystem(size: 9.5).monospacedDigit())
                    .foregroundStyle(Theme.text3)
            }
            .padding(.vertical, 8)
        }
    }

    private var dossierView: some View {
        VStack(spacing: 0) {
            ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                HStack(alignment: .top, spacing: 10) {
                    dossierSpine(record: record, isLast: index == records.count - 1)
                    legacyStreamCard(record, isCurrent: record.id == currentRecordID)
                    Text(shortTime(record.occurredAt))
                        .font(.noonmarkSystem(size: 9.5).monospacedDigit())
                        .foregroundStyle(Theme.text3)
                        .frame(width: 42, alignment: .trailing)
                        .padding(.top, 11)
                }
                .id(record.id)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
        .accessibilityIdentifier("zhulong-stream-dossier")
    }

    private var chapterView: some View {
        VStack(spacing: 0) {
            ForEach(activeSections) { section in
                let sectionRecords = records.filter { $0.section == section }
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedSections.contains(section) },
                        set: { expanded in
                            if expanded {
                                expandedSections.insert(section)
                            } else {
                                expandedSections.remove(section)
                            }
                        }
                    )
                ) {
                    VStack(spacing: 8) {
                        ForEach(sectionRecords) { record in
                            legacyStreamCard(record, isCurrent: record.id == currentRecordID)
                                .id(record.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                } label: {
                    chapterHeader(section, records: sectionRecords)
                }
                .tint(Theme.text3)
                if section != activeSections.last {
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
        .accessibilityIdentifier("zhulong-stream-chapters")
    }

    private var weaveView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(store.engine.preferences.language == .chinese ? "烛龙 · 分析、选项与执行" : "Zhulong · Analysis, options and execution")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(store.engine.preferences.language == .chinese ? "你 · 决定与授权" : "You · Decisions and authority")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.noonmarkSystem(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.text3)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.panel2)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            VStack(spacing: 9) {
                ForEach(records) { record in
                    weaveRow(record)
                        .id(record.id)
                }
            }
            .padding(12)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
        .accessibilityIdentifier("zhulong-stream-weave")
    }

    @ViewBuilder
    private var currentAction: some View {
        if let session = workspace.selectedSession, isScopeReviewActive {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text(copy.confirmScopeTitle)
                        .font(.noonmarkSystem(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                    Spacer()
                    StatusPill(text: copy.waitingForYou, color: Theme.accent)
                }
                Text(copy.scopeDisclosure)
                    .font(.noonmarkSystem(size: 11.5))
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(3)
                HStack(spacing: 6) {
                    ForEach(session.proposedScopes.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { scope in
                        Text(scopeLabel(scope))
                            .font(.noonmarkSystem(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.text2)
                            .padding(.horizontal, 8)
                            .frame(height: 23)
                            .background(Capsule().fill(Theme.chip))
                            .overlay(Capsule().stroke(Theme.line))
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
            }
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 8).fill(actionEmphasisFill))
            .overlay(alignment: .leading) {
                Rectangle().fill(actionEmphasisStroke).frame(width: 3)
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(actionEmphasisStroke.opacity(0.25)))
        } else if workspace.selectedSession?.phase == .readyForProvider {
            if let session = decisionRevisionSession {
                decisionGateRevisionAction(session)
            } else if let context = readyPlanningBriefContext {
                planningBriefAction(context.brief, session: context.session)
            } else if let session = readyDailyReviewSession {
                dailyReviewAction(session)
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
        } else if let session = workspace.selectedSession, session.phase == .draftReview {
            if isDailyReviewSession(session) {
                dailyReviewAction(session)
            } else {
                draftReviewAction(session)
            }
        } else if let gate = workspace.selectedSession?.currentDecisionGate {
            decisionGateAction(gate)
        }
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
        store.zhulongTask(for: session) == .dailyReview
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

    @ViewBuilder
    private var entryComposer: some View {
        if canComposeEntry {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 9) {
                    MarkdownEditor(
                        text: $entryText,
                        placeholder: copy.appendEntryPlaceholder,
                        style: .compact,
                        showsSurface: false,
                        onCommit: appendEntry
                    )
                        .accessibilityIdentifier("zhulong-session-entry")
                    SmallActionButton(copy.appendAction) { appendEntry() }
                        .disabled(entryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if workspace.variant == .conversation {
                    HStack {
                        Spacer()
                        variantMenu(accessibilityIdentifier: "zhulong-stream-variant-menu.composer")
                            .font(.noonmarkSystem(size: 10.5, weight: .medium))
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 54)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
        }
    }

    private var canComposeEntry: Bool {
        guard let session = workspace.selectedSession else { return false }
        return session.workspaceStatus == .active &&
            session.phase != .providerRunning &&
            session.phase != .decisionGate
    }

    private var hasCurrentAction: Bool {
        isScopeReviewActive || workspace.selectedSession?.phase == .readyForProvider
            || workspace.selectedSession?.phase == .draftReview
            || workspace.selectedSession?.currentDecisionGate != nil
    }

    private func appendEntry() {
        let content = entryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.isEmpty == false else { return }
        workspace.appendToCurrentSession(
            author: .user,
            kind: workspace.selectedSession?.phase == .draftReview ? .answer : .statement,
            content: content
        )
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

    private var isScopeReviewActive: Bool {
        workspace.selectedSession?.workspaceStatus == .active &&
            workspace.selectedSession?.phase == .scopeReview
    }

    private var statusColor: Color {
        switch workspace.selectedSession?.workspaceStatus {
        case .paused: Theme.warn
        case .archived: Theme.text3
        case .active, nil: Theme.accent
        }
    }

    private var actionSurfaceFill: Color {
        workspace.variant == .conversation ? .clear : Theme.panel
    }

    private var actionSurfaceStroke: Color {
        workspace.variant == .conversation ? .clear : Theme.line
    }

    private var actionEmphasisFill: Color {
        workspace.variant == .conversation ? .clear : Theme.accentSoft.opacity(0.5)
    }

    private var actionEmphasisStroke: Color {
        workspace.variant == .conversation ? .clear : Theme.accent
    }

    private var activeSections: [ZhulongStreamSection] {
        ZhulongStreamSection.allCases.filter { section in
            records.contains { $0.section == section }
        }
    }

    private func dossierSpine(record: ZhulongStreamRecord, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(actorColor(record.actor).opacity(0.14))
                Text(actorMark(record.actor))
                    .font(.noonmarkSystem(size: 8.5, weight: .bold))
                    .foregroundStyle(actorColor(record.actor))
            }
            .frame(width: 20, height: 20)
            if isLast == false {
                Rectangle().fill(Theme.line2.opacity(0.65)).frame(width: 1, height: 42)
            }
        }
        .frame(width: 24)
        .padding(.top, 9)
    }

    private func chapterHeader(
        _ section: ZhulongStreamSection,
        records: [ZhulongStreamRecord]
    ) -> some View {
        HStack(spacing: 11) {
            Text(String(format: "%02d", (activeSections.firstIndex(of: section) ?? 0) + 1))
                .font(.noonmarkSystem(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.text3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(sectionTitle(section))
                    .font(.noonmarkSystem(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Text(records.last?.title ?? "")
                    .font(.noonmarkSystem(size: 10.5))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }
            Spacer()
            Text(store.engine.preferences.language == .chinese ? "\(records.count) 条" : "\(records.count) entries")
                .font(.noonmarkSystem(size: 10.5).monospacedDigit())
                .foregroundStyle(Theme.text3)
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
    }

    @ViewBuilder
    private func weaveRow(_ record: ZhulongStreamRecord) -> some View {
        if record.isBoundary || record.actor == .system {
            legacyStreamCard(record, isCurrent: record.id == currentRecordID)
                .frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .top, spacing: 8) {
                if record.actor == .zhulong {
                    legacyStreamCard(record, isCurrent: record.id == currentRecordID)
                    causalNode(record)
                    Color.clear.frame(maxWidth: .infinity)
                } else {
                    Color.clear.frame(maxWidth: .infinity)
                    causalNode(record)
                    legacyStreamCard(record, isCurrent: record.id == currentRecordID)
                }
            }
        }
    }

    private func causalNode(_ record: ZhulongStreamRecord) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.line2).frame(width: 1, height: 8)
            Circle().fill(actorColor(record.actor)).frame(width: 7, height: 7)
            Rectangle().fill(Theme.line2).frame(width: 1, height: 34)
        }
        .frame(width: 20)
    }

    private func legacyStreamCard(_ record: ZhulongStreamRecord, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(record.eyebrow)
                    .font(.noonmarkSystem(size: 9.5, weight: .semibold))
                    .foregroundStyle(record.isInvalidation ? Theme.warn : actorColor(record.actor))
                    .tracking(0.35)
                Spacer()
                Text(shortTime(record.occurredAt))
                    .font(.noonmarkSystem(size: 9.5).monospacedDigit())
                    .foregroundStyle(Theme.text3)
            }
            Text(record.title)
                .font(.noonmarkSystem(size: 12.5, weight: .semibold))
                .foregroundStyle(record.isInvalidation ? Theme.text2 : Theme.text1)
            if let body = record.body {
                Text(body)
                    .font(.noonmarkSystem(size: 11.5))
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(
                isCurrent
                    ? Theme.accentSoft.opacity(0.62)
                    : record.actor == .zhulong ? Theme.navZhulong.opacity(0.035) : Theme.panel2
            )
        )
        .overlay(alignment: .leading) {
            if isCurrent {
                Rectangle().fill(Theme.accent).frame(width: 3)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isCurrent ? Theme.accent.opacity(0.24) : Theme.line)
        )
        .opacity(record.isInvalidation ? 0.62 : 1)
    }

    private func streamRow(_ record: ZhulongStreamRecord) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(record.eyebrow)
                .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                .foregroundStyle(record.isInvalidation ? Theme.warn : actorColor(record.actor))
                .frame(width: 60, alignment: .trailing)
                .padding(.top, 1)
            streamCard(record)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 12)
        .background(record.id == currentRecordID ? Theme.accentSoft.opacity(0.34) : Color.clear)
    }

    private func streamCard(_ record: ZhulongStreamRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(record.title)
                    .font(.noonmarkSystem(size: 12.5, weight: .semibold))
                    .foregroundStyle(record.isInvalidation ? Theme.text2 : Theme.text1)
                Spacer()
                Text(shortTime(record.occurredAt))
                    .font(.noonmarkSystem(size: 9.5).monospacedDigit())
                    .foregroundStyle(Theme.text3)
            }
            if let body = record.body {
                Text(body)
                    .font(.noonmarkSystem(size: 11.5))
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(record.isInvalidation ? 0.62 : 1)
    }

    private func actorColor(_ actor: ZhulongStreamActor) -> Color {
        switch actor {
        case .user: Theme.accent
        case .zhulong: Theme.navZhulong
        case .system: Theme.text3
        }
    }

    private func actorMark(_ actor: ZhulongStreamActor) -> String {
        switch (actor, store.engine.preferences.language) {
        case (.user, .chinese): "你"
        case (.user, .english): "You"
        case (.zhulong, .chinese): "烛"
        case (.zhulong, .english): "Z"
        case (.system, .chinese): "系"
        case (.system, .english): "S"
        }
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

    private func shortTime(_ date: Date) -> String {
        dateTimeFormatter.string(from: date, style: .shortTime)
    }

    private func scopeLabel(_ scope: ZhulongDataScope) -> String {
        copy.scopeTitle(scope.presentationCopyKey)
    }
}
