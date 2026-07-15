import NoonmarkCore
import NoonmarkMacRuntime
import SwiftUI

struct GroupManagementSettingsCard: View {
    @EnvironmentObject private var store: NoonmarkStore

    private struct Counts {
        let categories: Int
        let labels: Int
    }

    private var presentation: AppPresentation {
        AppPresentation(language: store.engine.preferences.language)
    }

    private var copy: GroupManagementCopy {
        presentation.groupManagement
    }

    private var counts: Counts? {
        guard let catalog = store.classificationCatalog() else { return nil }
        return Counts(
            categories: catalog.activeManageableItems(for: .category).count,
            labels: catalog.activeManageableItems(for: .label).count
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(copy.subtitle)
                .font(.noonmarkSystem(size: 12))
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                if let counts {
                    summaryMetric(
                        value: counts.categories,
                        metric: .category,
                        systemImage: "folder.fill",
                        color: Theme.accent,
                        accessibilityIdentifier: "settings.groups.category-count"
                    )

                    Divider()
                        .frame(height: 30)

                    summaryMetric(
                        value: counts.labels,
                        metric: .label,
                        systemImage: "number",
                        color: Theme.ok,
                        accessibilityIdentifier: "settings.groups.label-count"
                    )
                } else {
                    unavailableMessage
                }

                Spacer(minLength: 12)
                ClassificationManagerButton(title: copy.manageAction, prominent: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("settings.groups")
    }

    private func summaryMetric(
        value: Int,
        metric: GroupManagementMetric,
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
                Text(copy.metricTitle(metric))
                    .font(.noonmarkSystem(size: 10))
                    .foregroundStyle(Theme.text3)
            }
        }
        .frame(minWidth: 54, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(copy.metricAccessibilityLabel(metric, count: value))
    }

    private var unavailableMessage: some View {
        Label {
            Text(presentation.message(for: .classificationCatalogUnavailable))
                .font(.noonmarkSystem(size: 10.5))
                .foregroundStyle(Theme.text2)
                .lineLimit(2)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Theme.warn)
        }
        .frame(maxWidth: 230, alignment: .leading)
        .accessibilityIdentifier("settings.groups.unavailable")
    }
}
