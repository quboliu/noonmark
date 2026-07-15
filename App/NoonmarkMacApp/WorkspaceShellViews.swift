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
        [.day, .pool, .future]
    }

    var tracePages: [NoonmarkStore.Page] {
        [.unfinished, .completed, .calendar, .zhulong]
            .filter { store.visibleNavigationPages.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavGroupTitle(store.copy.planGroup)
            ForEach(planPages) { page in
                NavItem(
                    page: page,
                    label: store.navigationLabel(for: page),
                    count: store.navigationCount(for: page)
                )
            }

            NavGroupTitle(store.copy.traceGroup)
                .padding(.top, 12)
            ForEach(tracePages) { page in
                NavItem(
                    page: page,
                    label: store.navigationLabel(for: page),
                    count: store.navigationCount(for: page)
                )
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(Theme.sidebar)
        .background {
            AppE2EViewAnchor(identifier: "shell.sidebar")
        }
    }
}

struct NavGroupTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.noonmarkSystem(size: 11.5, weight: .semibold))
            .foregroundStyle(Theme.text3)
            .tracking(0.4)
            .padding(.horizontal, 20)
            .padding(.bottom, 5)
    }
}

struct NavItem: View {
    @EnvironmentObject private var store: NoonmarkStore
    let page: NoonmarkStore.Page
    let label: String
    let count: Int

    var active: Bool { store.page == page }

    var body: some View {
        Button {
            store.selectPage(page)
        } label: {
            HStack(spacing: 10) {
                navigationIcon
                Text(label)
                    .font(.noonmarkSystem(size: 14.5, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? Theme.text1 : Theme.text2)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.noonmarkSystem(size: 12, weight: active ? .semibold : .regular))
                        .foregroundStyle(Theme.text2)
                        .padding(.horizontal, 7)
                        .frame(minWidth: 21, minHeight: 18)
                        .background(Capsule().fill(Theme.chip))
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 12)
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
        .padding(.horizontal, 9)
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
