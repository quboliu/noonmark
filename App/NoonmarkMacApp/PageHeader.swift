import SwiftUI

/// 列表页统一页头：主标题（20pt semibold text1）+ 可选副标题
/// （12pt text2，与标题间距 4），右侧控件条与标题块 center 对齐。
/// 底部留白统一 12pt；与下方内容的额外间距由内容自身 top padding 承担。
struct WorkspacePageHeader<Trailing: View>: View {
    @EnvironmentObject private var store: NoonmarkStore
    let title: String
    let subtitle: String?
    let trailing: Trailing

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.noonmarkSystem(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                if let subtitle {
                    Text(subtitle)
                        .font(.noonmarkSystem(size: 12))
                        .foregroundStyle(Theme.text2)
                        .lineSpacing(3)
                }
            }
            Spacer(minLength: 8)
            trailing
            if store.hasDetailRailContent && store.isDetailRailExpanded == false {
                PaneBoundaryToggle(
                    direction: .left,
                    accessibilityLabel: store.copy.expandDetailRail,
                    identifier: "shell.detail-rail.toggle"
                ) {
                    store.toggleDetailRail()
                }
            }
        }
        .padding(.horizontal, NoonmarkVisualMetrics.pageHorizontalPadding)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
}
