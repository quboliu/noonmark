import Darwin
import Foundation
@testable import NoonmarkCore
@testable import NoonmarkZhulong
import XCTest

final class ZhulongJournalFileCommitterTests: XCTestCase {
    func testPermissionFailureBeforeRenameIsCleanAndRemovesTemporaryFile() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        var operations = ZhulongJournalDarwinOperations.live
        let livePermissions = operations.setOwnerOnlyPermissions
        let liveSync = operations.syncDirectory
        var syncCount = 0
        operations.setOwnerOnlyPermissions = { descriptor in
            try livePermissions(descriptor)
            throw JournalFileFault.permissions
        }
        operations.syncDirectory = { descriptor in
            syncCount += 1
            try liveSync(descriptor)
        }
        let journal = fixture.journal(fileOperations: operations)

        let failure = try captureFailure {
            _ = try journal.save(fixture.application)
        }

        XCTAssertEqual(failure.disposition, .notCommitted)
        XCTAssertEqual(failure.failedPhase, .temporaryPermissions)
        XCTAssertNil(try journal.load())
        XCTAssertFalse(try fixture.hasTemporaryJournalFile())
        XCTAssertEqual(syncCount, 1)
    }

    func testLoadSweepsOnlyCanonicalSecureOrphanTemporaryFiles() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        let valid = fixture.temporaryJournalURL(uuidByte: "11")
        let wrongMode = fixture.temporaryJournalURL(uuidByte: "22")
        let symbolicLink = fixture.temporaryJournalURL(uuidByte: "33")
        let hardLink = fixture.temporaryJournalURL(uuidByte: "44")
        let directory = fixture.temporaryJournalURL(uuidByte: "55")
        let wrongName = fixture.directoryURL.appendingPathComponent(
            ".pending-application.zhj.not-a-uuid.tmp",
            isDirectory: false
        )
        let linkTarget = fixture.directoryURL.appendingPathComponent(
            "orphan-link-target",
            isDirectory: false
        )
        let hardLinkTarget = fixture.directoryURL.appendingPathComponent(
            "orphan-hard-link-target",
            isDirectory: false
        )
        try fixture.writeFile(valid, permissions: 0o600)
        try fixture.writeFile(wrongMode, permissions: 0o640)
        try fixture.writeFile(wrongName, permissions: 0o600)
        try fixture.writeFile(linkTarget, permissions: 0o600)
        try FileManager.default.createSymbolicLink(
            at: symbolicLink,
            withDestinationURL: linkTarget
        )
        try fixture.writeFile(hardLinkTarget, permissions: 0o600)
        try FileManager.default.linkItem(at: hardLinkTarget, to: hardLink)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var operations = ZhulongJournalDarwinOperations.live
        let liveSync = operations.syncDirectory
        var syncCount = 0
        operations.syncDirectory = { descriptor in
            syncCount += 1
            try liveSync(descriptor)
        }

        XCTAssertNil(
            try fixture.journal(fileOperations: operations).load()
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: valid.path))
        for retained in [
            wrongMode,
            symbolicLink,
            hardLink,
            directory,
            wrongName
        ] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: retained.path),
                retained.lastPathComponent
            )
        }
        XCTAssertEqual(syncCount, 1)
    }

    func testOrphanSweepReportsCleanupDurabilityFailure() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        let orphan = fixture.temporaryJournalURL(uuidByte: "66")
        try fixture.writeFile(orphan, permissions: 0o600)
        var operations = ZhulongJournalDarwinOperations.live
        var syncCount = 0
        operations.syncDirectory = { _ in
            syncCount += 1
            throw posixError(ENOTSUP)
        }

        let failure = try captureFailure {
            _ = try fixture.journal(fileOperations: operations).load()
        }

        XCTAssertEqual(failure.disposition, .unresolved)
        XCTAssertEqual(failure.failedPhase, .temporaryCleanup)
        XCTAssertEqual(syncCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertNil(try fixture.journal().load())
    }

    func testOrphanSweepSyncsEarlierRemovalBeforeLaterErrorEscapes() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        let firstOrphan = fixture.temporaryJournalURL(uuidByte: "77")
        let secondOrphan = fixture.temporaryJournalURL(uuidByte: "88")
        try fixture.writeFile(firstOrphan, permissions: 0o600)
        try fixture.writeFile(secondOrphan, permissions: 0o600)
        var operations = ZhulongJournalDarwinOperations.live
        let liveRemove = operations.removeSecureTemporaryFile
        let liveSync = operations.syncDirectory
        var removalCount = 0
        var syncCount = 0
        operations.removeSecureTemporaryFile = { url in
            removalCount += 1
            if removalCount == 2 {
                throw JournalFileFault.cleanup
            }
            return try liveRemove(url)
        }
        operations.syncDirectory = { descriptor in
            syncCount += 1
            try liveSync(descriptor)
        }

        let failure = try captureFailure {
            _ = try fixture.journal(fileOperations: operations).load()
        }

        XCTAssertEqual(removalCount, 2)
        XCTAssertEqual(syncCount, 1)
        XCTAssertEqual(failure.disposition, .unresolved)
        XCTAssertEqual(failure.failedPhase, .temporaryCleanup)
        XCTAssertEqual(
            failure.underlyingError as? JournalFileFault,
            .cleanup
        )
        XCTAssertEqual(
            [firstOrphan, secondOrphan].filter {
                FileManager.default.fileExists(atPath: $0.path)
            }.count,
            1
        )
    }

    func testOrphanSweepPreservesRemovalAndBothDirectorySyncErrors() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        let firstOrphan = fixture.temporaryJournalURL(uuidByte: "99")
        let secondOrphan = fixture.temporaryJournalURL(uuidByte: "AA")
        try fixture.writeFile(firstOrphan, permissions: 0o600)
        try fixture.writeFile(secondOrphan, permissions: 0o600)
        var operations = ZhulongJournalDarwinOperations.live
        let liveRemove = operations.removeSecureTemporaryFile
        var removalCount = 0
        var syncCount = 0
        operations.removeSecureTemporaryFile = { url in
            removalCount += 1
            if removalCount == 2 {
                throw JournalFileFault.cleanup
            }
            return try liveRemove(url)
        }
        operations.syncDirectory = { _ in
            syncCount += 1
            throw posixError(syncCount == 1 ? ENOTSUP : EIO)
        }

        let failure = try captureFailure {
            _ = try fixture.journal(fileOperations: operations).load()
        }

        XCTAssertEqual(removalCount, 2)
        XCTAssertEqual(syncCount, 2)
        XCTAssertEqual(failure.disposition, .unresolved)
        XCTAssertEqual(failure.failedPhase, .temporaryCleanup)
        XCTAssertEqual(
            failure.underlyingError as? JournalFileFault,
            .cleanup
        )
        XCTAssertEqual(
            (failure.durabilityError as? NSError)?.code,
            Int(ENOTSUP)
        )
        XCTAssertEqual(
            (failure.retryError as? NSError)?.code,
            Int(EIO)
        )
    }

    func testTemporaryFileMetadataGuardRejectsEveryUnsafeDimension() {
        var status = stat()
        status.st_mode = mode_t(S_IFREG) | mode_t(0o600)
        status.st_nlink = 1
        status.st_uid = 501

        XCTAssertTrue(
            ZhulongJournalDarwinOperations.isSecureTemporaryFileStatus(
                status,
                effectiveUserID: 501
            )
        )

        status.st_mode = mode_t(S_IFDIR) | mode_t(0o600)
        XCTAssertFalse(
            ZhulongJournalDarwinOperations.isSecureTemporaryFileStatus(
                status,
                effectiveUserID: 501
            )
        )
        status.st_mode = mode_t(S_IFREG) | mode_t(0o600)
        status.st_nlink = 2
        XCTAssertFalse(
            ZhulongJournalDarwinOperations.isSecureTemporaryFileStatus(
                status,
                effectiveUserID: 501
            )
        )
        status.st_nlink = 1
        status.st_uid = 502
        XCTAssertFalse(
            ZhulongJournalDarwinOperations.isSecureTemporaryFileStatus(
                status,
                effectiveUserID: 501
            )
        )
        status.st_uid = 501
        status.st_mode = mode_t(S_IFREG) | mode_t(0o640)
        XCTAssertFalse(
            ZhulongJournalDarwinOperations.isSecureTemporaryFileStatus(
                status,
                effectiveUserID: 501
            )
        )
    }

    func testRenameErrorBeforeEffectIsCleanAndRemovesTemporaryFile() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        var operations = ZhulongJournalDarwinOperations.live
        operations.renameExclusive = { _, _ in
            throw JournalFileFault.rename
        }
        let journal = fixture.journal(fileOperations: operations)

        let failure = try captureFailure {
            _ = try journal.save(fixture.application)
        }

        XCTAssertEqual(failure.disposition, .notCommitted)
        XCTAssertEqual(failure.failedPhase, .replacement)
        XCTAssertNil(try journal.load())
        XCTAssertFalse(try fixture.hasTemporaryJournalFile())
    }

    func testRenameErrorWithAbsentDestinationAndPersistentDirectorySyncStaysUnresolved() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        var operations = ZhulongJournalDarwinOperations.live
        let liveRename = operations.renameExclusive
        var syncCount = 0
        operations.renameExclusive = { source, destination in
            try liveRename(source, destination)
            try FileManager.default.removeItem(at: destination)
            throw JournalFileFault.rename
        }
        operations.syncDirectory = { _ in
            syncCount += 1
            throw posixError(ENOTSUP)
        }
        let journal = fixture.journal(fileOperations: operations)

        let failure = try captureFailure {
            _ = try journal.save(fixture.application)
        }

        XCTAssertEqual(failure.disposition, .unresolved)
        XCTAssertEqual(failure.failedPhase, .replacement)
        XCTAssertEqual(syncCount, 2)
        XCTAssertThrowsError(try journal.load())
        XCTAssertThrowsError(
            try fixture.sessionRepository.save(
                fixture.makeUnrelatedSession()
            )
        )
    }

    func testRenameErrorWithAbsentDestinationAndSuccessfulDirectorySyncIsNotCommitted() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        var operations = ZhulongJournalDarwinOperations.live
        let liveRename = operations.renameExclusive
        let liveSync = operations.syncDirectory
        var syncCount = 0
        operations.renameExclusive = { source, destination in
            try liveRename(source, destination)
            try FileManager.default.removeItem(at: destination)
            throw JournalFileFault.rename
        }
        operations.syncDirectory = { descriptor in
            syncCount += 1
            try liveSync(descriptor)
        }
        let journal = fixture.journal(fileOperations: operations)

        let failure = try captureFailure {
            _ = try journal.save(fixture.application)
        }

        XCTAssertEqual(failure.disposition, .notCommitted)
        XCTAssertEqual(failure.failedPhase, .replacement)
        XCTAssertEqual(syncCount, 1)
        XCTAssertNil(try journal.load())
        try fixture.sessionRepository.save(
            fixture.makeUnrelatedSession()
        )
    }

    func testRenameSuccessThenWrongBytesIsUnresolvedAndKeepsGateClosed() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        var operations = ZhulongJournalDarwinOperations.live
        let liveRename = operations.renameExclusive
        operations.renameExclusive = { source, destination in
            try liveRename(source, destination)
            try Data([0x00, 0x01]).write(to: destination)
            throw JournalFileFault.rename
        }
        let journal = fixture.journal(fileOperations: operations)

        let failure = try captureFailure {
            _ = try journal.save(fixture.application)
        }

        XCTAssertEqual(failure.disposition, .unresolved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.fileURL.path))
        XCTAssertThrowsError(
            try fixture.sessionRepository.save(
                fixture.makeUnrelatedSession()
            )
        ) { error in
            XCTAssertEqual(
                error as? ZhulongPendingApplicationRecoveryError,
                .applicationAlreadyPending
            )
        }
    }

    func testSuccessfulRenameThatLeavesWrongBytesFailsFinalObservation() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        var operations = ZhulongJournalDarwinOperations.live
        let liveRename = operations.renameExclusive
        operations.renameExclusive = { source, destination in
            try liveRename(source, destination)
            try Data([0x02, 0x03]).write(to: destination)
        }
        let journal = fixture.journal(fileOperations: operations)

        let failure = try captureFailure {
            _ = try journal.save(fixture.application)
        }

        XCTAssertEqual(failure.disposition, .unresolved)
        XCTAssertEqual(failure.failedPhase, .observation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.fileURL.path))
    }

    func testRenameSuccessThenUnreadableDestinationIsUnresolvedAndKeepsGateClosed() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        var operations = ZhulongJournalDarwinOperations.live
        let liveRename = operations.renameExclusive
        operations.renameExclusive = { source, destination in
            try liveRename(source, destination)
            throw JournalFileFault.rename
        }
        operations.readFile = { _ in
            throw JournalFileFault.read
        }
        let journal = fixture.journal(fileOperations: operations)

        let failure = try captureFailure {
            _ = try journal.save(fixture.application)
        }

        XCTAssertEqual(failure.disposition, .unresolved)
        XCTAssertNotNil(failure.reconciliationError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.fileURL.path))
        XCTAssertThrowsError(
            try fixture.sessionRepository.save(
                fixture.makeUnrelatedSession()
            )
        )
    }

    func testRenameReportedErrorWithExactDestinationAndPersistentDirectorySyncIsUnresolved() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        var operations = ZhulongJournalDarwinOperations.live
        let liveRename = operations.renameExclusive
        var syncCount = 0
        operations.renameExclusive = { source, destination in
            try liveRename(source, destination)
            throw JournalFileFault.rename
        }
        operations.syncDirectory = { _ in
            syncCount += 1
            throw posixError(ENOTSUP)
        }
        let journal = fixture.journal(fileOperations: operations)

        let failure = try captureFailure {
            _ = try journal.save(fixture.application)
        }

        XCTAssertEqual(failure.disposition, .unresolved)
        XCTAssertEqual(failure.failedPhase, .replacement)
        XCTAssertEqual(syncCount, 2)
        XCTAssertThrowsError(try journal.load())
        XCTAssertThrowsError(
            try fixture.sessionRepository.save(
                fixture.makeUnrelatedSession()
            )
        )
        XCTAssertEqual(try fixture.journal().load(), fixture.application)
    }

    func testPersistentPrepareDirectorySyncWithAbsentFinalStateLatchesWriteGate() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        var operations = ZhulongJournalDarwinOperations.live
        let liveRename = operations.renameExclusive
        var installedURL: URL?
        var syncCount = 0
        operations.renameExclusive = { source, destination in
            try liveRename(source, destination)
            installedURL = destination
        }
        operations.syncDirectory = { _ in
            syncCount += 1
            if syncCount == 1, let installedURL {
                try FileManager.default.removeItem(at: installedURL)
            }
            throw posixError(ENOTSUP)
        }
        let journal = fixture.journal(fileOperations: operations)

        let failure = try captureFailure {
            _ = try journal.save(fixture.application)
        }

        XCTAssertEqual(failure.disposition, .unresolved)
        XCTAssertEqual(failure.failedPhase, .directorySync)
        XCTAssertEqual(syncCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.fileURL.path))
        XCTAssertThrowsError(try journal.load())
        XCTAssertThrowsError(
            try fixture.sessionRepository.save(
                fixture.makeUnrelatedSession()
            )
        )
    }

    func testDirectorySyncFirstErrorThenRetrySuccessReturnsRecoveredCommitted() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        var operations = ZhulongJournalDarwinOperations.live
        let liveSync = operations.syncDirectory
        var syncCount = 0
        operations.syncDirectory = { descriptor in
            syncCount += 1
            try liveSync(descriptor)
            if syncCount == 1 {
                throw JournalFileFault.sync
            }
        }
        let journal = fixture.journal(fileOperations: operations)

        let outcome = try journal.save(fixture.application)

        XCTAssertEqual(
            outcome,
            .recoveredCommitted(after: .directorySync)
        )
        XCTAssertEqual(syncCount, 2)
        XCTAssertEqual(try journal.load(), fixture.application)
    }

    func testDirectoryCloseEINTRAfterRenameReturnsRecoveredCommittedWithoutCloseRetry() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        var operations = ZhulongJournalDarwinOperations.live
        let liveClose = operations.closeDescriptor
        var closeCount = 0
        operations.closeDescriptor = { descriptor in
            closeCount += 1
            try liveClose(descriptor)
            if closeCount == 2 {
                throw posixError(EINTR)
            }
        }
        let journal = fixture.journal(fileOperations: operations)

        let outcome = try journal.save(fixture.application)

        XCTAssertEqual(
            outcome,
            .recoveredCommitted(after: .directoryClose)
        )
        XCTAssertEqual(try journal.load(), fixture.application)
    }

    func testDirectoryCloseEIORequiresFreshSyncAndPersistentFailureStaysUnresolved() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        var operations = ZhulongJournalDarwinOperations.live
        let liveClose = operations.closeDescriptor
        let liveSync = operations.syncDirectory
        var closeCount = 0
        var syncCount = 0
        operations.closeDescriptor = { descriptor in
            closeCount += 1
            try liveClose(descriptor)
            if closeCount == 2 {
                throw posixError(EIO)
            }
        }
        operations.syncDirectory = { descriptor in
            syncCount += 1
            if syncCount == 1 {
                try liveSync(descriptor)
            } else {
                throw posixError(ENOTSUP)
            }
        }
        let journal = fixture.journal(fileOperations: operations)

        let failure = try captureFailure {
            _ = try journal.save(fixture.application)
        }

        XCTAssertEqual(failure.disposition, .unresolved)
        XCTAssertEqual(failure.failedPhase, .directoryClose)
        XCTAssertEqual(syncCount, 3)
        XCTAssertEqual(try fixture.journal().load(), fixture.application)
        XCTAssertThrowsError(
            try fixture.sessionRepository.save(
                fixture.makeUnrelatedSession()
            )
        )
    }

    func testDirectoryCloseCleanupErrorDoesNotReplaceSyncFailurePhase() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        let recorder = JournalMonitoringRecorder()
        var operations = ZhulongJournalDarwinOperations.live
        let liveClose = operations.closeDescriptor
        var closeCount = 0
        operations.syncDirectory = { _ in
            throw JournalFileFault.sync
        }
        operations.closeDescriptor = { descriptor in
            closeCount += 1
            try liveClose(descriptor)
            if closeCount == 2 {
                throw JournalFileFault.close
            }
        }
        let journal = fixture.journal(
            fileOperations: operations,
            monitor: recorder.record
        )

        let failure = try captureFailure {
            _ = try journal.save(fixture.application)
        }

        XCTAssertEqual(failure.disposition, .unresolved)
        XCTAssertEqual(failure.failedPhase, .directorySync)
        XCTAssertTrue(
            recorder.events.contains {
                $0.phase == .directoryClose
                    && $0.resolution == .cleanupFailure
            }
        )
    }

    func testUnsupportedFullSyncFallsBackToFsyncAndRecordsGuaranteeLevel() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        let recorder = JournalMonitoringRecorder()
        var operations = ZhulongJournalDarwinOperations.live
        let liveSync = operations.syncFile
        var fallbackSyncCount = 0
        operations.fullSyncFile = { _ in
            throw posixError(ENOTSUP)
        }
        operations.syncFile = { descriptor in
            fallbackSyncCount += 1
            try liveSync(descriptor)
        }
        let journal = fixture.journal(
            fileOperations: operations,
            monitor: recorder.record
        )

        let outcome = try journal.save(fixture.application)

        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(fallbackSyncCount, 1)
        XCTAssertTrue(
            recorder.events.contains {
                $0.operation == .prepare
                    && $0.phase == .temporaryFileSync
                    && $0.resolution == .fileSyncFallback
                    && $0.errorKind == .posix
                    && $0.errorCode == Int(ENOTSUP)
            }
        )
    }

    func testFallbackFsyncFailureIsCleanAndDoesNotInstallJournal() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        var operations = ZhulongJournalDarwinOperations.live
        operations.fullSyncFile = { _ in
            throw posixError(ENOTSUP)
        }
        operations.syncFile = { _ in
            throw posixError(EIO)
        }
        let journal = fixture.journal(fileOperations: operations)

        let failure = try captureFailure {
            _ = try journal.save(fixture.application)
        }

        XCTAssertEqual(failure.disposition, .notCommitted)
        XCTAssertEqual(failure.failedPhase, .temporaryFileSync)
        XCTAssertNil(try journal.load())
    }

    func testPersistentUnsupportedDirectorySyncIsUnresolvedAndKeepsGateClosed() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        let recorder = JournalMonitoringRecorder()
        var operations = ZhulongJournalDarwinOperations.live
        operations.syncDirectory = { _ in
            throw posixError(ENOTSUP)
        }
        let journal = fixture.journal(
            fileOperations: operations,
            monitor: recorder.record
        )

        let failure = try captureFailure {
            _ = try journal.save(fixture.application)
        }

        XCTAssertEqual(failure.disposition, .unresolved)
        XCTAssertEqual(failure.failedPhase, .directorySync)
        let retryError = try XCTUnwrap(failure.retryError as? NSError)
        XCTAssertEqual(retryError.code, Int(ENOTSUP))
        XCTAssertThrowsError(try journal.load())
        XCTAssertThrowsError(
            try fixture.sessionRepository.save(
                fixture.makeUnrelatedSession()
            )
        )
        XCTAssertEqual(try fixture.journal().load(), fixture.application)
        XCTAssertTrue(
            recorder.events.contains {
                $0.phase == .directorySync
                    && $0.resolution == .unresolved
                    && $0.errorCode == Int(ENOTSUP)
            }
        )
    }

    func testExactPrepareFenceMustResolveBeforeEnginePersistenceCanStart() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        var operations = ZhulongJournalDarwinOperations.live
        operations.syncDirectory = { _ in
            throw posixError(ENOTSUP)
        }
        let faultJournal = fixture.journal(fileOperations: operations)
        _ = try captureFailure {
            _ = try faultJournal.save(fixture.application)
        }
        var enginePersistCount = 0

        do {
            guard try faultJournal.load() != nil else {
                XCTFail("exact pending must remain visible")
                return
            }
            _ = ZhulongApplicationCommitCoordinator.finish(
                engineAlreadyPersisted: false,
                persistEngine: { enginePersistCount += 1 },
                persistSession: {},
                clearJournal: { _ in .committed }
            )
        } catch {
            // Unresolved directory durability must stop recovery before Engine.
        }

        XCTAssertEqual(enginePersistCount, 0)
        XCTAssertEqual(try fixture.journal().load(), fixture.application)
    }

    func testTemporaryCleanupFailureIsAttachedWithoutReplacingCleanVerdict() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        let recorder = JournalMonitoringRecorder()
        var operations = ZhulongJournalDarwinOperations.live
        operations.renameExclusive = { _, _ in
            throw JournalFileFault.rename
        }
        operations.removeFile = { _ in
            throw JournalFileFault.cleanup
        }
        let journal = fixture.journal(
            fileOperations: operations,
            monitor: recorder.record
        )

        let failure = try captureFailure {
            _ = try journal.save(fixture.application)
        }

        XCTAssertEqual(failure.disposition, .notCommitted)
        XCTAssertEqual(failure.failedPhase, .replacement)
        XCTAssertEqual(failure.underlyingError as? JournalFileFault, .rename)
        XCTAssertEqual(failure.cleanupError as? JournalFileFault, .cleanup)
        XCTAssertTrue(
            recorder.events.contains {
                $0.phase == .temporaryCleanup
                    && $0.resolution == .cleanupFailure
            }
        )
    }

    func testWriteRetriesEINTRAndCompletesPartialWrites() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        var operations = ZhulongJournalDarwinOperations.live
        let liveWrite = operations.writeChunk
        var writeCallCount = 0
        operations.writeChunk = { descriptor, data, offset in
            writeCallCount += 1
            if writeCallCount == 1 {
                throw posixError(EINTR)
            }
            if writeCallCount == 2 {
                return try data.withUnsafeBytes { bytes in
                    guard let baseAddress = bytes.baseAddress else { return 0 }
                    let count = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        1
                    )
                    guard count >= 0 else { throw posixError(errno) }
                    return count
                }
            }
            return try liveWrite(descriptor, data, offset)
        }
        let journal = fixture.journal(fileOperations: operations)

        XCTAssertEqual(try journal.save(fixture.application), .committed)
        XCTAssertGreaterThanOrEqual(writeCallCount, 3)
        XCTAssertEqual(try journal.load(), fixture.application)
    }

    func testTemporaryFileIsOwnerOnlyAndCloseOnExecBeforeWrite() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        var operations = ZhulongJournalDarwinOperations.live
        let liveWrite = operations.writeChunk
        var inspected = false
        operations.writeChunk = { descriptor, data, offset in
            if inspected == false {
                inspected = true
                var status = stat()
                XCTAssertEqual(fstat(descriptor, &status), 0)
                XCTAssertEqual(status.st_mode & mode_t(0o777), mode_t(0o600))
                XCTAssertNotEqual(fcntl(descriptor, F_GETFD) & FD_CLOEXEC, 0)
            }
            return try liveWrite(descriptor, data, offset)
        }
        let journal = fixture.journal(fileOperations: operations)

        XCTAssertEqual(try journal.save(fixture.application), .committed)
        XCTAssertTrue(inspected)
    }

    func testGeneratedTemporarySymlinkIsNeverFollowedOrReplaced() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        let decoyURL = fixture.directoryURL
            .appendingPathComponent("decoy", isDirectory: false)
        let decoy = Data("do-not-overwrite".utf8)
        try decoy.write(to: decoyURL)
        var operations = ZhulongJournalDarwinOperations.live
        let liveOpen = operations.openExclusiveFile
        operations.openExclusiveFile = { temporaryURL in
            try FileManager.default.createSymbolicLink(
                at: temporaryURL,
                withDestinationURL: decoyURL
            )
            return try liveOpen(temporaryURL)
        }
        let journal = fixture.journal(fileOperations: operations)

        let failure = try captureFailure {
            _ = try journal.save(fixture.application)
        }

        XCTAssertEqual(failure.disposition, .notCommitted)
        XCTAssertEqual(failure.failedPhase, .temporaryOpen)
        XCTAssertEqual(try Data(contentsOf: decoyURL), decoy)
        XCTAssertNil(try journal.load())
    }

    func testLoadRejectsHardLinkedJournal() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        let journal = fixture.journal()
        try journal.save(fixture.application)
        let secondLink = fixture.directoryURL
            .appendingPathComponent("journal-hard-link", isDirectory: false)
        try FileManager.default.linkItem(at: journal.fileURL, to: secondLink)

        XCTAssertThrowsError(try journal.load())
    }

    func testLoadRejectsJournalWithGroupWritablePermissions() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        let journal = fixture.journal()
        try journal.save(fixture.application)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o620],
            ofItemAtPath: journal.fileURL.path
        )

        XCTAssertThrowsError(try journal.load())
    }

    func testMonitoringFieldsCannotContainPathIdentityOrPayload() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        let recorder = JournalMonitoringRecorder()
        var operations = ZhulongJournalDarwinOperations.live
        let liveSync = operations.syncDirectory
        var syncCount = 0
        operations.syncDirectory = { descriptor in
            syncCount += 1
            try liveSync(descriptor)
            if syncCount == 1 {
                throw JournalFileFault.sync
            }
        }
        let journal = fixture.journal(
            fileOperations: operations,
            monitor: recorder.record
        )
        _ = try journal.save(fixture.application)

        let rendered = String(reflecting: recorder.events)

        XCTAssertFalse(rendered.contains(fixture.directoryURL.path))
        XCTAssertFalse(rendered.contains(fixture.application.id.uuidString))
        XCTAssertFalse(rendered.contains("journal fault fixture"))
    }

    func testStructuredErrorTelemetryDropsNSErrorPathAndMessage() {
        let secretPath = "/private/secret/pending-application.zhj"
        let error = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(EIO),
            userInfo: [
                NSFilePathErrorKey: secretPath,
                NSLocalizedDescriptionKey: "payload-secret"
            ]
        )

        let telemetry = ZhulongErrorTelemetry(error)
        let rendered = String(reflecting: telemetry)

        XCTAssertEqual(telemetry.kind, .posix)
        XCTAssertEqual(telemetry.code, Int(EIO))
        XCTAssertFalse(rendered.contains(secretPath))
        XCTAssertFalse(rendered.contains("payload-secret"))
    }

    func testClearUnlinkSuccessThenErrorReturnsRecoveredCommitted() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        let writer = fixture.journal()
        try writer.save(fixture.application)
        var operations = ZhulongJournalDarwinOperations.live
        let liveRemove = operations.removeFile
        operations.removeFile = { url in
            try liveRemove(url)
            throw JournalFileFault.remove
        }
        let journal = fixture.journal(fileOperations: operations)

        let outcome = try journal.clear(
            fixture.application,
            requiring: .beforeSession
        )

        XCTAssertEqual(
            outcome,
            .recoveredCommitted(after: .removal)
        )
        XCTAssertNil(try writer.load())
    }

    func testClearErrorWithExactExpectedStillPresentIsCleanFailure() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        let writer = fixture.journal()
        try writer.save(fixture.application)
        var operations = ZhulongJournalDarwinOperations.live
        operations.removeFile = { _ in
            throw JournalFileFault.remove
        }
        let journal = fixture.journal(fileOperations: operations)

        let failure = try captureFailure {
            _ = try journal.clear(
                fixture.application,
                requiring: .beforeSession
            )
        }

        XCTAssertEqual(failure.disposition, .notCommitted)
        XCTAssertEqual(failure.failedPhase, .removal)
        XCTAssertEqual(try writer.load(), fixture.application)
    }

    func testClearErrorWithThirdBytesIsUnresolvedAndPreservesGate() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        let writer = fixture.journal()
        try writer.save(fixture.application)
        var operations = ZhulongJournalDarwinOperations.live
        operations.removeFile = { url in
            try Data([0xFF]).write(to: url)
            throw JournalFileFault.remove
        }
        let journal = fixture.journal(fileOperations: operations)

        let failure = try captureFailure {
            _ = try journal.clear(
                fixture.application,
                requiring: .beforeSession
            )
        }

        XCTAssertEqual(failure.disposition, .unresolved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.fileURL.path))
        XCTAssertThrowsError(
            try fixture.sessionRepository.save(
                fixture.makeUnrelatedSession()
            )
        )
    }

    func testSuccessfulClearThatRecreatesExactJournalFailsFinalObservation() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        let writer = fixture.journal()
        try writer.save(fixture.application)
        let exactBytes = try Data(contentsOf: writer.fileURL)
        var operations = ZhulongJournalDarwinOperations.live
        let liveRemove = operations.removeFile
        operations.removeFile = { url in
            try liveRemove(url)
            try exactBytes.write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
        let journal = fixture.journal(fileOperations: operations)

        let failure = try captureFailure {
            _ = try journal.clear(
                fixture.application,
                requiring: .beforeSession
            )
        }

        XCTAssertEqual(failure.disposition, .unresolved)
        XCTAssertEqual(failure.failedPhase, .observation)
        XCTAssertEqual(try writer.load(), fixture.application)
    }

    func testSuccessfulClearThatRecreatesWrongBytesFailsFinalObservation() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        let writer = fixture.journal()
        try writer.save(fixture.application)
        var operations = ZhulongJournalDarwinOperations.live
        let liveRemove = operations.removeFile
        operations.removeFile = { url in
            try liveRemove(url)
            try Data([0x04]).write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
        let journal = fixture.journal(fileOperations: operations)

        let failure = try captureFailure {
            _ = try journal.clear(
                fixture.application,
                requiring: .beforeSession
            )
        }

        XCTAssertEqual(failure.disposition, .unresolved)
        XCTAssertEqual(failure.failedPhase, .observation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.fileURL.path))
    }

    func testClearDirectorySyncFirstErrorThenRetrySuccessReturnsRecoveredCommitted() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        let writer = fixture.journal()
        try writer.save(fixture.application)
        var operations = ZhulongJournalDarwinOperations.live
        let liveSync = operations.syncDirectory
        var syncCount = 0
        operations.syncDirectory = { descriptor in
            syncCount += 1
            try liveSync(descriptor)
            if syncCount == 1 {
                throw JournalFileFault.sync
            }
        }
        let journal = fixture.journal(fileOperations: operations)

        let outcome = try journal.clear(
            fixture.application,
            requiring: .beforeSession
        )

        XCTAssertEqual(
            outcome,
            .recoveredCommitted(after: .directorySync)
        )
        XCTAssertEqual(syncCount, 2)
        XCTAssertNil(try writer.load())
    }

    func testPersistentClearDirectorySyncFailureIsUnresolvedAndLatchesAbsentGate() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        let writer = fixture.journal()
        try writer.save(fixture.application)
        try fixture.sessionRepository.save(
            fixture.application.afterSession,
            replacing: fixture.application.beforeSession,
            authorizedBy: fixture.application
        )
        var operations = ZhulongJournalDarwinOperations.live
        var syncCount = 0
        operations.syncDirectory = { _ in
            syncCount += 1
            throw posixError(ENOTSUP)
        }
        let journal = fixture.journal(fileOperations: operations)

        let outcome = ZhulongApplicationCommitCoordinator.finish(
            engineAlreadyPersisted: true,
            persistEngine: {},
            persistSession: {},
            clearJournal: { requirement in
                try journal.clear(
                    fixture.application,
                    requiring: requirement
                )
            }
        )

        XCTAssertEqual(outcome.progress, .sessionPersisted)
        XCTAssertFalse(outcome.commitCompleted)
        XCTAssertEqual(syncCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.fileURL.path))
        XCTAssertThrowsError(try journal.load())
        XCTAssertThrowsError(
            try fixture.sessionRepository.save(
                fixture.makeUnrelatedSession()
            )
        )
        XCTAssertNil(try writer.load())
        XCTAssertNoThrow(
            try fixture.sessionRepository.save(
                fixture.makeUnrelatedSession()
            )
        )
    }

    func testAbsentFenceResolvesThroughSymlinkAliasBeforeWritesReopen() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        let realParentURL = fixture.directoryURL.deletingLastPathComponent()
        let aliasParentURL = realParentURL
            .appendingPathComponent(
                "noonmark-journal-alias-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createSymbolicLink(
            at: aliasParentURL,
            withDestinationURL: realParentURL
        )
        defer { try? FileManager.default.removeItem(at: aliasParentURL) }
        let aliasURL = aliasParentURL.appendingPathComponent(
            fixture.directoryURL.lastPathComponent,
            isDirectory: true
        )
        let writer = fixture.journal()
        try writer.save(fixture.application)
        var operations = ZhulongJournalDarwinOperations.live
        operations.syncDirectory = { _ in
            throw posixError(ENOTSUP)
        }
        let faultJournal = fixture.journal(fileOperations: operations)
        _ = try captureFailure {
            _ = try faultJournal.clear(
                fixture.application,
                requiring: .beforeSession
            )
        }
        let aliasRepository = EncryptedFileZhulongSessionRepository(
            directoryURL: aliasURL,
            keySource: fixture.keySource
        )
        let aliasJournal = EncryptedFileZhulongApplicationJournal(
            directoryURL: aliasURL,
            keySource: fixture.keySource
        )

        XCTAssertThrowsError(
            try aliasRepository.save(fixture.makeUnrelatedSession())
        )
        XCTAssertNil(try aliasJournal.load())
        XCTAssertNoThrow(
            try aliasRepository.save(fixture.makeUnrelatedSession())
        )
    }

    func testUnlinkReportedErrorWithAbsentDestinationStillRequiresDurableDirectorySync() throws {
        let fixture = try makeFixture()
        defer { fixture.removeDirectory() }
        let writer = fixture.journal()
        try writer.save(fixture.application)
        var operations = ZhulongJournalDarwinOperations.live
        let liveRemove = operations.removeFile
        var syncCount = 0
        operations.removeFile = { url in
            try liveRemove(url)
            throw JournalFileFault.remove
        }
        operations.syncDirectory = { _ in
            syncCount += 1
            throw posixError(ENOTSUP)
        }
        let journal = fixture.journal(fileOperations: operations)

        let failure = try captureFailure {
            _ = try journal.clear(
                fixture.application,
                requiring: .beforeSession
            )
        }

        XCTAssertEqual(failure.disposition, .unresolved)
        XCTAssertEqual(failure.failedPhase, .removal)
        XCTAssertEqual(syncCount, 2)
        XCTAssertThrowsError(try journal.load())
        XCTAssertThrowsError(
            try fixture.sessionRepository.save(
                fixture.makeUnrelatedSession()
            )
        )
        XCTAssertNil(try writer.load())
        XCTAssertNoThrow(
            try fixture.sessionRepository.save(
                fixture.makeUnrelatedSession()
            )
        )
    }

    private func makeFixture() throws -> JournalFileFixture {
        try JournalFileFixture()
    }

    private func captureFailure(
        _ operation: () throws -> Void
    ) throws -> ZhulongApplicationJournalMutationFailure {
        do {
            try operation()
            XCTFail("expected journal mutation failure")
            throw JournalFileFault.missingExpectedFailure
        } catch let failure as ZhulongApplicationJournalMutationFailure {
            return failure
        }
    }
}

