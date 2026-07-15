import AppKit
import NoonmarkMacRuntime
import SwiftUI

/// A three-column AppKit split workspace with native draggable dividers and
/// automatic divider-position restoration.
struct NativeWorkspaceSplitView: NSViewControllerRepresentable {
    @ObservedObject var store: NoonmarkStore
    let stateRepository: WorkspaceStateRepository

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, stateRepository: stateRepository)
    }

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let controller = WorkspaceSplitViewController()
        controller.splitView.isVertical = true
        controller.splitView.dividerStyle = .thin
        if stateRepository.persistenceEnabled {
            controller.splitView.autosaveName = NoonmarkMainWindowState
                .splitViewAutosaveName
        }
        controller.splitView.identifier = NSUserInterfaceItemIdentifier(
            "shell.workspace-split"
        )
        controller.splitView.setAccessibilityIdentifier("shell.workspace-split")

        let sidebarController = NSHostingController(
            rootView: Sidebar()
                .environmentObject(store)
                .preferredColorScheme(.light)
        )
        let contentController = NSHostingController(
            rootView: MainSurface()
                .environmentObject(store)
                .preferredColorScheme(.light)
        )
        let detailController = NSHostingController(
            rootView: DetailRail()
                .environmentObject(store)
                .preferredColorScheme(.light)
                .background {
                    AppE2EViewAnchor(identifier: "shell.detail-rail")
                }
        )

        let sidebarItem = NSSplitViewItem(
            sidebarWithViewController: sidebarController
        )
        sidebarItem.canCollapse = true
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        sidebarItem.minimumThickness = CGFloat(WorkspaceGeometry.sidebarWidthRange.lowerBound)
        sidebarItem.maximumThickness = CGFloat(WorkspaceGeometry.sidebarWidthRange.upperBound)
        sidebarItem.preferredThicknessFraction = NSSplitViewItem.unspecifiedDimension
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 260)

        let contentItem = NSSplitViewItem(viewController: contentController)
        contentItem.canCollapse = false
        contentItem.minimumThickness = 440
        contentItem.holdingPriority = .defaultLow

        let detailItem = NSSplitViewItem(
            inspectorWithViewController: detailController
        )
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
        _ controller: NSSplitViewController,
        context: Context
    ) {
        context.coordinator.store = store
        context.coordinator.applyStoreState()
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var store: NoonmarkStore?
        private weak var controller: WorkspaceSplitViewController?
        private let stateRepository: WorkspaceStateRepository
        private let hadPersistedState: Bool
        private var needsInitialGeometryRestore = true
        private var isApplyingState = false

        init(
            store: NoonmarkStore,
            stateRepository: WorkspaceStateRepository
        ) {
            self.store = store
            self.stateRepository = stateRepository
            hadPersistedState = stateRepository.containsSavedState
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
            let shouldCollapseSidebar = !store.isSidebarExpanded
            let shouldCollapseDetail = !store.shouldShowDetailRail

            isApplyingState = true
            sidebarItem.isCollapsed = shouldCollapseSidebar
            detailItem.isCollapsed = shouldCollapseDetail
            isApplyingState = false

            if needsInitialGeometryRestore == false {
                saveExpansionState(store)
            }
        }

        @objc private func splitViewDidResizeNotification(_ note: Notification) {
            splitViewDidResize()
        }

        private func splitViewDidResize() {
            guard let store,
                  let controller,
                  controller.splitViewItems.count == 3,
                  isApplyingState == false,
                  needsInitialGeometryRestore == false
            else { return }
            let sidebarExpanded = !controller.splitViewItems[0].isCollapsed
            if store.isSidebarExpanded != sidebarExpanded {
                store.isSidebarExpanded = sidebarExpanded
            }
            if store.hasDetailRailContent {
                let detailExpanded = !controller.splitViewItems[2].isCollapsed
                if store.isDetailRailExpanded != detailExpanded {
                    store.isDetailRailExpanded = detailExpanded
                }
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
            if hadPersistedState == false {
                sidebarItem.isCollapsed = false
                detailItem.isCollapsed = false
                controller.view.layoutSubtreeIfNeeded()
                controller.splitView.setPosition(
                    CGFloat(WorkspaceGeometry.defaultSidebarWidth),
                    ofDividerAt: 0
                )
                controller.splitView.setPosition(
                    controller.splitView.bounds.width
                        - CGFloat(WorkspaceGeometry.defaultDetailWidth),
                    ofDividerAt: 1
                )
                controller.view.layoutSubtreeIfNeeded()
            }
            sidebarItem.isCollapsed = !store.isSidebarExpanded
            detailItem.isCollapsed = !store.shouldShowDetailRail
            controller.view.layoutSubtreeIfNeeded()
            isApplyingState = false
            saveExpansionState(store)
        }

        private func saveExpansionState(_ store: NoonmarkStore) {
            stateRepository.save(
                WorkspaceState(
                    sidebarExpanded: store.isSidebarExpanded,
                    detailExpanded: store.isDetailRailExpanded
                )
            )
        }
    }
}

@MainActor
final class WorkspaceSplitViewController: NSSplitViewController {
    var afterLayout: (() -> Void)?

    override func viewDidLayout() {
        super.viewDidLayout()
        afterLayout?()
    }
}
