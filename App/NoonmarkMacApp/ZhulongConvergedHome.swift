import NoonmarkAI
import NoonmarkMacRuntime
import NoonmarkMacUIContract
import NoonmarkZhulong
import SwiftUI

struct ZhulongConvergedHome: View {
    @EnvironmentObject private var store: NoonmarkStore

    var body: some View {
        ZhulongWorkspaceRoot(workspace: store.zhulongWorkspace)
            .onAppear {
                store.zhulongWorkspace.setPresentationLanguage(
                    store.engine.preferences.language
                )
            }
            .onChange(of: store.engine.preferences.language) { _, language in
                store.zhulongWorkspace.setPresentationLanguage(language)
            }
    }
}

private struct ZhulongWorkspaceRoot: View {
    @ObservedObject var workspace: ZhulongWorkspaceStore

    var body: some View {
        if workspace.selectedSession != nil {
            ZhulongSessionStreamPage(workspace: workspace)
        } else {
            ZhulongWorkspaceHome(workspace: workspace)
        }
    }
}

private struct ZhulongWorkspaceHome: View {
    @EnvironmentObject private var store: NoonmarkStore
    @ObservedObject var workspace: ZhulongWorkspaceStore
    @FocusState private var intentIsFocused: Bool
    @State private var intent = ""
    @State private var hoveredWorkflowID: String?

    private var copy: ZhulongCopy {
        AppPresentation(language: store.engine.preferences.language).zhulong
    }

    private var workflows: [ZhulongHomeWorkflow] {
        [
            ZhulongHomeWorkflow(
                id: "task-shaping",
                title: copy.taskShapingTitle,
                detail: copy.taskShapingDetail,
                intent: copy.taskShapingIntent,
                task: .taskDecomposition
            ),
            ZhulongHomeWorkflow(
                id: "daily-close",
                title: copy.dailyCloseTitle,
                detail: copy.dailyCloseDetail,
                intent: copy.dailyCloseIntent,
                task: .dailyReview
            ),
            ZhulongHomeWorkflow(
                id: "scheduling",
                title: copy.schedulingTitle,
                detail: copy.schedulingDetail,
                intent: copy.schedulingIntent,
                task: .scheduling,
                isSuggestion: true
            ),
            ZhulongHomeWorkflow(
                id: "classification",
                title: copy.classificationTitle,
                detail: copy.classificationDetail,
                intent: copy.classificationIntent,
                task: .classification,
                isSuggestion: true
            )
        ]
    }

    private var pendingCount: Int {
        workspace.sessions.filter { $0.workspaceStatus != .archived }.count
    }

