import NoonmarkMacRuntime
import SwiftUI

// 右栏共享原语：与任务详情同一视觉语言 —— 无卡片、无描边容器，
// 依靠小标题、留白、1px 分隔线与克制的 accent 建立秩序。

struct RailDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.line)
            .frame(height: 1)
    }
}

struct RailHeroStat: View {
    let label: String
    let value: String
    var tone: Color = Theme.text1

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.noonmarkSystem(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .tracking(0.6)
            Spacer(minLength: 8)
            Text(value)
                .font(.noonmarkSystem(size: 22, weight: .semibold))
                .foregroundStyle(tone)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

struct RailStatRow: View {
    let label: String
    let value: String
    var valueColor: Color = Theme.text1

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.noonmarkSystem(size: 11.5))
                .foregroundStyle(Theme.text3)
            Spacer(minLength: 8)
            Text(value)
                .font(.noonmarkSystem(size: 11.5, weight: .medium))
                .foregroundStyle(valueColor)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

struct RailTrendPoint: Identifiable {
    let id = UUID()
    let axisLabel: String
    /// 完成率 0...1；nil 表示当天没有任务。
    let ratio: Double?
    let isHighlighted: Bool
}

struct RailTrendStrip: View {
    let points: [RailTrendPoint]

    private let maxBarHeight: CGFloat = 26

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(points) { point in
                    bar(point)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: maxBarHeight)
            HStack(spacing: 0) {
                ForEach(points) { point in
                    Text(point.axisLabel)
                        .font(.noonmarkSystem(size: 8.5))
                        .foregroundStyle(
                            point.isHighlighted ? Theme.accent : Theme.text3
                        )
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
    }

    private func bar(_ point: RailTrendPoint) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(barColor(point))
                .frame(width: 3, height: barHeight(point))
        }
    }

    private func barHeight(_ point: RailTrendPoint) -> CGFloat {
        guard let ratio = point.ratio else { return 3 }
        return max(3, maxBarHeight * CGFloat(min(1, max(0, ratio))))
    }

    private func barColor(_ point: RailTrendPoint) -> Color {
        guard point.ratio != nil else { return Theme.line2 }
        return point.isHighlighted ? Theme.accent : Theme.text3.opacity(0.55)
    }
}

struct RailSignal: Identifiable {
    let id = UUID()
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?
}

struct RailSignalList: View {
    let signals: [RailSignal]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(signals) { signal in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(signal.action == nil ? Theme.text3 : Theme.accent)
                        .frame(width: 4, height: 4)
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(signal.text)
                            .font(.noonmarkSystem(size: 11.5))
                            .foregroundStyle(Theme.text1)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                        if let actionTitle = signal.actionTitle, let action = signal.action {
                            TextActionButton(actionTitle, action: action)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

struct RailEntryRow: View {
    let systemImage: String
    let title: String
    var subtitle: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: systemImage)
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.noonmarkSystem(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                    if let subtitle, subtitle.isEmpty == false {
                        Text(subtitle)
                            .font(.noonmarkSystem(size: 10.5))
                            .foregroundStyle(Theme.text3)
                            .lineSpacing(3)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.noonmarkSystem(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.text3)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct RailSearchField: View {
    @EnvironmentObject private var store: NoonmarkStore
    @Binding var query: String
    var onSubmit: () -> Void = {}
    var onDismiss: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.noonmarkSystem(size: 11, weight: .medium))
                .foregroundStyle(Theme.text3)
            TextField(store.copy.railSearchPlaceholder, text: $query)
                .textFieldStyle(.plain)
                .font(.noonmarkSystem(size: 11.5))
                .foregroundStyle(Theme.text1)
                .accessibilityIdentifier("rail.search.field")
                .background {
                    AppE2EViewAnchor(
                        identifier: "rail.search.field"
                    )
                }
                .onSubmit(onSubmit)
                .onExitCommand(perform: onDismiss)
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.noonmarkSystem(size: 11))
                        .foregroundStyle(Theme.text3)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct RailSearchResultsPanel: View {
    @EnvironmentObject private var store: NoonmarkStore
    let results: [WorkspaceSearchResult]
    let onSelect: (WorkspaceSearchResult) -> Void

    var body: some View {
        Group {
            if results.isEmpty {
                InlineEmptyHint(store.copy.searchNoResults)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(results) { result in
                        resultRow(result)
                    }
                }
            }
        }
    }

    private func resultRow(_ result: WorkspaceSearchResult) -> some View {
        Button {
            onSelect(result)
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: kindIcon(result.kind))
                    .font(.noonmarkSystem(size: 10, weight: .medium))
                    .foregroundStyle(kindTint(result.kind))
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.copy.displayTaskTitle(result.title))
                        .font(.noonmarkSystem(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.text1)
                        .lineLimit(1)
                    if let context = result.context, context.isEmpty == false {
                        Text(
                            result.kind == .subtask
                                ? store.copy.displayTaskTitle(context)
                                : context
                        )
                        .font(.noonmarkSystem(size: 10.5))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Text(kindLabel(result.kind))
                    .font(.noonmarkSystem(size: 10))
                    .foregroundStyle(Theme.text3)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func kindLabel(_ kind: WorkspaceSearchResultKind) -> String {
        switch kind {
        case .task:
            store.copy.searchTaskKind
        case .poolTask:
            store.copy.searchPoolTaskKind
        case .recurringPlan:
            store.copy.searchRecurringPlanKind
        case .subtask:
            store.copy.searchSubtaskKind
        }
    }

    private func kindIcon(_ kind: WorkspaceSearchResultKind) -> String {
        switch kind {
        case .task:
            "checklist"
        case .poolTask:
            "tray"
        case .recurringPlan:
            "repeat"
        case .subtask:
            "checkmark.circle"
        }
    }

    private func kindTint(_ kind: WorkspaceSearchResultKind) -> Color {
        switch kind {
        case .task:
            Theme.navDay
        case .poolTask:
            Theme.navPool
        case .recurringPlan:
            Theme.navRecurring
        case .subtask:
            Theme.accent
        }
    }
}