private struct JournalFileFixture {
    let directoryURL: URL
    let keySource = JournalFileKeySource()
    let application: ZhulongPendingApplication
    let sessionRepository: EncryptedFileZhulongSessionRepository

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-journal-file-commit-\(UUID().uuidString)",
                isDirectory: true
            )
        let now = Date(timeIntervalSinceReferenceDate: 1_234_567)
        var session = try ZhulongSession(
            primaryIntent: "journal fault fixture",
            proposedScopes: [.taskPool],
            now: now
        )
        let beforeSession = session
        _ = try session.appendEntry(
            author: .zhulong,
            kind: .statement,
            content: "journal fault fixture applied",
            now: now.addingTimeInterval(2)
        )
        let afterEngine = NoonmarkEngine()
        _ = try afterEngine.createPoolTask(
            title: "journal fault fixture",
            now: now.addingTimeInterval(2)
        )
        application = try ZhulongPendingApplication(
            kind: .todoDiff(ZhulongTodoDiffID()),
            sessionID: session.id,
            beforeSnapshot: NoonmarkEngine().snapshot(),
            afterSnapshot: afterEngine.snapshot(),
            beforeSession: beforeSession,
            afterSession: session,
            createdAt: now.addingTimeInterval(2)
        )
        sessionRepository = EncryptedFileZhulongSessionRepository(
            directoryURL: directoryURL,
            keySource: keySource
        )
        try sessionRepository.save(beforeSession)
    }

    func journal(
        fileOperations: ZhulongJournalDarwinOperations = .live,
        monitor: @escaping ZhulongApplicationJournalMonitor = { _ in }
    ) -> EncryptedFileZhulongApplicationJournal {
        EncryptedFileZhulongApplicationJournal(
            directoryURL: directoryURL,
            keySource: keySource,
            fileOperations: fileOperations,
            monitor: monitor
        )
    }

    func makeUnrelatedSession() throws -> ZhulongSession {
        try ZhulongSession(
            primaryIntent: "unrelated session",
            proposedScopes: [.taskPool],
            now: application.createdAt.addingTimeInterval(10)
        )
    }

    func hasTemporaryJournalFile() throws -> Bool {
        try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ).contains {
            $0.lastPathComponent.hasPrefix(".pending-application.zhj.")
                && $0.pathExtension == "tmp"
        }
    }

    func temporaryJournalURL(uuidByte: String) -> URL {
        let uuid = "\(uuidByte)\(uuidByte)\(uuidByte)\(uuidByte)-" +
            "\(uuidByte)\(uuidByte)-\(uuidByte)\(uuidByte)-" +
            "\(uuidByte)\(uuidByte)-" +
            String(repeating: uuidByte, count: 6)
        return directoryURL.appendingPathComponent(
            ".pending-application.zhj.\(uuid).tmp",
            isDirectory: false
        )
    }

    func writeFile(
        _ url: URL,
        permissions: Int
    ) throws {
        try Data([0xA5]).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    func removeDirectory() {
        try? ZhulongSidecarTransactionLock(
            directoryURL: directoryURL,
            fileManager: .default
        ).clearApplicationCommitFence()
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private struct JournalFileKeySource: ZhulongSidecarKeySource {
    func loadOrCreateKey() throws -> Data {
        Data(repeating: 0x73, count: 32)
    }
}

private enum JournalFileFault: Error, Equatable {
    case permissions
    case rename
    case sync
    case close
    case read
    case cleanup
    case remove
    case missingExpectedFailure
}

private final class JournalMonitoringRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [ZhulongApplicationJournalMonitoringEvent] = []

    var events: [ZhulongApplicationJournalMonitoringEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }

    func record(_ event: ZhulongApplicationJournalMonitoringEvent) {
        lock.lock()
        storedEvents.append(event)
        lock.unlock()
    }
}

private func posixError(_ code: Int32) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code))
}
