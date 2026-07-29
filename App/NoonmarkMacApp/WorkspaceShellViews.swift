import AppKit
import Combine
import CryptoKit
import Darwin
import NoonmarkAI
@_spi(ClassificationUserDecision) import NoonmarkCore
import NoonmarkDayContext
import NoonmarkMacRuntime
import NoonmarkMacUIContract
import NoonmarkStorage
import NoonmarkSync
import NoonmarkZhulong
import NoonmarkZhulongAI
import SwiftUI
import UniformTypeIdentifiers

struct Sidebar: View {
    @EnvironmentObject private var store: NoonmarkStore

    var planPages: [NoonmarkStore.Page] {
        [.day, .pool, .future, .recurring]
    }

    var tracePages: [NoonmarkStore.Page] {
        [.unfinished, .completed, .calendar, .zhulong]
            .filter { store.visibleNavigationPages.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader
            ForEach(planPages) { page in
                NavItem(
                    page: page,
                    label: store.navigationLabel(for: page),
                    count: store.navigationCount(for: page),
                    isCompact: store.isSidebarExpanded == false
                )
            }

            if store.isSidebarExpanded {
                NavGroupTitle(store.copy.traceGroup)
                    .padding(.top, 12)
            } else {
                Divider()
                    .overlay(Theme.lineSubtle)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 10)
            }
            ForEach(tracePages) { page in
                NavItem(
                    page: page,
                    label: store.navigationLabel(for: page),
                    count: store.navigationCount(for: page),
                    isCompact: store.isSidebarExpanded == false
                )
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background(Theme.sidebar)
        .background {
            AppE2EViewAnchor(identifier: "shell.sidebar")
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 0) {
            if store.isSidebarExpanded {
                NavGroupTitle(store.copy.planGroup)
                    .padding(.bottom, 0)
                Spacer(minLength: 4)
            } else {
                Spacer(minLength: 0)
            }
            PaneBoundaryToggle(
                direction: store.isSidebarExpanded ? .left : .right,
                accessibilityLabel: store.isSidebarExpanded
                    ? store.copy.collapseSidebar
                    : store.copy.expandSidebar,
                identifier: "shell.sidebar.toggle"
            ) {
                store.toggleSidebar()
            }
            if store.isSidebarExpanded == false {
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, store.isSidebarExpanded ? 0 : 5)
        .padding(.trailing, store.isSidebarExpanded ? 10 : 5)
        .padding(.bottom, 4)
    }
}

struct NavGroupTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.noonmarkSystem(size: 11, weight: .semibold))
            .foregroundStyle(Theme.text3)
            .tracking(0.6)
            .padding(.horizontal, 20)
            .padding(.bottom, 5)
    }
}

struct NavItem: View {
    @EnvironmentObject private var store: NoonmarkStore
    let page: NoonmarkStore.Page
    let label: String
    let count: Int
    let isCompact: Bool

    var active: Bool { store.page == page }

    var body: some View {
        Button {
            store.selectPage(page)
        } label: {
            Group {
                if isCompact {
                    navigationIcon
                        .frame(maxWidth: .infinity)
                } else {
                    HStack(spacing: 10) {
                        navigationIcon
                        Text(label)
                            .font(.noonmarkSystem(size: 14.5, weight: active ? .semibold : .medium))
                            .foregroundStyle(active ? Theme.text1 : Theme.text2)
                        Spacer()
                        if count > 0 {
                            Text("\(count)")
                                .font(.noonmarkSystem(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(Theme.text3)
                        }
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, 12)
                }
            }
            .frame(height: NoonmarkVisualMetrics.navigationRowHeight)
            .hoverSurface(
                active: active,
                cornerRadius: 8,
                idleFill: .clear,
                hoverFill: Theme.panel.opacity(0.72),
                activeFill: Theme.accentSoft.opacity(Theme.layeredSurfaceOpacity),
                idleStroke: .clear,
                hoverStroke: Theme.line.opacity(0.45),
                activeStroke: .clear
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, isCompact ? 7 : 9)
        .padding(.vertical, 1.5)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
        .help(label)
        .background {
            AppE2EViewAnchor(
                identifier: "sidebar.nav.\(page.rawValue)",
                verificationText: label
            )
        }
    }

    private var navigationIcon: some View {
        Image(systemName: page.navigationSystemImage)
            .font(
                .noonmarkRenderedSystem(
                    size: NoonmarkVisualMetrics.navigationIconSize,
                    weight: .medium
                )
            )
            .frame(width: 19)
            .foregroundStyle(page.navigationIconColor)
    }
}

struct MainSurface: View {
    @EnvironmentObject private var store: NoonmarkStore

    var body: some View {
        Group {
            switch store.page {
            case .day:
                DayTodoPage()
            case .pool:
                TaskPoolPage()
            case .future:
                FuturePlansPage()
            case .recurring:
                RecurringPlansPage()
            case .unfinished:
                UnfinishedPoolPage()
            case .completed:
                CompletedPoolPage()
            case .calendar:
                CalendarPage()
            case .zhulong:
                ZhulongPage()
            case .settings:
                DayTodoPage()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            AppE2EViewAnchor(identifier: "shell.middle-pane")
        }
        .background(Theme.panel)
    }
}

struct TaskSelectionClearingScrollView<Content: View>: View {
    @EnvironmentObject private var store: NoonmarkStore
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Theme.panel)
                        .contentShape(Rectangle())
                        .onTapGesture { store.clearSelection() }
                    content
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: proxy.size.height,
                    alignment: .topLeading
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
