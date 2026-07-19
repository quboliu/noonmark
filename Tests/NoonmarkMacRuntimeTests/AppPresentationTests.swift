import Foundation
import NoonmarkCore
@testable import NoonmarkMacRuntime
import XCTest

final class AppPresentationTests: XCTestCase {
    func testApplicationLanguageOwnsTheSwiftUISystemControlLocale() {
        XCTAssertEqual(
            AppPresentation(language: .chinese).interfaceLocale.identifier,
            "zh-Hans-SG"
        )
        XCTAssertEqual(
            AppPresentation(language: .english).interfaceLocale.identifier,
            "en-SG"
        )
    }

    func testClassificationManagerCopyCoversVisibleAndAccessibilityText() {
        let chinese = AppPresentation(language: .chinese).classificationManager
        let english = AppPresentation(language: .english).classificationManager

        XCTAssertEqual(chinese.title, "分组与标签管理")
        XCTAssertEqual(english.title, "Manage Groups & Tags")
        XCTAssertEqual(chinese.kindTitle(.category, count: 2), "分组  2")
        XCTAssertEqual(english.kindTitle(.label, count: 3), "Tags  3")
        XCTAssertEqual(chinese.searchPlaceholder(.label), "搜索标签")
        XCTAssertEqual(english.searchPlaceholder(.category), "Search groups")
        XCTAssertEqual(
            chinese.emptyActiveMessage(.category, isSearching: false),
            "还没有使用中的项目"
        )
        XCTAssertEqual(
            english.emptyActiveMessage(.label, isSearching: true),
            "No matching active tags"
        )

        let chineseInventory = [
            chinese.subtitle,
            chinese.kindPickerTitle,
            chinese.closeAccessibilityLabel,
            chinese.selectedMetricVerification(.category),
            chinese.clearSearchAccessibilityLabel,
            chinese.newItemAction(.label),
            chinese.namePlaceholder(.category),
            chinese.createAction,
            chinese.colorTitle,
            chinese.chooseColorAccessibilityLabel("#2A6FDB"),
            chinese.usageRule(.label),
            chinese.activeSectionTitle,
            chinese.archivedSectionTitle,
            chinese.collapseAction,
            chinese.expandAction,
            chinese.nameEditorPlaceholder,
            chinese.saveAction,
            chinese.cancelAction,
            chinese.currentReferenceCount(2),
            chinese.historicalReferenceCount(3),
            chinese.renameAction,
            chinese.archiveAction,
            chinese.restoreAction,
            chinese.referencedItemsArchiveOnlyNotice,
            chinese.discardAction,
            chinese.historyNotice
        ]
        let englishInventory = [
            english.subtitle,
            english.kindPickerTitle,
            english.closeAccessibilityLabel,
            english.selectedMetricVerification(.category),
            english.clearSearchAccessibilityLabel,
            english.newItemAction(.label),
            english.namePlaceholder(.category),
            english.createAction,
            english.colorTitle,
            english.chooseColorAccessibilityLabel("#2A6FDB"),
            english.usageRule(.label),
            english.activeSectionTitle,
            english.archivedSectionTitle,
            english.collapseAction,
            english.expandAction,
            english.nameEditorPlaceholder,
            english.saveAction,
            english.cancelAction,
            english.currentReferenceCount(2),
            english.historicalReferenceCount(3),
            english.renameAction,
            english.archiveAction,
            english.restoreAction,
            english.referencedItemsArchiveOnlyNotice,
            english.discardAction,
            english.historyNotice
        ]
        XCTAssertTrue(chineseInventory.allSatisfy { $0.isEmpty == false })
        XCTAssertTrue(englishInventory.allSatisfy { $0.isEmpty == false })
        XCTAssertEqual(chineseInventory.count, englishInventory.count)
        XCTAssertTrue(
            zip(chineseInventory, englishInventory).allSatisfy {
                $0.0 != $0.1
            }
        )
    }

