import Foundation
@testable import SuntraceZhulong
import XCTest

final class KeychainZhulongSidecarKeySourceTests: XCTestCase {
    func testKeychainCreatesStableIndependentKeyAndLossFailsClosed() throws {
        let service = "app.noonmark.tests.zhulong-sidecar.\(UUID().uuidString)"
        let keySource = KeychainZhulongSidecarKeySource(service: service)
        try? keySource.deleteKey()
        defer { try? keySource.deleteKey() }

        let first = try keySource.loadOrCreateKey()
        let second = try keySource.loadOrCreateKey()
        XCTAssertEqual(first.count, 32)
        XCTAssertEqual(second, first)

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("suntrace-zhulong-keychain-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let repository = EncryptedFileZhulongSessionRepository(
            directoryURL: directoryURL,
            keySource: keySource
        )
        let session = try ZhulongSession(
            primaryIntent: "验证 Keychain sidecar",
            proposedScopes: [.currentDayTodo]
        )
        try repository.save(session)
        XCTAssertEqual(try repository.load(session.id), session)

        try keySource.deleteKey()
        XCTAssertThrowsError(try repository.load(session.id))
    }
}
