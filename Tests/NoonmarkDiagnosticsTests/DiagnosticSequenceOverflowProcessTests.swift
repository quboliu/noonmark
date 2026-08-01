import Foundation
@testable import NoonmarkDiagnostics
import XCTest

final class DiagnosticSequenceOverflowProcessTests: XCTestCase {
    private static let phaseEnvironment =
        "NOONMARK_TEST_DIAGNOSTIC_SEQUENCE_OVERFLOW_PHASE"
    private static let rootEnvironment =
        "NOONMARK_TEST_DIAGNOSTIC_SEQUENCE_OVERFLOW_ROOT"
    private static let testSelector =
        "NoonmarkDiagnosticsTests.DiagnosticSequenceOverflowProcessTests/" +
        "testCorruptSequenceFailsOpenWithoutTerminatingProcess"
    private static let now = Date(timeIntervalSince1970: 1_800_020_000)

    func testCorruptSequenceFailsOpenWithoutTerminatingProcess() async throws {
        if let rawPhase = ProcessInfo.processInfo.environment[
            Self.phaseEnvironment
        ] {
            let phase = try XCTUnwrap(Phase(rawValue: rawPhase))
            let rootPath = try XCTUnwrap(
                ProcessInfo.processInfo.environment[Self.rootEnvironment]
            )
            try await runChild(
                phase: phase,
                rootURL: URL(fileURLWithPath: rootPath, isDirectory: true)
            )
            return
        }

        for phase in Phase.allCases {
            try assertChildExitsNormally(phase: phase)
        }
    }

    private func assertChildExitsNormally(phase: Phase) throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "noonmark-diagnostic-sequence-\(phase.rawValue)-" +
                    UUID().uuidString,
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest",
            "-XCTest",
            Self.testSelector,
            Bundle(for: Self.self).bundleURL.path
        ]
        var environment = ProcessInfo.processInfo.environment
        environment[Self.phaseEnvironment] = phase.rawValue
        environment[Self.rootEnvironment] = rootURL.path
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
            "phase=\(phase.rawValue)\n\(childOutput)"
        )
        XCTAssertEqual(
            process.terminationStatus,
            0,
            "phase=\(phase.rawValue)\n\(childOutput)"
        )
    }

    private func runChild(phase: Phase, rootURL: URL) async throws {
        switch phase {
        case .segmentMaximumSequence:
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
            var data = try JSONEncoder().encode(
                RecordedEvidence(
                    sequence: .max,
                    timestamp: Self.now,
                    sessionID: DiagnosticSessionID(),
                    event: .cleanShutdown()
                )
            )
            data.append(0x0A)
            try data.write(
                to: rootURL.appendingPathComponent("events-00.ndjson")
            )
            let recorder = try makeRecorder(rootURL: rootURL)
            let package = try await recorder.snapshotPackage()
            XCTAssertTrue(package.manifest.collectionWasPartial)
            XCTAssertGreaterThanOrEqual(
                package.manifest.corruptRecordCount,
                1
            )
            XCTAssertFalse(package.records.contains { $0.sequence == .max })

        case .indexMaximumNextSequence:
            var recorder: LocalDiagnosticRecorder? = try makeRecorder(
                rootURL: rootURL
            )
            recorder?.startSession(at: Self.now)
            await recorder?.flush()
            recorder = nil
            let indexURL = rootURL.appendingPathComponent("index.json")
            var text = try String(contentsOf: indexURL, encoding: .utf8)
            let range = try XCTUnwrap(
                text.range(
                    of: #""nextSequence":[0-9]+"#,
                    options: .regularExpression
                )
            )
            text.replaceSubrange(
                range,
                with: #""nextSequence":18446744073709551615"#
            )
            try Data(text.utf8).write(to: indexURL)

            let relaunched = try makeRecorder(rootURL: rootURL)
            await relaunched.recordCleanShutdown(at: Self.now)
            let health = await relaunched.health()
            XCTAssertTrue(health.fileSinkDisabled)
            let package = try await relaunched.snapshotPackage()
            XCTAssertTrue(package.manifest.collectionWasPartial)
        }
    }

    private func makeRecorder(rootURL: URL) throws
        -> LocalDiagnosticRecorder
    {
        try LocalDiagnosticRecorder(
            rootURL: rootURL,
            appIdentity: .testFixture,
            configuration: .production,
            unifiedLoggingEnabled: false,
            now: { Self.now }
        )
    }

    private enum Phase: String, CaseIterable {
        case segmentMaximumSequence
        case indexMaximumNextSequence
    }
}
