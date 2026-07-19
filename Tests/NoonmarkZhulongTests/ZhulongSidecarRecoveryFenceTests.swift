import Foundation
@testable import NoonmarkZhulong
import XCTest

final class ZhulongSidecarRecoveryFenceTests: XCTestCase {
    func testCanonicalPathKeepsFenceAcrossTransientInodeResolutionFailure() throws {
        let directoryURL = URL(fileURLWithPath: "/virtual/sidecar")
        var inode: ZhulongSidecarDirectoryIdentity?
        let fence = ZhulongSidecarRecoveryFence { _ in
            ZhulongSidecarDirectoryIdentities(
                canonicalPath: "/canonical/sidecar",
                inode: inode
            )
        }
        let record = recoveryRecord(byte: 0x11)

        fence.activate(record, for: directoryURL)
        inode = .inode(device: 7, node: 41)

        XCTAssertTrue(fence.isActive(for: directoryURL))
        XCTAssertEqual(try fence.record(for: directoryURL), record)
        try fence.clear(for: directoryURL)
        XCTAssertFalse(fence.isActive(for: directoryURL))
    }

    func testCanonicalPathKeepsFenceAcrossSamePathDirectoryRecreation() throws {
        let directoryURL = URL(fileURLWithPath: "/virtual/sidecar")
        var inode = ZhulongSidecarDirectoryIdentity.inode(
            device: 7,
            node: 41
        )
        let fence = ZhulongSidecarRecoveryFence { _ in
            ZhulongSidecarDirectoryIdentities(
                canonicalPath: "/canonical/sidecar",
                inode: inode
            )
        }
        let record = recoveryRecord(byte: 0x22)
        fence.activate(record, for: directoryURL)

        inode = .inode(device: 7, node: 42)

        XCTAssertTrue(fence.isActive(for: directoryURL))
        XCTAssertEqual(try fence.record(for: directoryURL), record)
        try fence.clear(for: directoryURL)
        XCTAssertFalse(fence.isActive(for: directoryURL))
    }

    func testConflictingCanonicalAndInodeRecordsStayFailClosed() throws {
        let firstURL = URL(fileURLWithPath: "/virtual/first")
        let secondURL = URL(fileURLWithPath: "/virtual/second")
        let sharedInode = ZhulongSidecarDirectoryIdentity.inode(
            device: 7,
            node: 41
        )
        let fence = ZhulongSidecarRecoveryFence { url in
            ZhulongSidecarDirectoryIdentities(
                canonicalPath: url.path,
                inode: sharedInode
            )
        }
        fence.activate(recoveryRecord(byte: 0x31), for: firstURL)
        fence.activate(recoveryRecord(byte: 0x32), for: secondURL)

        XCTAssertTrue(fence.isActive(for: firstURL))
        XCTAssertTrue(fence.isActive(for: secondURL))
        XCTAssertThrowsError(try fence.record(for: firstURL))
        XCTAssertThrowsError(try fence.record(for: secondURL))
        XCTAssertThrowsError(try fence.clear(for: firstURL))
        XCTAssertThrowsError(try fence.clear(for: secondURL))
    }

    func testClearingOneDirectoryDoesNotClearDistinctDirectoryWithSameRecord() throws {
        let firstURL = URL(fileURLWithPath: "/virtual/first")
        let secondURL = URL(fileURLWithPath: "/virtual/second")
        let fence = ZhulongSidecarRecoveryFence { url in
            ZhulongSidecarDirectoryIdentities(
                canonicalPath: url.path
            )
        }
        let sharedRecord = recoveryRecord(byte: 0x41)
        fence.activate(sharedRecord, for: firstURL)
        fence.activate(sharedRecord, for: secondURL)

        try fence.clear(for: firstURL)

        XCTAssertFalse(fence.isActive(for: firstURL))
        XCTAssertTrue(fence.isActive(for: secondURL))
        XCTAssertEqual(try fence.record(for: secondURL), sharedRecord)
        try fence.clear(for: secondURL)
        XCTAssertFalse(fence.isActive(for: secondURL))
    }

    private func recoveryRecord(byte: UInt8) -> ZhulongJournalRecoveryFence {
        ZhulongJournalRecoveryFence(
            operation: .prepare,
            exactBytes: Data(repeating: byte, count: 8)
        )
    }
}
