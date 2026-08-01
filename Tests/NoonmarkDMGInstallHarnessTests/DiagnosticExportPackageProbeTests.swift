import Darwin
import Foundation
@testable import NoonmarkDMGInstallHarness
import XCTest

final class DiagnosticExportPackageProbeTests: XCTestCase {
    func testProbeAcceptsAnExactTypedPackage() throws {
        let fixture = try PackageProbeFixture()
        defer { fixture.remove() }
        try fixture.writeExport(try fixture.packageData())

        XCTAssertNoThrow(
            try DiagnosticExportPackageProbe.verify(
                exportPath: fixture.exportURL.path,
                sentinelsPath: fixture.sentinelsURL.path,
                ledger: nil
            )
        )
    }

    func testProbeRejectsAnUnknownNestedSchemaKey() throws {
        let fixture = try PackageProbeFixture()
        defer { fixture.remove() }
        try fixture.writeExport(
            try fixture.packageData(manifestUnknownValue: "untrusted")
        )

        XCTAssertThrowsError(
            try DiagnosticExportPackageProbe.verify(
                exportPath: fixture.exportURL.path,
                sentinelsPath: fixture.sentinelsURL.path,
                ledger: nil
            )
        )
    }

    func testProbeRejectsAPrivacySentinelHiddenByJSONEscaping() throws {
        let sentinel = "PRIVATE-CANARY-ESCAPED"
        let fixture = try PackageProbeFixture(sentinel: sentinel)
        defer { fixture.remove() }
        let literal = try fixture.packageData(version: sentinel)
        let literalString = try XCTUnwrap(
            String(data: literal, encoding: .utf8)
        )
        let escaped = literalString
            .replacingOccurrences(
                of: sentinel,
                with: "PRIVATE\\u002dCANARY\\u002dESCAPED"
            )
        XCTAssertFalse(escaped.utf8.containsContiguousBytes(of: sentinel.utf8))
        try fixture.writeExport(Data(escaped.utf8))

        XCTAssertThrowsError(
            try DiagnosticExportPackageProbe.verify(
                exportPath: fixture.exportURL.path,
                sentinelsPath: fixture.sentinelsURL.path,
                ledger: nil
            )
        )
    }

    func testProbeRejectsAPrivacySentinelInsideCodableData() throws {
        let sentinel = "SECRETABC123"
        let fixture = try PackageProbeFixture(sentinel: sentinel)
        defer { fixture.remove() }
        let payload = Data(sentinel.utf8)
        let package = try fixture.packageData(metricPayload: payload)
        XCTAssertNil(package.range(of: payload))
        XCTAssertNotNil(
            package.range(of: Data(payload.base64EncodedString().utf8))
        )
        try fixture.writeExport(package)

        XCTAssertThrowsError(
            try DiagnosticExportPackageProbe.verify(
                exportPath: fixture.exportURL.path,
                sentinelsPath: fixture.sentinelsURL.path,
                ledger: nil
            )
        )
    }
}

private struct PackageProbeFixture {
    let root: URL
    let exportURL: URL
    let sentinelsURL: URL

    init(sentinel: String = "PRIVATE-CANARY-RAW") throws {
        root = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        .appendingPathComponent(".build/test-fixtures", isDirectory: true)
        .appendingPathComponent(
            "noonmark-diagnostic-package-\(UUID().uuidString)",
            isDirectory: true
        )
        exportURL = root.appendingPathComponent(
            "Noonmark-Diagnostic-Closure.noonmarkdiagnostics"
        )
        sentinelsURL = root.appendingPathComponent("privacy-sentinels.txt")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("\(sentinel)\n".utf8).write(to: sentinelsURL)
        guard chmod(sentinelsURL.path, mode_t(0o600)) == 0 else {
            throw POSIXError(.EPERM)
        }
    }

    func writeExport(_ data: Data) throws {
        try data.write(to: exportURL)
        guard chmod(exportURL.path, mode_t(0o600)) == 0 else {
            throw POSIXError(.EPERM)
        }
    }

    func packageData(
        version: String = "0.1.0",
        manifestUnknownValue: String? = nil,
        metricPayload: Data? = nil
    ) throws -> Data {
        let metrics: [[String: Any]] = if let metricPayload {
            [[
                "receivedAt": 0,
                "summary": [
                    "kind": "metric",
                    "intervalStart": 0,
                    "intervalEnd": 0,
                    "crashCount": 0,
                    "hangCount": 0,
                    "cpuExceptionCount": 0,
                    "diskWriteExceptionCount": 0,
                    "rawJSONByteCount": metricPayload.count
                ],
                "sanitizedJSON": metricPayload.base64EncodedString(),
                "redactionVersion": 1
            ]]
        } else {
            []
        }
        var manifest: [String: Any] = [
            "schemaVersion": 1,
            "generatedAt": 0,
            "appIdentity": [
                "version": version,
                "build": "1",
                "buildArchitecture": "arm64",
                "operatingSystemMajorVersion": 14,
                "operatingSystemMinorVersion": 0,
                "operatingSystemPatchVersion": 0,
                "architecture": "arm64"
            ],
            "recordCount": 0,
            "activeOperationCount": 0,
            "operationCapsuleCount": 0,
            "metricPayloadCount": metrics.count,
            "droppedRecordCount": 0,
            "droppedCriticalRecordCount": 0,
            "compactedCriticalEvidenceCount": 0,
            "evictedMetricPayloadCount": 0,
            "corruptRecordCount": 0,
            "oversizedEventCount": 0,
            "oversizedMetricPayloadCount": 0,
            "maximumObservedAllocatedBytes": 0,
            "redactionVersion": 1,
            "collectionWasPartial": false
        ]
        if let manifestUnknownValue {
            manifest["unknownNested"] = manifestUnknownValue
        }
        return try JSONSerialization.data(
            withJSONObject: [
                "manifest": manifest,
                "records": [],
                "activeOperations": [],
                "operationCapsules": [],
                "metricAttachments": metrics
            ],
            options: [.sortedKeys]
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private extension Collection<UInt8> {
    func containsContiguousBytes(of bytes: some Collection<UInt8>) -> Bool {
        Data(self).range(of: Data(bytes)) != nil
    }
}
