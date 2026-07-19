import Foundation
@testable import NoonmarkSync
import XCTest

final class SyncInvariantCodableTests: XCTestCase {
    private let whitespaceOnly = " \t\n\u{00A0}\u{3000}"

    func testIdentifierDecodingRejectsWhitespaceOnlyRawValues() throws {
        let recordIDData = try encodedObject(["rawValue": whitespaceOnly])
        let deviceIDData = try encodedObject(["rawValue": whitespaceOnly])

        assertDataCorrupted {
            try JSONDecoder().decode(SyncRecordID.self, from: recordIDData)
        }
        assertDataCorrupted {
            try JSONDecoder().decode(SyncDeviceID.self, from: deviceIDData)
        }
    }

    func testStorageModelDecodingRejectsWhitespaceOnlyInvariantFields() throws {
        let metadata = SyncMetadataEntry(
            key: "sync.metadata",
            value: Data([0x01]),
            updatedAt: Date(timeIntervalSinceReferenceDate: 10)
        )
        let audit = SyncAuditLogEntry(
            id: UUID(uuidString: "AF000000-0000-0000-0000-000000000001")!,
            direction: .download,
            entityType: .day,
            entityID: "2026-07-17",
            action: "merged",
            createdAt: Date(timeIntervalSinceReferenceDate: 11)
        )

        assertDataCorrupted {
            try JSONDecoder().decode(
                SyncMetadataEntry.self,
                from: replacingStringField(
                    "key",
                    with: whitespaceOnly,
                    in: metadata
                )
            )
        }
        assertDataCorrupted {
            try JSONDecoder().decode(
                SyncAuditLogEntry.self,
                from: replacingStringField(
                    "action",
                    with: whitespaceOnly,
                    in: audit
                )
            )
        }
    }

    func testInvariantDecodingNormalizesPaddedNonemptyValues() throws {
        let recordID = try JSONDecoder().decode(
            SyncRecordID.self,
            from: encodedObject(["rawValue": "  day:one\n"])
        )
        let deviceID = try JSONDecoder().decode(
            SyncDeviceID.self,
            from: encodedObject(["rawValue": "\tmac-one  "])
        )
        let metadata = SyncMetadataEntry(
            key: "sync.metadata",
            value: Data([0x01]),
            updatedAt: Date(timeIntervalSinceReferenceDate: 10)
        )
        let decodedMetadata = try JSONDecoder().decode(
            SyncMetadataEntry.self,
            from: replacingStringField(
                "key",
                with: "  sync.metadata\n",
                in: metadata
            )
        )
        let audit = SyncAuditLogEntry(
            direction: .merge,
            entityType: .taskChain,
            entityID: "chain-one",
            action: "merged",
            createdAt: Date(timeIntervalSinceReferenceDate: 11)
        )
        let decodedAudit = try JSONDecoder().decode(
            SyncAuditLogEntry.self,
            from: replacingStringField(
                "action",
                with: "\tmerged  ",
                in: audit
            )
        )

        XCTAssertEqual(recordID.rawValue, "day:one")
        XCTAssertEqual(deviceID.rawValue, "mac-one")
        XCTAssertEqual(decodedMetadata.key, "sync.metadata")
        XCTAssertEqual(decodedAudit.action, "merged")
    }

    func testIdentifierEncodingKeepsTheExistingKeyedWireShape() throws {
        let recordObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(SyncRecordID("day:one"))
            ) as? [String: String]
        )
        let deviceObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(SyncDeviceID("mac-one"))
            ) as? [String: String]
        )

        XCTAssertEqual(recordObject, ["rawValue": "day:one"])
        XCTAssertEqual(deviceObject, ["rawValue": "mac-one"])
    }

    private func replacingStringField(
        _ field: String,
        with value: String,
        in model: some Encodable
    ) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(model)
            ) as? [String: Any]
        )
        object[field] = value
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
    }

    private func encodedObject(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func assertDataCorrupted(
        _ operation: () throws -> some Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail(
                    "expected DecodingError.dataCorrupted, got \(error)",
                    file: file,
                    line: line
                )
            }
        }
    }
}
