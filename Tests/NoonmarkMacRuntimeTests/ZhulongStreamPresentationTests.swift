import Foundation
@testable import NoonmarkMacRuntime
import XCTest

@MainActor
final class ZhulongStreamPresentationTests: XCTestCase {
    func testDefaultIsIndependentConversationView() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = ZhulongStreamViewRepository(defaults: defaults)

        XCTAssertEqual(repository.load(), .conversation)
        XCTAssertEqual(ZhulongStreamView.allCases, [.conversation, .dossier, .chapters, .weave])
    }

    func testSelectionPersistsAndCorruptValueFailsClosed() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = ZhulongStreamViewRepository(defaults: defaults)

        repository.save(.weave)
        XCTAssertEqual(repository.load(), .weave)

        defaults.set("unknown", forKey: ZhulongStreamViewRepository.defaultStorageKey)
        XCTAssertEqual(repository.load(), .conversation)
    }

    func testEveryViewHasLocalizedDiscoverableCopy() {
        for view in ZhulongStreamView.allCases {
            XCTAssertFalse(view.title(language: .chinese).isEmpty)
            XCTAssertFalse(view.title(language: .english).isEmpty)
            XCTAssertFalse(view.purpose(language: .chinese).isEmpty)
            XCTAssertFalse(view.purpose(language: .english).isEmpty)
        }
    }

    private func makeDefaults() -> (String, UserDefaults) {
        let suiteName = "ZhulongStreamPresentationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }
}
