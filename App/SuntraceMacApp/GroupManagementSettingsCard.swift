import SuntraceCore
import SwiftUI

struct GroupManagementSettingsCard: View {
    @EnvironmentObject private var store: SuntraceStore

    private var catalog: ClassificationCatalogProjection? {
        store.classificationCatalog()
    }

    private var activeGroups: [ClassificationCatalogItemProjection] {
        catalog?.categories.filter { $0.lifecycle == .active && $0.mergedIntoID == nil } ?? []
    }

    private var activeLabels: [ClassificationCatalogItemProjection] {
        catalog?.labels.filter { $0.lifecycle == .active && $0.mergedIntoID == nil } ?? []
    }

    var body: some View {
        SettingsCard(
            systemImage: "square.grid.2x2",
            title: "分组与标签",
            subtitle: "分组建立任务结构，标签提供可叠加的横向线索。"
        ) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    metric(
                        title: "分组",
                        value: activeGroups.count,
                        detail: "每项任务至多一个",
                        systemImage: "folder.fill",
                        color: Theme.accent
                    )
                    metric(
                        title: "标签",
                        value: activeLabels.count,
                        detail: "可自由叠加",
                        systemImage: "number",
                        color: Theme.ok
                    )
                }

                VStack(alignment: .leading, spacing: 9) {
                    Text("视觉语义")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.text3)
                    HStack(spacing: 16) {
                        if let group = activeGroups.first {
                            groupPreview(group)
                        }
                        if let label = activeLabels.first {
                            labelPreview(label)
                        }
                    }
                }

                HStack {
                    Text("名称、生命周期和引用保护都在统一浮窗内维护。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text3)
                    Spacer()
                    ClassificationManagerButton()
                }
                .padding(.top, 2)
            }
        }
        .accessibilityIdentifier("settings.groups")
    }

    private func metric(
        title: String,
        value: Int,
        detail: String,
        systemImage: String,
        color: Color
    ) -> some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.10)))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value) 个\(title)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.text1)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.text3)
            }
            Spacer()
        }
        .padding(11)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.controlFill))
    }

    private func groupPreview(_ group: ClassificationCatalogItemProjection) -> some View {
        let color = classificationUIColor(group.colorHex)
        return HStack(spacing: 4) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10))
                .foregroundStyle(color)
            Text(group.name)
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 5)
        .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.09)))
    }

    private func labelPreview(_ label: ClassificationCatalogItemProjection) -> some View {
        let color = classificationUIColor(label.colorHex)
        return HStack(spacing: 3) {
            Text("#").font(.system(size: 9, weight: .black, design: .rounded)).foregroundStyle(color)
            Text(label.name).font(.system(size: 10.5, weight: .semibold))
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.10)))
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .stroke(color.opacity(0.48), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        }
    }
}
