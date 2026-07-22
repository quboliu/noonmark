import AppKit
import Foundation
import NoonmarkMacUIContract

struct ZhulongTitleGeometryE2EAutomation: LaunchAutomationRunnable {
    let resultURL: URL

    @MainActor
    static func fromCommandLine() -> ZhulongTitleGeometryE2EAutomation? {
        guard AppLaunchArguments.contains("--e2e-zhulong-title-geometry"),
              let path = AppLaunchArguments.value(
                  after: "--e2e-zhulong-title-geometry-result-url"
              )
        else {
            return nil
        }
        return ZhulongTitleGeometryE2EAutomation(
            resultURL: URL(fileURLWithPath: path)
        )
    }

    @MainActor
    func run(on store: NoonmarkStore) {
        ZhulongTitleGeometryE2EDriver.start(
            store: store,
            resultURL: resultURL
        )
    }
}

@MainActor
private enum ZhulongTitleGeometryE2EDriver {
    private enum Surface: String, CaseIterable {
        case home
        case session

        var titleIdentifier: String {
            switch self {
            case .home:
                "zhulong.home.title"
            case .session:
                "zhulong.session.title"
            }
        }

        var subtitleIdentifier: String {
            switch self {
            case .home:
                "zhulong.home.subtitle"
            case .session:
                "zhulong.session.subtitle"
            }
        }

        var contentMaxWidth: CGFloat {
            switch self {
            case .home:
                CGFloat(MacUIZhulongHomeLayout.contentMaxWidth)
            case .session:
                CGFloat(MacUIZhulongConversationLayout.contentMaxWidth)
            }
        }
    }

    static func start(store: NoonmarkStore, resultURL: URL) {
        Session(store: store, resultURL: resultURL).start()
    }

    @MainActor
    private final class Session {
        private let store: NoonmarkStore
        private let resultURL: URL

        init(store: NoonmarkStore, resultURL: URL) {
            self.store = store
            self.resultURL = resultURL
        }

        func start(attemptsRemaining: Int = 80) {
            guard Bundle.main.bundleIdentifier == "app.noonmark.mac.e2e" else {
                finishFailure("title geometry verification crossed its E2E boundary")
                return
            }
            guard store.page == .zhulong,
                  let middle = AppViewTreeE2E.view(identifier: "shell.middle-pane")
            else {
                retry(attemptsRemaining) {
                    "Zhulong page or middle-pane geometry anchor was unavailable"
                }
                return
            }

            let expectedSurface: Surface = store.zhulongWorkspace.selectedSession == nil
                ? .home
                : .session
            let visibleTitles = Surface.allCases.compactMap { surface in
                AppViewTreeE2E.view(identifier: surface.titleIdentifier).map {
                    (surface: surface, view: $0)
                }
            }
            guard visibleTitles.count == 1,
                  visibleTitles[0].surface == expectedSurface
            else {
                retry(attemptsRemaining) {
                    let visible = visibleTitles.map { $0.surface.rawValue }
                        .joined(separator: ",")
                    return "expected one visible \(expectedSurface.rawValue) title; visible=\(visible)"
                }
                return
            }

            let title = visibleTitles[0].view
            guard let subtitle = AppViewTreeE2E.view(
                identifier: expectedSurface.subtitleIdentifier
            ) else {
                retry(attemptsRemaining) {
                    "visible \(expectedSurface.rawValue) subtitle geometry anchor was unavailable"
                }
                return
            }
            let expectedText = store.copy.navZhulong
            guard AppViewTreeE2E.verificationText(for: title) == expectedText else {
                finishFailure(
                    "visible title text did not match the current language",
                    evidence: [
                        "surface=\(expectedSurface.rawValue)",
                        "identifier=\(expectedSurface.titleIdentifier)",
                        "expected_text=\(expectedText)",
                        "actual_text=\(AppViewTreeE2E.verificationText(for: title) ?? "nil")"
                    ]
                )
                return
            }
            guard title.window === middle.window,
                  subtitle.window === middle.window
            else {
                finishFailure("title, subtitle and middle pane belonged to different windows")
                return
            }

            let titleFrame = AppViewTreeE2E.frameInWindow(for: title)
            let subtitleFrame = AppViewTreeE2E.frameInWindow(for: subtitle)
            let middleFrame = AppViewTreeE2E.frameInWindow(for: middle)
            guard titleFrame.width > 0,
                  titleFrame.height > 0,
                  subtitleFrame.width > 0,
                  subtitleFrame.height > 0,
                  middleFrame.width > 0,
                  middleFrame.height > 0
            else {
                retry(attemptsRemaining) {
                    "title or middle-pane geometry was empty"
                }
                return
            }

            let horizontalPadding = CGFloat(MacUIShellLayout.pageHorizontalPadding)
            let availableContentWidth = max(0, middleFrame.width - (horizontalPadding * 2))
            let contentWidth = min(expectedSurface.contentMaxWidth, availableContentWidth)
            let expectedMinX = middleFrame.midX - (contentWidth / 2)
            let titleDelta = abs(titleFrame.minX - expectedMinX)
            let subtitleDelta = abs(subtitleFrame.minX - expectedMinX)
            let delta = max(titleDelta, subtitleDelta)
            let evidence = [
                "surface=\(expectedSurface.rawValue)",
                "identifier=\(expectedSurface.titleIdentifier)",
                "expected_text=\(expectedText)",
                "title_frame=\(frameDescription(titleFrame))",
                "subtitle_frame=\(frameDescription(subtitleFrame))",
                "middle_frame=\(frameDescription(middleFrame))",
                "title_min_x=\(number(titleFrame.minX))",
                "subtitle_min_x=\(number(subtitleFrame.minX))",
                "expected_content_min_x=\(number(expectedMinX))",
                "title_min_x_delta=\(number(titleDelta))",
                "subtitle_min_x_delta=\(number(subtitleDelta))",
                "min_x_delta=\(number(delta))",
                "tolerance=1.000"
            ]
            guard delta <= 1 else {
                finishFailure(
                    "Zhulong title was not aligned with the readable content axis",
                    evidence: evidence
                )
                return
            }
            finish(["ok"] + evidence)
        }

        private func retry(
            _ attemptsRemaining: Int,
            failure: @escaping () -> String
        ) {
            guard attemptsRemaining > 1 else {
                finishFailure(failure())
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
                start(attemptsRemaining: attemptsRemaining - 1)
            }
        }

        private func finishFailure(
            _ message: String,
            evidence: [String] = []
        ) {
            AppViewTreeE2E.writeDump(beside: resultURL)
            finish(["failed: \(message)"] + evidence)
        }

        private func finish(_ lines: [String]) {
            do {
                try FileManager.default.createDirectory(
                    at: resultURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try lines.joined(separator: "\n").write(
                    to: resultURL,
                    atomically: true,
                    encoding: .utf8
                )
            } catch {
                NSLog(
                    "Noonmark Zhulong title geometry E2E result write failed: %@",
                    String(describing: error)
                )
            }
        }

        private func frameDescription(_ frame: NSRect) -> String {
            [
                "x:\(number(frame.minX))",
                "y:\(number(frame.minY))",
                "width:\(number(frame.width))",
                "height:\(number(frame.height))"
            ].joined(separator: ",")
        }

        private func number(_ value: CGFloat) -> String {
            String(format: "%.3f", Double(value))
        }
    }
}
