@_spi(ClassificationUserDecision) import NoonmarkCore
import NoonmarkMacRuntime
import SwiftUI

struct IOSTaskCollectionPresentationMenu: View {
    let accessibilityIdentifier: String
    @Binding var preference: TaskCollectionPresentationPreference

    var body: some View {
        Menu {
            Picker("组织", selection: $preference.organization) {
                Text("平铺").tag(TaskCollectionOrganization.flat)
                Text("按分类").tag(TaskCollectionOrganization.grouped)
            }
            Divider()
            Picker("排序", selection: $preference.sortKey) {
                Text("时间").tag(TaskCollectionSortKey.time)
                Text("标题").tag(TaskCollectionSortKey.title)
            }
            Picker("方向", selection: $preference.direction) {
                Text("升序").tag(TaskCollectionSortDirection.ascending)
                Text("降序").tag(TaskCollectionSortDirection.descending)
            }
        } label: {
            Label("视图", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct IOSTaskCollectionSectionHeader: View {
    let section: TaskCollectionPresentationSection
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            if section.isPinnedQueue {
                Image(systemName: "pin.fill")
            } else if section.category != nil {
                Image(systemName: "folder.fill")
            }
            Text(section.title ?? "置顶")
                .font(.headline)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
    }
}

extension ClassificationItemProjection {
    var iosTaskCollectionCategoryPresentation: TaskCollectionCategoryPresentation {
        TaskCollectionCategoryPresentation(
            id: id,
            name: name,
            colorHex: colorHex,
            approval: presentationApproval == .userApproved
                ? .userApproved
                : .pendingAIReview
        )
    }
}
