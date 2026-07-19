import AppKit
import Foundation

/// Restores the global left-button state after an externally terminated E2E
/// gesture. This runs before Store construction: emergency input recovery must
/// not depend on a data-root lease, schema initialization, or fixture seeding.
/// The stable E2E bundle owns event-posting permission; shell helpers
/// deliberately do not assume that Terminal or an ad-hoc process does.
@MainActor
struct WindowServerInputCleanupE2EAutomation {
    private enum Failure: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message):
                message
            }
        }
    }

    private let resultURL: URL

    static func fromCommandLine() -> Self? {
        guard AppLaunchArguments.permitsInternalArguments,
              let path = AppLaunchArguments.value(
                  after: "--e2e-windowserver-input-cleanup-result-url"
              )
        else {
            return nil
        }
        return Self(resultURL: URL(fileURLWithPath: path))
    }

    func run() {
        Task { @MainActor in
            do {
                let input = try WindowServerInputDriver()
                try await releaseLeftButtonIfNeeded(input)
                try writeResult("ok")
            } catch {
                try? writeResult("failed: \(error.localizedDescription)")
            }
            E2EApplicationTermination.schedule()
        }
    }

    private func releaseLeftButtonIfNeeded(
        _ input: WindowServerInputDriver
    ) async throws {
        guard input.isLeftButtonDown else { return }
        guard let point = input.currentPointerLocation else {
            throw Failure.failed(
                "WindowServer pointer location was unavailable during cleanup"
            )
        }
        let gestureNumber = input.nextMouseGestureNumber()
        for attempt in 0 ..< 60 {
            if input.isLeftButtonDown == false { return }
            if attempt.isMultiple(of: 10) {
                try input.postMouse(
                    type: .leftMouseUp,
                    at: point,
                    gestureNumber: gestureNumber,
                    pressure: 0
                )
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure.failed(
            "WindowServer left button remained down after signed-App cleanup"
        )
    }

    private func writeResult(_ result: String) throws {
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.write(
            to: resultURL,
            atomically: true,
            encoding: .utf8
        )
    }
}
