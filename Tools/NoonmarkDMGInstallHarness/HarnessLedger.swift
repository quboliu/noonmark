import Foundation

final class HarnessLedger {
    enum Failure: LocalizedError {
        case cannotCreateParent(URL)
        case cannotOpen(URL)

        var errorDescription: String? {
            switch self {
            case let .cannotCreateParent(url):
                "无法建立 harness ledger 目录：\(url.path)"
            case let .cannotOpen(url):
                "无法打开 harness ledger：\(url.path)"
            }
        }
    }

    private let handle: FileHandle
    private let formatter = ISO8601DateFormatter()

    init(path: String) throws {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
        } catch {
            throw Failure.cannotCreateParent(parent)
        }
        if FileManager.default.fileExists(atPath: url.path) == false,
           FileManager.default.createFile(atPath: url.path, contents: nil) == false
        {
            throw Failure.cannotOpen(url)
        }
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw Failure.cannotOpen(url)
        }
        try handle.seekToEnd()
        self.handle = handle
    }

    deinit {
        try? handle.close()
    }

    func pass(_ step: String, _ detail: String) throws {
        try append(status: "PASS", step: step, detail: detail)
    }

    func fail(_ step: String, _ detail: String) {
        try? append(status: "FAIL", step: step, detail: detail)
    }

    private func append(status: String, step: String, detail: String) throws {
        let cleanStep = Self.singleLine(step)
        let cleanDetail = Self.singleLine(detail)
        let line = "\(formatter.string(from: Date()))\t\(status)\t\(cleanStep)\t\(cleanDetail)\n"
        let data = Data(line.utf8)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        FileHandle.standardOutput.write(data)
    }

    private static func singleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }
}