    private var contentAlignment: Alignment {
        switch MacUIZhulongHomeLayout.contentPlacement(hasPendingSessions: pendingCount > 0) {
        case .centered:
            .center
        case .topAligned:
            .top
        }
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PageHeader(
                        title: store.copy.navZhulong,
                        subtitle: copy.homeSubtitle,
                        titlePlacement: .centeredInMainSurface,
                        centerSubtitleWithTitle: true,
                        titleAnchorIdentifier: "zhulong.home.title"
                    )
                    .frame(maxWidth: CGFloat(MacUIZhulongHomeLayout.headerOuterMaxWidth))
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 22) {
                        intentComposer
                        workflowSection
                        if pendingCount > 0 {
                            pendingSection
                                .padding(.top, 10)
                        }
                    }
                    .frame(maxWidth: CGFloat(MacUIZhulongHomeLayout.contentMaxWidth), alignment: .leading)
                    .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
                    .padding(.top, 20)
                    .padding(.bottom, 36)
                    .frame(maxWidth: .infinity)
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: viewport.size.height,
                    alignment: contentAlignment
                )
            }
        }
        .background(Theme.background)
        .accessibilityIdentifier("zhulong-converged-home")
        .background {
            AppE2EViewAnchor(
                identifier: "zhulong-converged-home",
                verificationText: store.copy.navZhulong
            )
        }
    }

    private var intentComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                MarkdownEditor(
                    text: $intent,
                    placeholder: copy.intentPlaceholder,
                    style: .compact,
                    showsSurface: false,
                    onCommit: startIntent,
                    nativeAccessibilityIdentifier:
                    "zhulong-home-intent"
                )
                .focused($intentIsFocused)
                .frame(maxHeight: 36)

                Button(action: startIntent) {
                    Image(systemName: "arrow.up")
                        .font(.noonmarkSystem(size: 11, weight: .bold))
                        .foregroundStyle(
                            canSubmitIntent ? Theme.panel : Theme.text3
                        )
                        .frame(width: 32, height: 32)
                        .background(
                            Circle().fill(
                                canSubmitIntent
                                    ? Theme.text1
                                    : Theme.controlFill
                            )
                        )
                        .overlay(
                            Circle().stroke(
                                canSubmitIntent
                                    ? Color.clear
                                    : Theme.line
                            )
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(canSubmitIntent == false)
                .accessibilityLabel(copy.beginIntentAccessibilityLabel)
                .accessibilityIdentifier("zhulong-home-submit")
                .background {
                    AppE2EViewAnchor(
                        identifier: "zhulong-home-submit-target",
                        verificationText:
                        copy.beginIntentAccessibilityLabel
                    )
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .frame(
                height: CGFloat(
                    MacUIZhulongHomeLayout.composerHeight
                )
            )
            .background(
                RoundedRectangle(
                    cornerRadius: CGFloat(
                        MacUIZhulongHomeLayout.composerCornerRadius
                    )
                )
                .fill(Theme.panel)
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: CGFloat(
                        MacUIZhulongHomeLayout.composerCornerRadius
                    )
                )
                .stroke(
                    intentIsFocused
                        ? Theme.accent.opacity(0.5)
                        : Theme.line,
                    lineWidth: intentIsFocused ? 1.2 : 1
                )
            )
            .shadow(
                color: Theme.text1.opacity(0.045),
                radius: 16,
                y: 8
            )

            Text(freeformDataUseDisclosure)
                .font(.noonmarkSystem(size: 10.8))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    AppE2EViewAnchor(
                        identifier: "zhulong-home-data-disclosure",
                        verificationText: freeformDataUseDisclosure
                    )
                }

            if conversationAccessIsDenied {
                Text(copy.homeDataAccessDeniedHint)
                    .font(.noonmarkSystem(size: 10.8))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(
                        "zhulong-home-access-denied"
                    )
            }
        }
    }

    private var workflowSection: some View {
        VStack(spacing: 0) {
            ForEach(Array(workflows.enumerated()), id: \.element.id) { index, workflow in
                workflowButton(workflow)
                if index < workflows.count - 1 {
                    Divider()
                        .padding(.leading, 34)
                        .overlay(Theme.line.opacity(0.82))
                }
            }
        }
        .accessibilityIdentifier("zhulong-home-workflows")
    }

    private func workflowButton(_ workflow: ZhulongHomeWorkflow) -> some View {
        let disclosedDetail = copy.workflowDetailWithScope(
            detail: workflow.detail,
            scopes: scopeList(store.zhulongDataScopes(for: workflow.task))
        )
        return Button {
            startWorkflow(workflow)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(hoveredWorkflowID == workflow.id ? Theme.text2 : Theme.line, lineWidth: 1.2)
                    Image(systemName: "plus")
                        .font(.noonmarkSystem(size: 10, weight: .medium))
                        .foregroundStyle(hoveredWorkflowID == workflow.id ? Theme.text1 : Theme.text3)
                }
                .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(workflow.title)
                            .font(.noonmarkSystem(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.text1)
                        if workflow.isSuggestion {
                            Text(copy.suggestionMode)
                                .font(.noonmarkSystem(size: 9.5, weight: .medium))
                                .foregroundStyle(Theme.text3)
                        }
                    }
                    Text(disclosedDetail)
                        .font(.noonmarkSystem(size: 11.3))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(2)
                }

                Spacer(minLength: 10)
            }
            .padding(.horizontal, 2)
            .frame(height: CGFloat(MacUIZhulongHomeLayout.workflowRowHeight))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9).fill(
                    hoveredWorkflowID == workflow.id
                        ? Theme.panel2
                        : .clear
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(conversationAccessIsDenied)
        .onHover { isHovered in
            hoveredWorkflowID = isHovered ? workflow.id : nil
        }
        .accessibilityLabel(
            copy.workflowAccessibilityLabel(
                title: workflow.title,
                detail: disclosedDetail
            )
        )
        .accessibilityIdentifier("zhulong-home-workflow-\(workflow.id)")
        .background {
            AppE2EViewAnchor(
                identifier: "zhulong-home-workflow-\(workflow.id)",
                verificationText: copy.workflowAccessibilityLabel(
                    title: workflow.title,
                    detail: disclosedDetail
                )
            )
        }
    }

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(copy.pendingDecisionsTitle, count: pendingCount)

            ForEach(workspace.sessions.filter { $0.workspaceStatus != .archived }, id: \.id) { session in
                ZhulongWorkspaceSessionRow(session: session, copy: copy) {
                    workspace.selectSession(session.id)
                }
                Divider().overlay(Theme.line)
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.noonmarkSystem(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text1)
            Spacer()
            Text(copy.itemCount(count))
                .font(.noonmarkSystem(size: 10.5))
                .foregroundStyle(Theme.text3)
                .monospacedDigit()
        }
        .padding(.bottom, 9)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    private var canSubmitIntent: Bool {
        conversationAccessIsDenied == false
            && intent.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty == false
    }

    private var conversationAccessIsDenied: Bool {
        store.zhulongConversationPermissionDecision == .deny
    }

    private var freeformDataUseDisclosure: String {
        copy.homeDataUseDisclosure(
            scopes: scopeList([.currentDayTodo]),
            recipient: currentProviderDisclosure
        )
    }

    private var currentProviderDisclosure: String {
        guard store.zhulongProviderDraft.isConfigured else {
            return copy.providerExecutionUnavailable
        }
        guard let identity = try? store.zhulongProviderIdentity() else {
            return copy.noProviderIdentity
        }
        return ZhulongProviderDisclosureFormatter.disclosure(
            for: identity,
            copy: copy
        )
    }

    private func scopeList(
        _ scopes: Set<ZhulongDataScope>
    ) -> String {
        copy.scopeList(
            scopes
                .sorted(by: { $0.rawValue < $1.rawValue })
                .map { copy.scopeTitle($0.presentationCopyKey) }
        )
    }

    private func startIntent() {
        let value = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false else { return }
        store.startZhulongWorkspaceSession(intent: value)
        intent = ""
        intentIsFocused = false
    }

    private func startWorkflow(_ workflow: ZhulongHomeWorkflow) {
        intentIsFocused = false
        store.startZhulongWorkspaceSession(intent: workflow.intent, task: workflow.task)
    }
}

