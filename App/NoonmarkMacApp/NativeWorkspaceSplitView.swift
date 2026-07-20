import AppKit
import NoonmarkMacRuntime
import SwiftUI

/// A three-column AppKit split workspace with native draggable dividers and
/// one explicit persistence authority for divider restoration.
struct NativeWorkspaceSplitView: NSViewControllerRepresentable {
    @ObservedObject var store: NoonmarkStore
    let stateRepository: WorkspaceStateRepository

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, stateRepository: stateRepository)
    }

    func makeNSViewController(context: Context) -> WorkspaceSplitViewController {
        let controller = WorkspaceSplitViewController()
        controller.splitView.isVertical = true
        controller.splitView.dividerStyle = .thin
        controller.splitView.identifier = NSUserInterfaceItemIdentifier(
            "shell.workspace-split"
        )
        controller.splitView.setAccessibilityIdentifier(
            "shell.workspace-split"
        )

        let sidebarController = NSHostingController(
            rootView: Sidebar()
                .environmentObject(store)
                .preferredColorScheme(.light)
        )
        let contentController = NSHostingController(
            rootView: MainSurface()
                .ignoresSafeArea(.container, edges: .top)
                .environmentObject(store)
                .preferredColorScheme(.light)
        )
        let detailController = NSHostingController(
            rootView: DetailRail()
                .ignoresSafeArea(.container, edges: .top)
                .environmentObject(store)
                .preferredColorScheme(.light)
                .background {
                    AppE2EViewAnchor(identifier: "shell.detail-rail")
                }
        )

        let sidebarItem = NSSplitViewItem(
            sidebarWithViewController: sidebarController
        )
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = CGFloat(WorkspaceGeometry.compactSidebarWidth)
        sidebarItem.maximumThickness = CGFloat(WorkspaceGeometry.sidebarWidthRange.upperBound)
        sidebarItem.preferredThicknessFraction = NSSplitViewItem.unspecifiedDimension
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 260)

        let contentItem = NSSplitViewItem(viewController: contentController)
        contentItem.canCollapse = false
        contentItem.minimumThickness = 440
        contentItem.holdingPriority = .defaultLow

        let detailItem = NSSplitViewItem(viewController: detailController)
        detailItem.canCollapse = true
        detailItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        detailItem.minimumThickness = CGFloat(WorkspaceGeometry.detailWidthRange.lowerBound)
        detailItem.maximumThickness = CGFloat(WorkspaceGeometry.detailWidthRange.upperBound)
        detailItem.preferredThicknessFraction = NSSplitViewItem.unspecifiedDimension
        detailItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 261)

        controller.addSplitViewItem(sidebarItem)
        controller.addSplitViewItem(contentItem)
        controller.addSplitViewItem(detailItem)
        context.coordinator.attach(to: controller)
        context.coordinator.applyStoreState()
        return controller
    }

    func updateNSViewController(
        _ controller: WorkspaceSplitViewController,
        context: Context
    ) {
        context.coordinator.store = store
        context.coordinator.applyStoreState()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsViewController: WorkspaceSplitViewController,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width,
              let height = proposal.height
        else { return nil }
        return CGSize(width: width, height: height)
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var store: NoonmarkStore?
        private weak var controller: WorkspaceSplitViewController?
        private let stateRepository: WorkspaceStateRepository
        private var usesCustomDetailWidth: Bool
        private var needsInitialGeometryRestore = true
        private var isApplyingState = false
        private var appliedAutomaticDetailWidth: CGFloat?
        private var pendingAutomaticDetailWidth: CGFloat?
        private var expandedSidebarWidth: CGFloat
        private var customDetailWidth: CGFloat

        init(
            store: NoonmarkStore,
            stateRepository: WorkspaceStateRepository
        ) {
            self.store = store
            self.stateRepository = stateRepository
            let persistedState = stateRepository.load()
            usesCustomDetailWidth = persistedState.usesCustomDetailWidth
            expandedSidebarWidth = Self.clampedExpandedSidebarWidth(
                persistedState.expandedSidebarWidth
            )
            customDetailWidth = Self.clampedCustomDetailWidth(
                persistedState.customDetailWidth
            )
            super.init()
        }

        func attach(to controller: WorkspaceSplitViewController) {
            self.controller = controller
            controller.afterLayout = { [weak self] in
                self?.restoreInitialGeometryIfNeeded()
            }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(splitViewDidResizeNotification(_:)),
                name: NSSplitView.didResizeSubviewsNotification,
                object: controller.splitView,
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func applyStoreState() {
            guard let store,
                  let controller,
                  controller.splitViewItems.count == 3
            else { return }

            let sidebarItem = controller.splitViewItems[0]
            let detailItem = controller.splitViewItems[2]
            let shouldCollapseDetail = !store.shouldShowDetailRail
            let automaticDetailWidth = store.page.detailRailWidth

            let automaticDetailWidthChanged = usesCustomDetailWidth == false
                && appliedAutomaticDetailWidth != automaticDetailWidth
            if automaticDetailWidthChanged {
                pendingAutomaticDetailWidth = automaticDetailWidth
            }

            isApplyingState = true
            applySidebarGeometry(
                sidebarItem: sidebarItem,
                expanded: store.isSidebarExpanded
            )
            detailItem.isCollapsed = shouldCollapseDetail
            let canApplyPendingDetailWidth = shouldCollapseDetail == false
                && needsInitialGeometryRestore == false
            let visibleDetailWidth: CGFloat? = if canApplyPendingDetailWidth {
                usesCustomDetailWidth
                    ? customDetailWidth
                    : pendingAutomaticDetailWidth
            } else {
                nil
            }
            if let visibleDetailWidth {
                controller.view.layoutSubtreeIfNeeded()
                applyDetailWidth(visibleDetailWidth)
                controller.view.layoutSubtreeIfNeeded()
                if usesCustomDetailWidth == false {
                    appliedAutomaticDetailWidth = visibleDetailWidth
                    pendingAutomaticDetailWidth = nil
                }
            }
            isApplyingState = false

            if needsInitialGeometryRestore == false {
                saveExpansionState(store)
            }
        }

        @objc private func splitViewDidResizeNotification(_ note: Notification) {
            splitViewDidResize(note)
        }

        private func splitViewDidResize(_ notification: Notification) {
            guard let store,
                  let controller,
                  controller.splitViewItems.count == 3,
                  isApplyingState == false,
                  needsInitialGeometryRestore == false
            else { return }
            if NSApp.currentEvent?.type == .leftMouseDragged {
                WorkspaceDragE2EDiagnostics.recordWorkspaceWidth(
                    controller.splitView.bounds.width
                )
            }
            let capturesSidebarWidth = store.isSidebarExpanded
                && isUserDraggingDivider(notification, at: 0)
            if capturesSidebarWidth {
                let sidebarWidth = controller.splitViewItems[0]
                    .viewController.view.frame.width
                if WorkspaceGeometry.sidebarWidthRange.contains(
                    Double(sidebarWidth)
                ) {
                    expandedSidebarWidth = Self.clampedExpandedSidebarWidth(
                        Double(sidebarWidth)
                    )
                }
            }
            if store.hasDetailRailContent {
                let detailExpanded = !controller.splitViewItems[2].isCollapsed
                if store.isDetailRailExpanded != detailExpanded {
                    store.isDetailRailExpanded = detailExpanded
                }
            }
            if isUserDraggingDivider(notification, at: 1) {
                usesCustomDetailWidth = true
                let detailWidth = controller.splitViewItems[2]
                    .viewController.view.frame.width
                if WorkspaceGeometry.detailWidthRange.contains(
                    Double(detailWidth)
                ) {
                    customDetailWidth = Self.clampedCustomDetailWidth(
                        Double(detailWidth)
                    )
                }
                appliedAutomaticDetailWidth = nil
                pendingAutomaticDetailWidth = nil
            }
            saveExpansionState(store)
        }

        private func restoreInitialGeometryIfNeeded() {
            guard needsInitialGeometryRestore,
                  let store,
                  let controller,
                  controller.splitViewItems.count == 3,
                  controller.splitView.bounds.width > 0
            else { return }
            needsInitialGeometryRestore = false

            isApplyingState = true
            let sidebarItem = controller.splitViewItems[0]
            let detailItem = controller.splitViewItems[2]
            let automaticDetailWidth = store.page.detailRailWidth
            sidebarItem.isCollapsed = false
            if store.isSidebarExpanded {
                controller.view.layoutSubtreeIfNeeded()
                controller.splitView.setPosition(
                    expandedSidebarWidth,
                    ofDividerAt: 0
                )
                controller.view.layoutSubtreeIfNeeded()
            }
            detailItem.isCollapsed = false
            controller.view.layoutSubtreeIfNeeded()
            let restoredDetailWidth = usesCustomDetailWidth
                ? customDetailWidth
                : automaticDetailWidth
            applyDetailWidth(restoredDetailWidth)
            if usesCustomDetailWidth == false {
                appliedAutomaticDetailWidth = automaticDetailWidth
            }
            controller.view.layoutSubtreeIfNeeded()
            applySidebarGeometry(
                sidebarItem: sidebarItem,
                expanded: store.isSidebarExpanded
            )
            detailItem.isCollapsed = !store.shouldShowDetailRail
            controller.view.layoutSubtreeIfNeeded()
            pendingAutomaticDetailWidth = nil
            isApplyingState = false
            saveExpansionState(store)
        }

        private func applyDetailWidth(_ width: CGFloat) {
            guard let controller,
                  controller.splitView.bounds.width > 0
            else { return }
            controller.splitView.setPosition(
                controller.splitView.bounds.maxX
                    - width
                    - controller.splitView.dividerThickness,
                ofDividerAt: 1
            )
        }

        private func applySidebarGeometry(
            sidebarItem: NSSplitViewItem,
            expanded: Bool
        ) {
            guard let controller else { return }
            sidebarItem.isCollapsed = false

            let compactWidth = CGFloat(WorkspaceGeometry.compactSidebarWidth)
            let expandedRange = WorkspaceGeometry.sidebarWidthRange
            if expanded {
                sidebarItem.maximumThickness = CGFloat(expandedRange.upperBound)
                sidebarItem.minimumThickness = compactWidth
                let needsExpandedWidth = sidebarItem.viewController.view.frame.width
                    < CGFloat(expandedRange.lowerBound)
                if controller.splitView.bounds.width > 0, needsExpandedWidth {
                    controller.splitView.setPosition(
                        expandedSidebarWidth,
                        ofDividerAt: 0
                    )
                    controller.view.layoutSubtreeIfNeeded()
                }
                sidebarItem.minimumThickness = CGFloat(expandedRange.lowerBound)
            } else {
                let currentWidth = sidebarItem.viewController.view.frame.width
                sidebarItem.minimumThickness = compactWidth
                sidebarItem.maximumThickness = CGFloat(expandedRange.upperBound)
                let needsCompactWidth = abs(currentWidth - compactWidth) > 0.5
                if controller.splitView.bounds.width > 0, needsCompactWidth {
                    controller.splitView.setPosition(
                        compactWidth,
                        ofDividerAt: 0
                    )
                    controller.view.layoutSubtreeIfNeeded()
                }
                sidebarItem.maximumThickness = compactWidth
            }
        }

        private static func clampedExpandedSidebarWidth(
            _ width: Double
        ) -> CGFloat {
            CGFloat(
                min(
                    max(width, WorkspaceGeometry.sidebarWidthRange.lowerBound),
                    WorkspaceGeometry.sidebarWidthRange.upperBound
                )
            )
        }

        private static func clampedCustomDetailWidth(
            _ width: Double
        ) -> CGFloat {
            CGFloat(
                min(
                    max(width, WorkspaceGeometry.detailWidthRange.lowerBound),
                    WorkspaceGeometry.detailWidthRange.upperBound
                )
            )
        }

        private func isUserDraggingDivider(
            _ notification: Notification,
            at expectedIndex: Int
        ) -> Bool {
            guard let dividerIndex = notification.userInfo?[
                "NSSplitViewDividerIndex"
            ] as? NSNumber else {
                return false
            }
            return dividerIndex.intValue == expectedIndex
                && NSApp.currentEvent?.type == .leftMouseDragged
        }

        private func saveExpansionState(_ store: NoonmarkStore) {
            stateRepository.save(
                WorkspaceState(
                    sidebarExpanded: store.isSidebarExpanded,
                    detailExpanded: store.isDetailRailExpanded,
                    usesCustomDetailWidth: usesCustomDetailWidth,
                    expandedSidebarWidth: Double(expandedSidebarWidth),
                    customDetailWidth: Double(customDetailWidth)
                )
            )
        }
    }
}

@MainActor
final class WorkspaceSplitViewController: NSSplitViewController {
    var afterLayout: (() -> Void)?
    private var isAfterLayoutScheduled = false

    override func viewDidLayout() {
        super.viewDidLayout()
        guard isAfterLayoutScheduled == false else { return }
        isAfterLayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isAfterLayoutScheduled = false
            self.afterLayout?()
        }
    }
}
