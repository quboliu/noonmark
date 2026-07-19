import AppKit
import NoonmarkCore
import NoonmarkMacRuntime
import NoonmarkMacUIContract
import SwiftUI

@MainActor
final class NoonmarkSearchWindowController: NSWindowController {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("Noonmark.SearchWindow")
    static let frameAutosaveName = "Noonmark.SearchWindow.Frame"
    static let minimumContentSize = NSSize(width: 520, height: 360)

    private let store: NoonmarkStore
    private let model = NoonmarkSearchWindowModel()

    init(store: NoonmarkStore) {
        self.store = store
        let root = NoonmarkSearchView(model: model)
            .environmentObject(store)
            .preferredColorScheme(.light)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = Self.windowIdentifier
        window.title = store.copy.searchCommand
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.enableNoonmarkDynamicKeyViewLoop()
        window.installNoonmarkResizableHostingContent(
            root,
            minimumContentSize: Self.minimumContentSize
        )

        super.init(window: window)
        windowFrameAutosaveName = Self.frameAutosaveName
        model.onClose = { [weak self] in self?.close() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(onReveal: @escaping (WorkspaceSearchResult) -> Void) {
        model.onReveal = onReveal
        model.requestFocus()
        window?.title = store.copy.searchCommand
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshLocalizedChrome() {
        window?.title = store.copy.searchCommand
    }
}

@MainActor
final class NoonmarkSearchWindowModel: ObservableObject {
    @Published private(set) var focusRequest = 0
    var onReveal: ((WorkspaceSearchResult) -> Void)?
    var onClose: (() -> Void)?

    func requestFocus() {
        focusRequest &+= 1
    }

    func reveal(_ result: WorkspaceSearchResult) {
        onReveal?(result)
        onClose?()
    }
}

private struct NoonmarkSearchView: View {
    @EnvironmentObject private var store: NoonmarkStore
    @ObservedObject var model: NoonmarkSearchWindowModel
    @State private var query = ""
    @State private var selectedResultID: String?
    @FocusState private var searchIsFocused: Bool

    private var results: [WorkspaceSearchResult] {
        WorkspaceSearchIndex(engine: store.engine).search(query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.text3)
                    .accessibilityHidden(true)
                TextField(store.copy.searchPlaceholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.noonmarkSystem(size: 15))
                    .focused($searchIsFocused)
                    .onSubmit(revealSelectedResult)
                    .accessibilityIdentifier("search.field")
                    .background {
                        AppE2EViewAnchor(identifier: "search.field")
                    }
                if query.isEmpty == false {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.text3)
                            .frame(
                                width: CGFloat(MacUIAccessibilityLayout.minimumInteractiveTargetSize),
                                height: CGFloat(MacUIAccessibilityLayout.minimumInteractiveTargetSize)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(store.copy.clear)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(Theme.controlFill)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.line).frame(height: 1)
            }

            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchPlaceholder
            } else if results.isEmpty {
                emptyResults
            } else {
                List(results, selection: $selectedResultID) { result in
                    NoonmarkSearchResultRow(result: result)
                        .tag(result.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            model.reveal(result)
                        }
                }
                .listStyle(.inset)
                .accessibilityIdentifier("search.results")
                .background {
                    AppE2EViewAnchor(identifier: "search.results")
                }
            }
        }
        .background(Theme.background)
        .onAppear {
            searchIsFocused = true
        }
        .onChange(of: model.focusRequest) { _, _ in
            searchIsFocused = true
        }
        .onChange(of: query) { _, _ in
            selectedResultID = results.first?.id
        }
        .onChange(of: results.map(\.id)) { _, ids in
            if let selectedResultID, ids.contains(selectedResultID) {
                return
            }
            selectedResultID = ids.first
        }
        .onExitCommand {
            model.onClose?()
        }
        .background {
            AppE2EViewAnchor(
                identifier: "search.window",
                verificationText: store.copy.searchCommand
            )
        }
    }

    private var searchPlaceholder: some View {
        ContentUnavailableView(
            store.copy.searchEmptyPrompt,
            systemImage: "magnifyingglass"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyResults: some View {
        ContentUnavailableView(
            store.copy.searchNoResults,
            systemImage: "magnifyingglass",
            description: Text(store.copy.searchNoResultsHint)
        )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(store.copy.searchNoResults)
    }

    private func revealSelectedResult() {
        let result = results.first { $0.id == selectedResultID } ?? results.first
        guard let result else { return }
        model.reveal(result)
    }
}

private struct NoonmarkSearchResultRow: View {
    @EnvironmentObject private var store: NoonmarkStore
    let result: WorkspaceSearchResult

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.noonmarkSystem(size: 13, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(result.title)
                    .font(.noonmarkSystem(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text1)
                    .lineLimit(1)
                if let context = result.context {
                    Text(context)
                        .font(.noonmarkSystem(size: 11.5))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 3) {
                Text(kindLabel)
                    .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                if let dateLabel {
                    Text(dateLabel)
                        .font(.noonmarkSystem(size: 10.5))
                        .foregroundStyle(Theme.text3)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private var kindLabel: String {
        switch result.kind {
        case .task:
            store.copy.searchTaskKind
        case .poolTask:
            store.copy.searchPoolTaskKind
        case .subtask:
            store.copy.searchSubtaskKind
        }
    }

    private var iconName: String {
        switch result.kind {
        case .task:
            "checklist"
        case .poolTask:
            "tray"
        case .subtask:
            "checkmark.circle"
        }
    }

    private var iconColor: Color {
        switch result.kind {
        case .task:
            Theme.navDay
        case .poolTask:
            Theme.navPool
        case .subtask:
            Theme.accent
        }
    }

    private var dateLabel: String? {
        let date: LocalDate? = switch result.destination {
        case let .trace(_, traceDate, _):
            traceDate
        case let .subtask(_, _, subtaskDate, _):
            subtaskDate
        case .pool:
            nil
        }
        return date.map(store.displayDate)
    }
}

extension NoonmarkStore {
    func revealSearchResult(_ result: WorkspaceSearchResult) {
        switch result.destination {
        case let .pool(chainID):
            guard engine.taskPool().contains(where: { $0.chain.id == chainID }) else {
                clearSelection()
                return
            }
            selectPage(.pool)
            selectPool(chainID)
        case let .trace(traceID, _, _):
            guard let trace = currentSearchTrace(traceID) else {
                clearSelection()
                return
            }
            revealTraceSearchResult(trace)
        case let .subtask(subtaskID, _, _, _):
            guard let subtask = engine.subtasks[subtaskID],
                  let parentTrace = currentSearchTrace(subtask.traceID)
            else {
                clearSelection()
                return
            }
            let isVisibleCompletedSubtask = parentTrace.status == .completed
                && engine.completedSubtaskRecords().contains {
                    $0.subtask.id == subtaskID
                }
            if isVisibleCompletedSubtask {
                selectPage(.completed)
                selectCompletedSubtask(subtaskID)
            } else {
                revealTraceSearchResult(parentTrace)
            }
        }
    }

    private func currentSearchTrace(_ traceID: DayTraceID) -> DayTrace? {
        guard let trace = engine.traces[traceID], trace.formsDayHistory else {
            return nil
        }
        return trace
    }

    private func revealTraceSearchResult(_ trace: DayTrace) {
        if trace.status == .completed {
            selectPage(.completed)
            selectCompleted(trace.id)
        } else {
            selectPage(.day)
            selectedDate = trace.date
            selectedCalendarDate = trace.date
            selectTrace(trace.id)
        }
    }
}