    func testClassificationEditorAndBadgeCopyRespectLanguage() {
        let chineseEditor = AppPresentation(language: .chinese)
            .taskClassificationEditor
        let englishEditor = AppPresentation(language: .english)
            .taskClassificationEditor
        XCTAssertEqual(chineseEditor.noGroup, "无分组")
        XCTAssertEqual(englishEditor.noGroup, "No group")
        XCTAssertEqual(
            chineseEditor.duplicateTagError("专注"),
            "标签「专注」已经添加。"
        )
        XCTAssertEqual(
            englishEditor.duplicateTagError("Focus"),
            "The tag “Focus” is already added."
        )
        XCTAssertFalse(
            englishEditor.editorAccessibilityLabel(taskTitle: "Launch").contains("任务")
        )

        let editorInventory = [
            englishEditor.categoryTitle,
            englishEditor.labelTitle,
            englishEditor.groupNamePlaceholder,
            englishEditor.cancelAction,
            englishEditor.createAndAddAction,
            englishEditor.noGroupAction,
            englishEditor.newGroupAction,
            englishEditor.addAction,
            englishEditor.tagNamePlaceholder,
            englishEditor.emptyGroupNameError,
            englishEditor.emptyTagNameError,
            englishEditor.taskGroupAccessibilityLabel(taskTitle: "Launch"),
            englishEditor.currentGroupAccessibilityLabel("Work"),
            englishEditor.addTagAccessibilityLabel(taskTitle: "Launch"),
            englishEditor.savedAccessibilityLabel(taskTitle: "Launch"),
            englishEditor.removeTagAccessibilityLabel(
                taskTitle: "Launch",
                tagName: "Focus"
            ),
            englishEditor.taskTagAccessibilityLabel(
                taskTitle: "Launch",
                tagName: "Focus"
            ),
            englishEditor.saveFailedAccessibilityLabel("Try again")
        ]
        XCTAssertTrue(editorInventory.allSatisfy { $0.isEmpty == false })

        let chineseBadges = AppPresentation(language: .chinese)
            .taskClassificationBadges
        let englishBadges = AppPresentation(language: .english)
            .taskClassificationBadges
        XCTAssertEqual(chineseBadges.allTagsTitle, "全部标签")
        XCTAssertEqual(englishBadges.allTagsTitle, "All Tags")
        XCTAssertEqual(
            englishBadges.overflowAccessibilityLabel(
                taskTitle: "Launch",
                totalCount: 3,
                hiddenCount: 1
            ),
            "Show all 3 tags for “Launch”; 1 is currently hidden"
        )
        XCTAssertTrue(
            englishBadges.containerAccessibilityLabel(
                taskTitle: "Launch",
                isHistorical: true
            ).hasPrefix("Historical")
        )
        XCTAssertFalse(
            englishBadges.taskGroupAccessibilityLabel(
                taskTitle: "Launch",
                groupName: "Work"
            ).contains("任务")
        )
        XCTAssertFalse(
            englishBadges.taskTagAccessibilityLabel(
                taskTitle: "Launch",
                tagName: "Focus"
            ).contains("标签")
        )
        XCTAssertEqual(
            englishBadges.allTagsAccessibilityLabel(taskTitle: "Launch"),
            "All tags for “Launch”"
        )
    }

    func testGroupManagementCopyIsCompleteInChineseAndEnglish() {
        let chinese = AppPresentation(language: .chinese).groupManagement
        let english = AppPresentation(language: .english).groupManagement

        XCTAssertEqual(chinese.title, "分组与标签")
        XCTAssertEqual(chinese.subtitle, "用一个分组建立结构，再用标签补充横向线索。")
        XCTAssertEqual(chinese.categoryTitle, "分组")
        XCTAssertEqual(chinese.labelTitle, "标签")
        XCTAssertEqual(chinese.metricTitle(.category), "分组")
        XCTAssertEqual(chinese.metricTitle(.label), "标签")
        XCTAssertEqual(chinese.manageAction, "管理分组与标签")
        XCTAssertEqual(chinese.manageShortAction, "管理")

        XCTAssertEqual(english.title, "Groups & Tags")
        XCTAssertEqual(
            english.subtitle,
            "Use one group for structure, then add tags for cross-cutting context."
        )
        XCTAssertEqual(english.categoryTitle, "Groups")
        XCTAssertEqual(english.labelTitle, "Tags")
        XCTAssertEqual(english.metricTitle(.category), "Groups")
        XCTAssertEqual(english.metricTitle(.label), "Tags")
        XCTAssertEqual(english.manageAction, "Manage groups & tags")
        XCTAssertEqual(english.manageShortAction, "Manage")
    }

