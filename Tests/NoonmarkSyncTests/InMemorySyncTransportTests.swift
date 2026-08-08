import Foundation
@testable import NoonmarkCore
@testable import NoonmarkSync
import XCTest

final class InMemorySyncTransportTests: XCTestCase {
    private static let collisionChildEnvironment =
        "NOONMARK_TEST_IN_MEMORY_SEED_COLLISION_CHILD"
    private static let collisionTestSelector =
        "NoonmarkSyncTests.InMemorySyncTransportTests/" +
        "testSeededImmutableCollisionThrowsWithoutTerminatingProcess"
    private static let ordinaryChildEnvironment =
        "NOONMARK_TEST_IN_MEMORY_ORDINARY_SEED_CHILD"
    private static let ordinaryTestSelector =
        "NoonmarkSyncTests.InMemorySyncTransportTests/" +
        "testSeededOrdinaryVariantsCanonicalizeIndependentlyOfOrder"

    func testSeededImmutableCollisionThrowsWithoutTerminatingProcess() throws {
        if ProcessInfo.processInfo.environment[
            Self.collisionChildEnvironment
        ] == "1" {
            let records = immutableCollisionRecords()
            XCTAssertThrowsError(
                try InMemorySyncTransport(records: records)
            ) { error in
                XCTAssertEqual(
                    error as? SyncRecordTransportError,
                    .immutableRecordCollision(recordID: records[0].id)
                )
            }
            return
        }

        try assertChildExitsNormally(
            selector: Self.collisionTestSelector,
            environment: [Self.collisionChildEnvironment: "1"]
        )
    }

    func testSeededOrdinaryVariantsCanonicalizeIndependentlyOfOrder() async throws {
        let older = try preferenceRecord(
            theme: .coolGray,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 10),
            deviceID: "seed-older"
        )
        let newer = try preferenceRecord(
            theme: .warmPaper,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 20),
            deviceID: "seed-newer"
        )

        if let order = ProcessInfo.processInfo.environment[
            Self.ordinaryChildEnvironment
        ] {
            let records = order == "older-first"
                ? [older, newer]
                : [newer, older]
            let transport = try InMemorySyncTransport(records: records)
            let fetched = try await transport.bootstrapRecords()
            XCTAssertEqual(fetched, [newer])
            return
        }

        for order in ["older-first", "newer-first"] {
            try assertChildExitsNormally(
                selector: Self.ordinaryTestSelector,
                environment: [Self.ordinaryChildEnvironment: order]
            )
        }
    }

    func testMalformedOrdinarySeedFailsClosed() throws {
        let malformed = SyncRecord(
            id: SyncRecordID("day:malformed-seed"),
            entityType: .day,
            entityID: "malformed-seed",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 10),
            modifiedByDeviceID: SyncDeviceID("seed-malformed"),
            payload: Data([0x00, 0x7F, 0x80, 0xFF])
        )

        XCTAssertThrowsError(
            try InMemorySyncTransport(records: [malformed])
        ) { error in
            XCTAssertEqual(
                error as? SyncRecordTransportError,
                .invalidCurrentRecordMerge(
                    recordID: malformed.id,
                    reason: .invalidRecordPayload
                )
            )
        }
    }

    func testThrowingPushLeavesExactStateUnchanged() async throws {
        let baseline = try preferenceRecord(
            theme: .coolGray,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 10),
            deviceID: "push-baseline"
        )
        let independent = SyncRecord(
            id: SyncRecordID("classification-commit:independent"),
            entityType: .classificationCommit,
            entityID: "independent",
            modifiedAt: Date(timeIntervalSinceReferenceDate: 11),
            modifiedByDeviceID: SyncDeviceID("push-independent"),
            payload: Data("independent".utf8)
        )
        let colliding = SyncRecord(
            id: baseline.id,
            entityType: .classificationCommit,
            entityID: baseline.entityID,
            modifiedAt: baseline.modifiedAt,
            modifiedByDeviceID: baseline.modifiedByDeviceID,
            payload: Data("collision".utf8)
        )
        let transport = try InMemorySyncTransport(records: [baseline])
        let before = try await transport.bootstrapRecords()

        do {
            try await transport.pushAccepting([independent, colliding])
            XCTFail("cross-type immutable collision must fail closed")
        } catch {
            XCTAssertEqual(
                error as? SyncRecordTransportError,
                .immutableRecordCollision(recordID: baseline.id)
            )
        }

        let after = try await transport.bootstrapRecords()
        XCTAssertEqual(after, before)
    }

    func testEmptyInitializerRemainsNonthrowing() async throws {
        let transport = InMemorySyncTransport()
        let records = try await transport.bootstrapRecords()

        XCTAssertTrue(records.isEmpty)
    }

    private func immutableCollisionRecords() -> [SyncRecord] {
        let id = SyncRecordID("classification-commit:seed-collision")
        return ["first", "second"].map { variant in
            SyncRecord(
                id: id,
                entityType: .classificationCommit,
                entityID: "seed-collision",
                modifiedAt: Date(timeIntervalSinceReferenceDate: 10),
                modifiedByDeviceID: SyncDeviceID("seed-collision"),
                payload: Data(variant.utf8)
            )
        }
    }

    private func preferenceRecord(
        theme: AppTheme,
        modifiedAt: Date,
        deviceID: String
    ) throws -> SyncRecord {
        try SyncRecordMapper().record(
            for: AppPreferencesEnvelope(
                theme: theme,
                language: .chinese,
                updatedAt: modifiedAt,
                writerDeviceID: SyncDeviceID(deviceID)
            ),
            modifiedBy: SyncDeviceID(deviceID)
        )
    }

    private func assertChildExitsNormally(
        selector: String,
        environment childEnvironment: [String: String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest",
            "-XCTest",
            selector,
            Bundle(for: Self.self).bundleURL.path
        ]
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in childEnvironment {
            environment[key] = value
        }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()
        let childOutput = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(
            process.terminationReason,
            .exit,
            childOutput,
            file: file,
            line: line
        )
        XCTAssertEqual(
            process.terminationStatus,
            0,
            childOutput,
            file: file,
            line: line
        )
    }
}
