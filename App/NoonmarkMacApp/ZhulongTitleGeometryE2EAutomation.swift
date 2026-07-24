import AppKit
import Foundation

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
            guard title.window === middle.window else {
                finishFailure("title and middle pane belonged to different windows")
                return
            }

            let titleFrame = AppViewTreeE2E.frameInWindow(for: title)
            let middleFrame = AppViewTreeE2E.frameInWindow(for: middle)
            guard titleFrame.width > 0,
                  titleFrame.height > 0,
                  middleFrame.width > 0,
                  middleFrame.height > 0
            else {
                retry(attemptsRemaining) {
                    "title or middle-pane geometry was empty"
                }
                return
            }

            let delta = abs(titleFrame.midX - middleFrame.midX)
            var evidence = [
                "surface=\(expectedSurface.rawValue)",
                "identifier=\(expectedSurface.titleIdentifier)",
                "expected_text=\(expectedText)",
                "title_frame=\(frameDescription(titleFrame))",
                "middle_frame=\(frameDescription(middleFrame))",
                "title_mid_x=\(number(titleFrame.midX))",
                "middle_mid_x=\(number(middleFrame.midX))",
                "mid_x_delta=\(number(delta))",
                "tolerance=1.000"
            ]
            guard delta <= 1 else {
                finishFailure(
                    "Zhulong title was not centered in the main surface",
                    evidence: evidence
                )
                return
            }
            if expectedSurface == .session {
                guard let history = AppViewTreeE2E.view(
                    identifier: "zhulong-session-show-home"
                ),
                let variant = AppViewTreeE2E.view(
                    identifier: "zhulong-stream-variant-menu"
                )
                else {
                    retry(attemptsRemaining) {
                        "responsive session-header controls were unavailable"
                    }
                    return
                }
                let historyFrame = AppViewTreeE2E.frameInWindow(
                    for: history
                )
                let variantFrame = AppViewTreeE2E.frameInWindow(
                    for: variant
                )
                let leadingGap = titleFrame.minX
                    - historyFrame.maxX
                let trailingGap = variantFrame.minX
                    - titleFrame.maxX
                evidence.append(
                    "detail_expanded=\(store.isDetailRailExpanded)"
                )
                evidence.append(
                    "history_frame=\(frameDescription(historyFrame))"
                )
                evidence.append(
                    "variant_frame=\(frameDescription(variantFrame))"
                )
                evidence.append(
                    "leading_title_gap=\(number(leadingGap))"
                )
                evidence.append(
                    "trailing_title_gap=\(number(trailingGap))"
                )
                guard leadingGap >= 8, trailingGap >= 8 else {
                    finishFailure(
                        "responsive session-header controls overlapped the centered title",
                        evidence: evidence
                    )
                    return
                }
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
