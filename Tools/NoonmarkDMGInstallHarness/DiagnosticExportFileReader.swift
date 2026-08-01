import Darwin
import Foundation

/// Reads diagnostic artifacts from one scope-owned directory descriptor. The
/// absolute root and the final file are both traversed without following links.
final class DiagnosticExportFileReader {
    private let root: DescriptorBoundDirectory

    init(
        anchoredAtDirectoryPath path: String,
        afterDirectoryIdentityCapture: () throws -> Void = {}
    ) throws {
        root = try DescriptorBoundDirectory(
            path: CanonicalAbsolutePath(path),
            afterIdentityCapture: afterDirectoryIdentityCapture
        )
    }

    init(root: DescriptorBoundDirectory) {
        self.root = root
    }

    func read(
        atPath path: String,
        maximumByteCount: Int,
        requireOwnerOnlyPermissions: Bool,
        afterIdentityCapture: () throws -> Void = {}
    ) throws -> Data {
        guard let data = try readIfPresent(
            atPath: path,
            maximumByteCount: maximumByteCount,
            requireOwnerOnlyPermissions: requireOwnerOnlyPermissions,
            afterIdentityCapture: afterIdentityCapture
        ) else {
            throw DescriptorBoundDirectory.posixFailure(
                "open descriptor-bound diagnostic file",
                code: ENOENT
            )
        }
        return data
    }

    func readIfPresent(
        atPath path: String,
        maximumByteCount: Int,
        requireOwnerOnlyPermissions: Bool,
        afterIdentityCapture: () throws -> Void = {}
    ) throws -> Data? {
        guard maximumByteCount > 0 else {
            throw Self.contract("diagnostic file byte bound is invalid")
        }
        let filePath = try CanonicalAbsolutePath(path)
        guard filePath.parent == root.path,
              let fileName = filePath.lastComponent
        else {
            throw Self.contract(
                "diagnostic file is outside its descriptor-bound root"
            )
        }

        guard let file = try root.openExistingFileIfPresent(
            named: fileName,
            writable: false
        ) else { return nil }
        let before = try file.identity()
        try Self.validate(
            before,
            maximumByteCount: maximumByteCount,
            requireOwnerOnlyPermissions: requireOwnerOnlyPermissions
        )
        try afterIdentityCapture()

        let data = try Self.readBounded(
            descriptor: file.descriptor,
            expectedByteCount: Int(before.st_size),
            maximumByteCount: maximumByteCount
        )
        let after = try file.identity()
        guard DescriptorBoundFile.sameFile(before, after) else {
            throw Self.contract(
                "diagnostic file changed during its descriptor read"
            )
        }
        try Self.validate(
            after,
            maximumByteCount: maximumByteCount,
            requireOwnerOnlyPermissions: requireOwnerOnlyPermissions
        )
        try file.validateNameStillBound(to: after)
        try root.validatePathBinding()
        return data
    }

    private static func validate(
        _ status: stat,
        maximumByteCount: Int,
        requireOwnerOnlyPermissions: Bool
    ) throws {
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_size > 0,
              status.st_size <= off_t(maximumByteCount),
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_mode & S_IRUSR == S_IRUSR,
              status.st_mode & (S_IWGRP | S_IWOTH) == 0
        else {
            throw contract(
                "diagnostic file is not a bounded, owner-readable, non-writable-by-others regular file"
            )
        }
        if requireOwnerOnlyPermissions {
            guard status.st_mode & (S_IRWXG | S_IRWXO) == 0,
                  status.st_mode & (S_IRUSR | S_IWUSR)
                  == (S_IRUSR | S_IWUSR)
            else {
                throw contract(
                    "diagnostic file is not owner-readable/writable and group/other closed"
                )
            }
        }
    }

    private static func readBounded(
        descriptor: Int32,
        expectedByteCount: Int,
        maximumByteCount: Int
    ) throws -> Data {
        var data = Data()
        data.reserveCapacity(expectedByteCount)
        var buffer = [UInt8](
            repeating: 0,
            count: min(64 * 1024, maximumByteCount)
        )
        while true {
            let count: Int = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw DescriptorBoundDirectory.posixFailure(
                    "read descriptor-bound diagnostic file",
                    code: errno
                )
            }
            guard data.count <= maximumByteCount - count,
                  data.count <= expectedByteCount - count
            else {
                throw contract("diagnostic file exceeded its captured byte bound")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count == expectedByteCount else {
            throw contract("diagnostic file ended before its captured byte count")
        }
        return data
    }

    private static func contract(
        _ message: String
    ) -> NoonmarkDMGInstallHarness.HarnessFailure {
        .contract(message)
    }
}
