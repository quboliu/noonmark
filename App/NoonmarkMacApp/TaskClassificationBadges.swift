import Foundation
import NoonmarkCore
import SwiftUI

struct TaskClassificationBadges: View {
    private static let maximumVisibleLabelCount = 2
    private static let animationDuration = 0.18

    let display: TaskClassificationDisplay
    let chainID: TaskChainID
    let taskTitle: String
    var automaticallyShowsAllLabels = false

    @State private var isShowingAllLabels = false

    private var visibleLabels: [ClassificationItemProjection] {
        Array(display.labels.prefix(Self.maximumVisibleLabelCount))
    }

    private var overflowCount: Int {
        max(0, display.labels.count - Self.maximumVisibleLabelCount)
    }

    private var hasClassification: Bool {
        display.category != nil || display.labels.isEmpty == false
    }

    var body: some View {
        if hasClassification {
            HStack(spacing: 6) {
                if let category = display.category {
                    TaskGroupMarker(
                        category: category,
                        chainID: chainID,
                        taskTitle: taskTitle
                    )
                }

                ForEach(visibleLabels) { label in
                    TaskLabelPatch(
                        label: label,
                        accessibilityIdentifier: "classification.label.\(chainID.description).\(label.id)",
                        accessibilityLabel: "任务「\(taskTitle)」的标签「\(label.name)」"
                    )
                }

                if overflowCount > 0 {
                    ClassificationOverflowButton(
                        hiddenCount: overflowCount,
                        totalCount: display.labels.count,
                        chainID: chainID,
                        taskTitle: taskTitle
                    ) {
                        withAnimation(.easeInOut(duration: Self.animationDuration)) {
                            isShowingAllLabels = true
                        }
                    }
                    .popover(isPresented: $isShowingAllLabels, arrowEdge: .bottom) {
                        ClassificationLabelsPopover(
                            labels: display.labels,
                            chainID: chainID,
                            taskTitle: taskTitle
                        )
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(
                "classification.\(display.isHistorical ? "history" : "current").\(chainID.description)"
            )
            .accessibilityLabel(
                "任务「\(taskTitle)」的\(display.isHistorical ? "当时分类" : "当前分类")"
            )
            .animation(
                .easeInOut(duration: Self.animationDuration),
                value: isShowingAllLabels
            )
            .onAppear {
                if automaticallyShowsAllLabels {
                    isShowingAllLabels = true
                }
            }
            .onChange(of: automaticallyShowsAllLabels) { _, shouldShow in
                guard shouldShow else { return }
                withAnimation(.easeInOut(duration: Self.animationDuration)) {
                    isShowingAllLabels = true
                }
            }
        }
    }
}

struct TaskGroupMarker: View {
    let category: ClassificationItemProjection
    let chainID: TaskChainID
    let taskTitle: String

    private var color: Color {
        classificationUIColor(category.colorHex)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color)
            Text(category.name)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.text1)
                .lineLimit(1)
        }
        .padding(.horizontal, 5)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.09)))
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("classification.category.\(chainID.description)")
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
                .font(.system(size: 9, weight: .black, design: .rounded))
                .foregroundStyle(color)
            Text(label.name)
                .font(.system(size: 10.5, weight: .semibold))
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
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(accessibilityLabel)
        .focusable(isFocusable)
    }
}

private struct ClassificationOverflowButton: View {
    let hiddenCount: Int
    let totalCount: Int
    let chainID: TaskChainID
    let taskTitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("+\(hiddenCount)")
                .font(.system(size: 10.5, weight: .semibold))
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
        .accessibilityIdentifier("classification.overflow.\(chainID.description)")
        .accessibilityLabel(
            "展开任务「\(taskTitle)」的全部 \(totalCount) 个标签；当前还有 \(hiddenCount) 个未显示"
        )
    }
}

private struct ClassificationLabelsPopover: View {
    let labels: [ClassificationItemProjection]
    let chainID: TaskChainID
    let taskTitle: String

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                Text("全部标签")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .tracking(0.6)
                    .padding(.bottom, 2)

                ForEach(labels) { label in
                    TaskLabelPatch(
                        label: label,
                        accessibilityIdentifier: "classification.popover.label.\(chainID.description).\(label.id)",
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
        .accessibilityIdentifier("classification.popover.\(chainID.description)")
        .accessibilityLabel("任务「\(taskTitle)」的全部标签")
    }
}
