import NoonmarkCore
import NoonmarkMacRuntime
import SwiftUI

struct TaskCollectionPresentationMenu: View {
    let copy: AppCopy
    let accessibilityIdentifier: String
    @Binding var preference: TaskCollectionPresentationPreference

    var body: some View {
        Menu {
            Picker(copy.taskCollectionOrganization, selection: $preference.organization) {
                Text(copy.taskCollectionFlat).tag(TaskCollectionOrganization.flat)
                Text(copy.taskCollectionGrouped).tag(TaskCollectionOrganization.grouped)
            }
            Divider()
            Picker(copy.taskCollectionSortKey, selection: $preference.sortKey) {
                Text(copy.taskCollectionSortTime).tag(TaskCollectionSortKey.time)
                Text(copy.taskCollectionSortTitle).tag(TaskCollectionSortKey.title)
            }
            Picker(copy.taskCollectionDirection, selection: $preference.direction) {
                Text(copy.taskCollectionAscending).tag(TaskCollectionSortDirection.ascending)
                Text(copy.taskCollectionDescending).tag(TaskCollectionSortDirection.descending)
            }
        } label: {
            Label(copy.taskCollectionView, systemImage: "arrow.up.arrow.down")
                .font(.noonmarkSystem(size: 11.5, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct TaskCollectionSectionHeader: View {
    let section: TaskCollectionPresentationSection
    let count: Int

    private var foreground: Color {
        guard let colorHex = section.category?.visualStyle.foregroundColorHex
        else { return Theme.text1 }
        return classificationUIColor(colorHex, fallback: Theme.text1)
    }

    var body: some View {
        HStack(spacing: 7) {
            if section.category != nil {
                Image(systemName: "folder.fill")
                    .font(.noonmarkSystem(size: 11, weight: .semibold))
                    .foregroundStyle(foreground)
            }
            Text(section.title ?? "")
                .font(.noonmarkSystem(size: 12, weight: .semibold))
                .foregroundStyle(foreground)
            Text("\(count)")
                .font(.noonmarkSystem(size: 10.5))
                .foregroundStyle(Theme.text3)
                .monospacedDigit()
            Spacer()
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
        .background {
            if let category = section.category {
                AppE2EViewAnchor(
                    identifier:
                    "task-collection.section.category.\(category.id)",
                    verificationText: category.name
                )
            }
        }
    }
}

extension ClassificationItemProjection {
    var taskCollectionCategoryPresentation: TaskCollectionCategoryPresentation {
        TaskCollectionCategoryPresentation(
            id: id,
            name: name,
            colorHex: colorHex,
            approval: presentationApproval == .userApproved ? .userApproved : .pendingAIReview
        )
    }
}
