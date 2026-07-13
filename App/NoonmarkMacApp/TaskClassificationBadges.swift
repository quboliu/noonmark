import Foundation
import NoonmarkCore
import SwiftUI

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
    var showsCategory = true

    @State private var isShowingAllLabels = false

    private var hasClassification: Bool {
        (showsCategory && display.category != nil) || display.labels.isEmpty == false
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
                "任务「\(taskTitle)」的\(display.isHistorical ? "当时分组与标签" : "当前分组与标签")"
            )
            .animation(
                .easeInOut(duration: Self.animationDuration),
                value: isShowingAllLabels
            )
        }
    }

    private func badgeRow(visibleLabelCount: Int) -> some View {
        let visibleLabels = Array(display.labels.prefix(visibleLabelCount))
        let overflowCount = max(0, display.labels.count - visibleLabels.count)

        return HStack(spacing: 6) {
            if showsCategory, let category = display.category {
                TaskGroupMarker(
                    category: category,
                    taskTitle: taskTitle,
                    accessibilityIdentifier: accessibilityNamespace.categoryIdentifier
                )
            }

            ForEach(visibleLabels) { label in
                TaskLabelPatch(
                    label: label,
                    accessibilityIdentifier: accessibilityNamespace.labelIdentifier(label.id),
                    accessibilityLabel: "任务「\(taskTitle)」的标签「\(label.name)」"
                )
            }

            if overflowCount > 0 {
                ClassificationOverflowButton(
                    hiddenCount: overflowCount,
                    totalCount: display.labels.count,
                    taskTitle: taskTitle,
                    accessibilityIdentifier: accessibilityNamespace.overflowIdentifier
                ) {
                    withAnimation(.easeInOut(duration: Self.animationDuration)) {
                        isShowingAllLabels = true
                    }
                }
                .popover(isPresented: $isShowingAllLabels, arrowEdge: .bottom) {
                    ClassificationLabelsPopover(
                        labels: display.labels,
                        taskTitle: taskTitle,
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
    let taskTitle: String
    let accessibilityIdentifier: String

    private var color: Color {
        classificationUIColor(category.colorHex)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder.fill")
                .font(.noonmarkSystem(size: 9, weight: .semibold))
                .foregroundStyle(color)
            Text(category.name)
                .font(.noonmarkSystem(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.text1)
                .lineLimit(1)
        }
        .padding(.horizontal, 5)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.09)))
        .background {
            AppE2EViewAnchor(
                identifier: accessibilityIdentifier,
                verificationText: category.name
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel("任务「\(taskTitle)」的分组「\(category.name)」")
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
        .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.10)))
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .stroke(color.opacity(0.48), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
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
    let totalCount: Int
    let taskTitle: String
    let accessibilityIdentifier: String
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
                        .stroke(Theme.line2.opacity(0.72), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(
            "展开任务「\(taskTitle)」的全部 \(totalCount) 个标签；当前还有 \(hiddenCount) 个未显示"
        )
        .background {
            AppE2EViewAnchor(
                identifier: accessibilityIdentifier,
                verificationText: "+\(hiddenCount)"
            )
        }
    }
}

private struct ClassificationLabelsPopover: View {
    let labels: [ClassificationItemProjection]
    let taskTitle: String
    let accessibilityNamespace: TaskClassificationAccessibilityNamespace

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                Text("全部标签")
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.6)
                    .padding(.bottom, 2)

                ForEach(labels) { label in
                    TaskLabelPatch(
                        label: label,
                        accessibilityIdentifier: accessibilityNamespace.popoverLabelIdentifier(label.id),
                        accessibilityLabel: "任务「\(taskTitle)」的标签「\(label.name)」",
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
        .accessibilityLabel("任务「\(taskTitle)」的全部标签")
        .background {
            AppE2EViewAnchor(
                identifier: accessibilityNamespace.popoverIdentifier,
                verificationText: taskTitle
            )
        }
    }
}