private struct ZhulongWorkspaceSessionRow: View {
    let session: ZhulongSession
    let copy: ZhulongCopy
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.primaryIntent)
                        .font(.noonmarkSystem(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                        .lineLimit(1)
                    Text(sessionStatus)
                        .font(.noonmarkSystem(size: 10.8))
                        .foregroundStyle(Theme.text2)
                    Text(copy.sessionNextStep)
                        .font(.noonmarkSystem(size: 10.5))
                        .foregroundStyle(Theme.text3)
                }

                Spacer(minLength: 10)
                Text(copy.continueAction)
                    .font(.noonmarkSystem(size: 10.8, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.leading, 38)
            .padding(.trailing, 2)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sessionStatus: String {
        let state: ZhulongSessionStateCopyKey = if session.workspaceStatus == .paused {
            .paused
        } else if session.workspaceStatus == .archived {
            .archived
        } else {
            switch session.phase {
            case .scopeReview: .scopeReview
            case .readyForProvider: .readyForProvider
            case .providerRunning: .providerRunning
            case .decisionGate: .decisionGate
            case .draftReview: .draftReview
            }
        }
        return copy.sessionStatus(state, style: .expanded)
    }
}

private struct ZhulongHomeWorkflow: Identifiable {
    let id: String
    let title: String
    let detail: String
    let intent: String
    let task: ZhulongTask
    let isSuggestion: Bool

    init(
        id: String,
        title: String,
        detail: String,
        intent: String,
        task: ZhulongTask,
        isSuggestion: Bool = false
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.intent = intent
        self.task = task
        self.isSuggestion = isSuggestion
    }
}

enum ZhulongHomeIntentResolver {
    static func task(for intent: String) -> ZhulongTask {
        let normalized = intent.lowercased()
        if containsAny(
            ["收尾", "复盘", "回顾今天", "结束今天", "daily close", "review today", "close today"],
            in: normalized
        ) {
            return .dailyReview
        }
        if containsAny(
            ["排期", "安排明天", "安排任务", "计划明天", "schedule", "reschedule", "plan tomorrow"],
            in: normalized
        ) {
            return .scheduling
        }
        if containsAny(
            ["分组", "标签", "分类", "归类", "group", "tag", "classify", "classification"],
            in: normalized
        ) {
            return .classification
        }
        return .taskDecomposition
    }

    private static func containsAny(_ terms: [String], in value: String) -> Bool {
        terms.contains { value.contains($0) }
    }
}
