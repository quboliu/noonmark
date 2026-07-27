import Foundation
import NoonmarkCore
import NoonmarkMacRuntime
import NoonmarkMacUIContract
import SwiftUI

private extension EnvironmentValues {
    @Entry var taskRowCategoryIsVisible: Bool = true
}

extension View {
    func taskRowCategoryVisibility(_ isVisible: Bool) -> some View {
        environment(
            \.taskRowCategoryIsVisible,
            isVisible
        )
    }

    func taskCollectionCategoryVisibility(
        _ preference: TaskCollectionPresentationPreference
    ) -> some View {
        environment(
            \.taskRowCategoryIsVisible,
            preference.showsCategoryInItemRows
        )
    }

    func taskCollectionCategoryVisibility(
        _ preference: TaskCollectionPresentationPreference,
        in section: TaskCollectionPresentationSection
    ) -> some View {
        environment(
            \.taskRowCategoryIsVisible,
            preference.showsCategoryInItemRows(in: section)
        )
    }
}

struct TaskClassificationAccessibilityNamespace: Hashable {
    let rawValue: String

    init(surface: String, instanceID: String) {
        precondition(surface.isEmpty == false)
        precondition(instanceID.isEmpty == false)
        rawValue = "classification.\(surface).\(instanceID)"
    }

    var categoryIdentifier: String { "\(rawValue).category" }
    var overflowIdentifier: String { "\(rawValue).overflow" }
    var popoverIdentifier: String { "\(rawValue).popover" }

    func containerIdentifier(isHistorical: Bool) -> String {
        "\(rawValue).\(isHistorical ? "history" : "current")"
    }

    func labelIdentifier(_ labelID: String) -> String {
        "\(rawValue).label.\(labelID)"
    }

    func popoverLabelIdentifier(_ labelID: String) -> String {
        "\(popoverIdentifier).label.\(labelID)"
    }
}

struct TaskClassificationBadges: View {
    private static let maximumVisibleLabelCount = 2
    private static let animationDuration = 0.18

    let display: TaskClassificationDisplay
    let taskTitle: String
    let accessibilityNamespace: TaskClassificationAccessibilityNamespace

    @EnvironmentObject private var store: NoonmarkStore
    @Environment(\.taskRowCategoryIsVisible)
    private var taskRowCategoryIsVisible

    @State private var isShowingAllLabels = false

    private var hasClassification: Bool {
        (taskRowCategoryIsVisible && display.category != nil)
            || display.labels.isEmpty == false
    }

    private var copy: TaskClassificationBadgesCopy {
        AppPresentation(
            language: store.engine.preferences.language
        ).taskClassificationBadges
    }

    private var accessibilityTaskTitle: String {
        store.copy.displayTaskTitle(taskTitle)
    }