    func testGroupMetricAccessibilityLabelsRespectLanguageAndPlurality() {
        let chinese = AppPresentation(language: .chinese).groupManagement
        let english = AppPresentation(language: .english).groupManagement

        XCTAssertEqual(
            chinese.metricAccessibilityLabel(.category, count: 2),
            "2 个分组"
        )
        XCTAssertEqual(
            chinese.metricAccessibilityLabel(.label, count: 3),
            "3 个标签"
        )
        XCTAssertEqual(
            english.metricAccessibilityLabel(.category, count: 1),
            "1 group"
        )
        XCTAssertEqual(
            english.metricAccessibilityLabel(.category, count: 2),
            "2 groups"
        )
        XCTAssertEqual(
            english.metricAccessibilityLabel(.label, count: 1),
            "1 tag"
        )
        XCTAssertEqual(
            english.metricAccessibilityLabel(.label, count: 2),
            "2 tags"
        )
    }

    func testPresentationErrorsAreLocalizedWithoutUsingRawErrorDescription() {
        let rawError = SensitiveTestError()
        let typed = AppPresentation.classify(
            rawError,
            for: .classificationCatalog
        )
        let chinese = AppPresentation(language: .chinese).message(for: typed)
        let english = AppPresentation(language: .english).message(for: typed)

        XCTAssertEqual(typed, .classificationCatalogUnavailable)
        XCTAssertEqual(chinese, "暂时无法读取分组与标签，请稍后再试。")
        XCTAssertEqual(
            english,
            "Groups and tags are temporarily unavailable. Try again shortly."
        )
        XCTAssertFalse(chinese.contains(SensitiveTestError.rawDescription))
        XCTAssertFalse(english.contains(SensitiveTestError.rawDescription))
    }

    func testClassificationDomainErrorsMapToTypedPresentationFailures() {
        let invalidNameReasons = [
            "classification name cannot be empty",
            "classification name has no searchable Unicode content",
            "task category name already exists",
            "task label name already exists"
        ]
        for reason in invalidNameReasons {
            XCTAssertEqual(
                AppPresentation.classify(
                    NoonmarkError.invalidInput(reason),
                    for: .classificationMutation
                ),
                .invalidClassificationName
            )
        }
        XCTAssertEqual(
            AppPresentation.classify(
                NoonmarkError.invalidTitle,
                for: .classificationMutation
            ),
            .invalidClassificationName
        )
        XCTAssertEqual(
            AppPresentation.classify(
                NoonmarkError.lockedDay,
                for: .classificationMutation
            ),
            .classificationHistoryLocked
        )
        XCTAssertEqual(
            AppPresentation.classify(
                NoonmarkError.chainAbandoned,
                for: .classificationMutation
            ),
            .classificationTaskUnavailable
        )
        XCTAssertEqual(
            AppPresentation.classify(
                NoonmarkError.notFound("sensitive internal resource"),
                for: .classificationMutation
            ),
            .classificationResourceUnavailable
        )
        XCTAssertEqual(
            AppPresentation.classify(
                NoonmarkError.invalidTransition("sensitive domain detail"),
                for: .classificationMutation
            ),
            .classificationActionUnavailable
        )
    }

    func testUnknownClassificationFailureDoesNotLeakInternalDetail() {
        let internalDetail = "sensitive classification transaction detail"
        let typed = AppPresentation.classify(
            NoonmarkError.invalidInput(internalDetail),
            for: .classificationMutation
        )

        XCTAssertEqual(typed, .classificationActionUnavailable)
        XCTAssertFalse(
            AppPresentation(language: .chinese)
                .message(for: typed)
                .contains(internalDetail)
        )
        XCTAssertFalse(
            AppPresentation(language: .english)
                .message(for: typed)
                .contains(internalDetail)
        )
    }
}

private struct SensitiveTestError: LocalizedError {
    static let rawDescription = "SECRET_DATABASE_PATH"

    var errorDescription: String? {
        Self.rawDescription
    }
}
