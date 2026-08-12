import SwiftUI

@main
struct NoonmarkIOSApp: App {
    @StateObject private var store = IOSStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            IOSRootView()
                .environmentObject(store)
                .task {
                    await store.startDiagnostics()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .background else { return }
                    Task { await store.flushDiagnostics() }
                }
        }
    }
}
