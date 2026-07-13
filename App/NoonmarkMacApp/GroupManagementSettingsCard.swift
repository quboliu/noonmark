import NoonmarkCore
import NoonmarkMacUIContract
import SwiftUI

struct GroupManagementSettingsCard: View {
    @EnvironmentObject private var store: NoonmarkStore

    private var catalog: ClassificationCatalogProjection? {
        store.classificationCatalog()
    }

    private var activeGroups: [ClassificationCatalogItemProjection] {
        catalog?.activeManageableItems(for: .category) ?? []
    }

    private var activeLabels: [ClassificationCatalogItemProjection] {
        catalog?.activeManageableItems(for: .label) ?? []
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.grid.2x2")
                .font(.noonmarkSystem(size: 15, weight: .semibold))
                .foregroundStyle(Theme.navSettings)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.chip))

            VStack(alignment: .leading, spacing: 3) {
                Text("分组与标签")
                    .font(.noonmarkSystem(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Text("用一个分组建立结构，再用标签补充横向线索。")
                    .font(.noonmarkSystem(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            summaryMetric(
                title: "分组",
                value: activeGroups.count,
                systemImage: "folder.fill",
                color: Theme.accent,
                accessibilityIdentifier: "settings.groups.category-count"
            )

            Rectangle()
                .fill(Theme.line)
                .frame(width: 1, height: 32)

            summaryMetric(
                title: "标签",
                value: activeLabels.count,
                systemImage: "number",
                color: Theme.ok,
                accessibilityIdentifier: "settings.groups.label-count"
            )

            ClassificationManagerButton(title: "管理分组与标签", prominent: true)
        }
        .padding(.horizontal, 14)
        .frame(height: CGFloat(MacUIClassificationLayout.settingsSummaryHeight))
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
        .accessibilityIdentifier("settings.groups")
    }

    private func summaryMetric(
        title: String,
        value: Int,
        systemImage: String,
        color: Color,
        accessibilityIdentifier: String
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.noonmarkSystem(size: 11, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.09)))
            VStack(alignment: .leading, spacing: 1) {
                Text("\(value)")
                    .font(.noonmarkSystem(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text1)
                Text(title)
                    .font(.noonmarkSystem(size: 10))
                    .foregroundStyle(Theme.text3)
            }
        }
        .frame(minWidth: 54, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel("\(value) 个\(title)")
    }
}