    var body: some View {
        if hasClassification {
            ViewThatFits(in: .horizontal) {
                badgeRow(visibleLabelCount: Self.maximumVisibleLabelCount)
                if display.labels.count > 1 {
                    badgeRow(visibleLabelCount: 1)
                }
                if display.labels.isEmpty == false {
                    badgeRow(visibleLabelCount: 0)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(accessibilityNamespace.containerIdentifier(isHistorical: display.isHistorical))
            .accessibilityLabel(
                copy.containerAccessibilityLabel(
                    taskTitle: accessibilityTaskTitle,
                    isHistorical: display.isHistorical
                )
            )
            .animation(
                Theme.shouldReduceMotion
                    ? nil
                    : .easeInOut(duration: Self.animationDuration),
                value: isShowingAllLabels
            )
        }
    }

    private func badgeRow(visibleLabelCount: Int) -> some View {
        let visibleLabels = Array(display.labels.prefix(visibleLabelCount))
        let overflowCount = max(0, display.labels.count - visibleLabels.count)

        return HStack(spacing: 6) {
            if taskRowCategoryIsVisible, let category = display.category {
                TaskGroupMarker(
                    category: category,
                    accessibilityIdentifier: accessibilityNamespace.categoryIdentifier,
                    accessibilityLabel: copy.taskGroupAccessibilityLabel(
                        taskTitle: accessibilityTaskTitle,
                        groupName: category.name
                    )
                )
            }

            ForEach(visibleLabels) { label in
                TaskLabelPatch(
                    label: label,
                    accessibilityIdentifier: accessibilityNamespace.labelIdentifier(label.id),
                    accessibilityLabel: copy.taskTagAccessibilityLabel(
                        taskTitle: accessibilityTaskTitle,
                        tagName: label.name
                    )
                )
            }

            if overflowCount > 0 {
                ClassificationOverflowButton(
                    hiddenCount: overflowCount,
                    accessibilityIdentifier: accessibilityNamespace.overflowIdentifier,
                    accessibilityLabel: copy.overflowAccessibilityLabel(
                        taskTitle: accessibilityTaskTitle,
                        totalCount: display.labels.count,
                        hiddenCount: overflowCount
                    )
                ) {
                    withAnimation(
                        Theme.shouldReduceMotion
                            ? nil
                            : .easeInOut(duration: Self.animationDuration)
                    ) {
                        isShowingAllLabels = true
                    }
                }
                .popover(isPresented: $isShowingAllLabels, arrowEdge: .bottom) {
                    ClassificationLabelsPopover(
                        labels: display.labels,
                        taskTitle: accessibilityTaskTitle,
                        accessibilityNamespace: accessibilityNamespace
                    )
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct TaskGroupMarker: View {
    let category: ClassificationItemProjection
    let accessibilityIdentifier: String
    let accessibilityLabel: String

    private var color: Color {
        category.categoryPresentationColor
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder.fill")
                .font(.noonmarkSystem(size: 9, weight: .semibold))
                .foregroundStyle(color)
            Text(category.name)
                .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 5)
        .frame(height: 20)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(
                    category.usesApprovedCategoryPresentation
                        ? color.opacity(0.09)
                        : Theme.controlFill
                )
        )
        .background {
            AppE2EViewAnchor(
                identifier: accessibilityIdentifier,
                verificationText: category.name
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct TaskLabelPatch: View {
    let label: ClassificationItemProjection
    let accessibilityIdentifier: String
    let accessibilityLabel: String
    var isFocusable = false

    private var color: Color {
        classificationUIColor(label.colorHex)
    }

    var body: some View {
        HStack(spacing: 3) {
            Text("#")
                .font(.noonmarkSystem(size: 9, weight: .black, design: .rounded))
                .foregroundStyle(color)
            Text(label.name)
                .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.text2)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(MacUITaskLabelPatchLayout.semanticFillOpacity))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .stroke(
                    Theme.line,
                    lineWidth: CGFloat(MacUITaskLabelPatchLayout.borderLineWidth)
                )
        }
        .background {
            AppE2EViewAnchor(
                identifier: accessibilityIdentifier,
                verificationText: label.name
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(accessibilityLabel)
        .focusable(isFocusable)
    }
}

private struct ClassificationOverflowButton: View {
    let hiddenCount: Int
    let accessibilityIdentifier: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("+\(hiddenCount)")
                .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.text2)
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 3).fill(Theme.chip))
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(
                            Theme.line,
                            lineWidth: CGFloat(MacUITaskLabelPatchLayout.borderLineWidth)
                        )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(accessibilityLabel)
        .background {
            AppE2EViewAnchor(
                identifier: accessibilityIdentifier,
                verificationText: "+\(hiddenCount)"
            )
        }
    }
}

private struct ClassificationLabelsPopover: View {
    @EnvironmentObject private var store: NoonmarkStore

    let labels: [ClassificationItemProjection]
    let taskTitle: String
    let accessibilityNamespace: TaskClassificationAccessibilityNamespace

    private var copy: TaskClassificationBadgesCopy {
        AppPresentation(
            language: store.engine.preferences.language
        ).taskClassificationBadges
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                Text(copy.allTagsTitle)
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.6)
                    .padding(.bottom, 2)

                ForEach(labels) { label in
                    TaskLabelPatch(
                        label: label,
                        accessibilityIdentifier: accessibilityNamespace.popoverLabelIdentifier(label.id),
                        accessibilityLabel: copy.taskTagAccessibilityLabel(
                            taskTitle: taskTitle,
                            tagName: label.name
                        ),
                        isFocusable: true
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(minWidth: 220, maxWidth: 320, maxHeight: 280)
        .background(Theme.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityNamespace.popoverIdentifier)
        .accessibilityLabel(copy.allTagsAccessibilityLabel(taskTitle: taskTitle))
        .background {
            AppE2EViewAnchor(
                identifier: accessibilityNamespace.popoverIdentifier,
                verificationText: taskTitle
            )
        }
    }
}
