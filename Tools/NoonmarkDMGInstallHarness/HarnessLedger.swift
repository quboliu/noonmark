import Darwin
import Foundation

final class HarnessLedger {
    private static let maximumBoundLedgerBytes: off_t = 4 * 1024 * 1024

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
    private let boundFile: DescriptorBoundFile?
    private let closesHandle: Bool
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
           FileManager.default.createFile(atPath: url.path, contents: nil) == false {
            throw Failure.cannotOpen(url)
        }
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw Failure.cannotOpen(url)
        }
        try handle.seekToEnd()
        self.handle = handle
        boundFile = nil
        closesHandle = true
    }

    init(
        directory: DescriptorBoundDirectory,
        fileName: String,
        requireNew: Bool = false
    ) throws {
        let opened = try directory.createOrOpenFile(
            named: fileName,
            mode: mode_t(S_IRUSR | S_IWUSR)
        )
        guard requireNew == false || opened.created else {
            throw DescriptorBoundDirectory.contract(
                "descriptor-bound ledger already existed"
            )
        }
        let file = opened.file
        let initialIdentity = try file.identity()
        if opened.created {
            guard initialIdentity.st_size == 0 else {
                throw DescriptorBoundDirectory.contract(
                    "new descriptor-bound ledger is not empty"
                )
            }
            guard fchmod(
                file.descriptor,
                mode_t(S_IRUSR | S_IWUSR)
            ) == 0 else {
                throw DescriptorBoundDirectory.posixFailure(
                    "set new descriptor-bound ledger permissions",
                    code: errno
                )
            }
        }
        let identity = try file.identity()
        try Self.validateBoundLedger(identity)
        try file.validateNameStillBound(to: identity)
        try directory.validatePathBinding()

        let handle = FileHandle(
            fileDescriptor: file.descriptor,
            closeOnDealloc: false
        )
        try handle.seekToEnd()
        self.handle = handle
        boundFile = file
        closesHandle = false
    }

    deinit {
        if closesHandle {
            try? handle.close()
        }
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
        if let boundFile {
            let before = try boundFile.identity()
            try Self.validateBoundLedger(before)
            guard before.st_size <= Self.maximumBoundLedgerBytes - off_t(data.count)
            else {
                throw DescriptorBoundDirectory.contract(
                    "descriptor-bound ledger reached its four-megabyte cap"
                )
            }
            try boundFile.validateNameStillBound(to: before)
            let end = try handle.seekToEnd()
            guard end == UInt64(before.st_size) else {
                throw DescriptorBoundDirectory.contract(
                    "descriptor-bound ledger changed before append"
                )
            }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            let after = try boundFile.identity()
            try Self.validateBoundLedger(after)
            guard DescriptorBoundFile.sameObject(before, after),
                  after.st_size == before.st_size + off_t(data.count)
            else {
                throw DescriptorBoundDirectory.contract(
                    "descriptor-bound ledger changed during append"
                )
            }
            try boundFile.validateNameStillBound(to: after)
        } else {
            try handle.write(contentsOf: data)
            try handle.synchronize()
        }
        FileHandle.standardOutput.write(data)
    }

    private static func validateBoundLedger(_ status: stat) throws {
        guard status.st_size >= 0,
              status.st_size <= maximumBoundLedgerBytes,
              status.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO)
              == (S_IRUSR | S_IWUSR)
        else {
            throw DescriptorBoundDirectory.contract(
                "descriptor-bound ledger is not a bounded owner-only file"
            )
        }
    }

    private static func singleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }
}
