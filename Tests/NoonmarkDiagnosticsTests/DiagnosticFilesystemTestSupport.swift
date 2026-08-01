import Darwin
import Foundation
import XCTest

struct DiagnosticFileFingerprint: Equatable {
    let data: Data
    let device: dev_t
    let inode: ino_t
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let size: Int64

    init(at url: URL) throws {
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        data = try Data(contentsOf: url)
        device = information.st_dev
        inode = information.st_ino
        modificationSeconds = Int64(information.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(information.st_mtimespec.tv_nsec)
        size = Int64(information.st_size)
    }
}

func XCTAssertDiagnosticFileUnchanged(
    at url: URL,
    from expected: DiagnosticFileFingerprint,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    XCTAssertEqual(
        try DiagnosticFileFingerprint(at: url),
        expected,
        message(),
        file: file,
        line: line
    )
}

func createDiagnosticFIFO(at url: URL) throws {
    guard mkfifo(url.path, mode_t(0o600)) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
