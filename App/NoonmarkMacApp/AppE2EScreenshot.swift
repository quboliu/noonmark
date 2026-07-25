import AppKit
import Foundation

enum AppE2EScreenshot {
    enum CaptureError: LocalizedError {
        case contentViewUnavailable
        case bufferUnavailable
        case encodingFailed
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .contentViewUnavailable:
                "App screenshot content view was unavailable"
            case .bufferUnavailable:
                "App screenshot buffer was unavailable"
            case .encodingFailed:
                "App screenshot encoding failed"
            case let .writeFailed(message):
                "App screenshot write failed: \(message)"
            }
        }
    }

    @MainActor
    static func captureContent(
        of window: NSWindow,
        to url: URL
    ) throws {
        guard let contentView = window.contentView else {
            throw CaptureError.contentViewUnavailable
        }
        try capture(contentView, to: url)
    }

    @MainActor
    static func capture(
        _ view: NSView,
        to url: URL
    ) throws {
        guard view.bounds.width > 0,
              view.bounds.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(
                  in: view.bounds
              )
        else {
            throw CaptureError.bufferUnavailable
        }
        view.window?.displayIfNeeded()
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(
            using: .png,
            properties: [:]
        ) else {
            throw CaptureError.encodingFailed
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            throw CaptureError.writeFailed(error.localizedDescription)
        }
    }
}
