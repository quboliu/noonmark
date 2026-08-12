import XCTest

@MainActor
final class NoonmarkIOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testUserCanCreateAndPersistTodayTask() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ios-ui-test"]
        app.launch()

        let taskTitle = "iOS simulator persistence task"
        let composer = app.textFields["ios.composer.记录今天要推进的任务"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText(taskTitle)
        app.buttons["加入"].tap()

        XCTAssertTrue(app.staticTexts[taskTitle].waitForExistence(timeout: 10))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts[taskTitle].waitForExistence(timeout: 10))

        // The launch target is fixed by the generated iOS development scheme;
        // the test never launches the Mac production identity.
    }

    func testUserCanCreateRecurringPlanInSimulator() throws {
        let app = launchApp()
        openPage("recurring", in: app)

        XCTAssertTrue(app.buttons["新建重复计划"].waitForExistence(timeout: 10))
        app.buttons["新建重复计划"].tap()
        let title = app.textFields["ios.recurring.editor.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        title.typeText("iOS simulator recurring plan")
        let subtaskInput = app.textFields["ios.recurring.subtask.add"]
        XCTAssertTrue(subtaskInput.waitForExistence(timeout: 10))
        subtaskInput.tap()
        subtaskInput.typeText("iOS simulator recurring subtask")
        app.buttons["ios.recurring.subtask.addButton"].tap()
        app.buttons["ios.recurring.editor.save"].tap()

        let plan = app.staticTexts["iOS simulator recurring plan"]
        XCTAssertTrue(plan.waitForExistence(timeout: 10))
        app.buttons["编辑"].tap()
        XCTAssertTrue(app.staticTexts["iOS simulator recurring subtask"].waitForExistence(timeout: 10))
        app.buttons["取消"].tap()
        plan.tap()
        let summary = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH 'ios.recurring.scheduled.'")
        ).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
    }

    func testUserCanEditAndSearchFlylightInSimulator() throws {
        let app = launchApp()
        openPage("flylight", in: app)

        XCTAssertTrue(app.buttons["新建飞光"].waitForExistence(timeout: 10))
        app.buttons["新建飞光"].tap()
        let editor = app.textViews["ios.flylight.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText("iOS simulator flylight")
        app.navigationBars.buttons["保存"].tap()

        XCTAssertTrue(app.staticTexts["iOS simulator flylight"].waitForExistence(timeout: 10))
        let search = app.searchFields["搜索飞光"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("flylight")
        XCTAssertTrue(app.staticTexts["iOS simulator flylight"].waitForExistence(timeout: 10))
    }

    func testUserCanPinDeleteAndPersistFlylightInSimulator() throws {
        let app = launchApp()
        openPage("flylight", in: app)

        let body = "iOS simulator flylight lifecycle"
        let createButton = app.buttons["新建飞光"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 10))
        createButton.tap()
        let editor = app.textViews["ios.flylight.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        typeTextReliably(body, into: editor)
        app.navigationBars.buttons["保存"].tap()
        let idea = app.staticTexts[body]
        XCTAssertTrue(idea.waitForExistence(timeout: 10))

        let stickyActions = app.buttons.matching(
            NSPredicate(format: "label == %@", "加入 Sticky Note")
        ).allElementsBoundByIndex
        XCTAssertFalse(stickyActions.isEmpty)
        // Flylight is ordered newest-first; the newly created entry owns the
        // first action even when this suite preserves earlier test data.
        stickyActions.first?.tap()
        XCTAssertTrue(
            app.staticTexts[body].waitForExistence(timeout: 10),
            "Flylight source disappeared after Sticky Note action. Accessibility hierarchy:\n\(app.debugDescription)"
        )
        openPage("stickyNotes", in: app)
        let stickyDetail = app.descendants(matching: .any)
            .matching(identifier: "ios.detail.stickyNotes")
            .firstMatch
        XCTAssertTrue(
            stickyDetail.waitForExistence(timeout: 5),
            "Sticky Note detail identity did not appear. Accessibility hierarchy:\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            app.navigationBars["Sticky Note"].waitForExistence(timeout: 10),
            "Sticky Note page did not appear. Accessibility hierarchy:\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            app.staticTexts[body].waitForExistence(timeout: 10),
            "Sticky Note body was not rendered. Accessibility hierarchy:\n\(app.debugDescription)"
        )
        let wallButton = app.buttons["便签墙"]
        XCTAssertTrue(
            wallButton.waitForExistence(timeout: 5),
            "Sticky Note wall control was not rendered. Accessibility hierarchy:\n\(app.debugDescription)"
        )
        wallButton.tap()
        XCTAssertTrue(
            app.staticTexts[body].waitForExistence(timeout: 10),
            "Sticky Note wall did not render the pinned source. Accessibility hierarchy:\n\(app.debugDescription)"
        )
        let streamButton = app.buttons["清单流"]
        XCTAssertTrue(streamButton.waitForExistence(timeout: 5))
        streamButton.tap()
        app.staticTexts[body].swipeLeft()
        XCTAssertTrue(app.buttons["移出"].waitForExistence(timeout: 5))
        app.buttons["移出"].tap()

        openPage("flylight", in: app)
        XCTAssertTrue(app.staticTexts[body].waitForExistence(timeout: 10))
        let deleteAction = app.buttons["ios.flylight.delete.\(body)"]
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 5))
        deleteAction.tap()
        XCTAssertFalse(
            app.staticTexts[body].waitForExistence(timeout: 2),
            "Deleted Flylight remained visible in the active collection. Accessibility hierarchy:\n\(app.debugDescription)"
        )

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["打开目录"].waitForExistence(timeout: 10))
        openPage("flylight", in: app)
        XCTAssertFalse(
            app.staticTexts[body].waitForExistence(timeout: 2),
            "Deleted Flylight reappeared after restart. Accessibility hierarchy:\n\(app.debugDescription)"
        )
    }

    func testUserCanClassifyAndPersistTaskInSimulator() throws {
        let app = launchApp()
        let categoryName = "iOS simulator category"
        let taskTitle = "iOS simulator classified task"

        openPage("settings", in: app)
        let classificationButton = app.buttons["查看分类与标签"]
        for _ in 0 ..< 3 where classificationButton.exists == false {
            app.swipeUp()
        }
        XCTAssertTrue(classificationButton.waitForExistence(timeout: 10))
        classificationButton.tap()
        XCTAssertTrue(app.buttons["ios.classification.catalog.add"].waitForExistence(timeout: 10))
        app.buttons["ios.classification.catalog.add"].tap()
        XCTAssertTrue(app.buttons["ios.classification.catalog.create-category"].waitForExistence(timeout: 5))
        app.buttons["ios.classification.catalog.create-category"].tap()

        let categoryEditor = app.textFields["ios.classification.editor.name"]
        XCTAssertTrue(categoryEditor.waitForExistence(timeout: 5))
        categoryEditor.tap()
        categoryEditor.typeText(categoryName)
        app.buttons["ios.classification.editor.save"].tap()
        XCTAssertTrue(app.staticTexts[categoryName].waitForExistence(timeout: 10))
        app.buttons["完成"].tap()

        openPage("day", in: app)
        let composer = app.textFields["ios.composer.记录今天要推进的任务"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText(taskTitle)
        app.buttons["加入"].tap()
        app.staticTexts[taskTitle].tap()

        XCTAssertTrue(app.buttons["ios.classification.category"].waitForExistence(timeout: 10))
        app.buttons["ios.classification.category"].tap()
        XCTAssertTrue(app.buttons[categoryName].waitForExistence(timeout: 5))
        app.buttons[categoryName].tap()
        XCTAssertTrue(app.staticTexts[categoryName].waitForExistence(timeout: 10))

        app.buttons["完成"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts[taskTitle].waitForExistence(timeout: 10))
        app.staticTexts[taskTitle].tap()
        XCTAssertTrue(app.staticTexts[categoryName].waitForExistence(timeout: 10))
    }

    func testUserCanSearchArchiveRestoreAndDeleteClassificationInSimulator() throws {
        let app = launchApp()
        let labelName = "iOS simulator disposable label \(UUID().uuidString.prefix(8))"

        openPage("settings", in: app)
        let classificationButton = app.buttons["查看分类与标签"]
        for _ in 0 ..< 3 where classificationButton.exists == false {
            app.swipeUp()
        }
        XCTAssertTrue(classificationButton.waitForExistence(timeout: 10))
        classificationButton.tap()
        XCTAssertTrue(app.buttons["ios.classification.catalog.add"].waitForExistence(timeout: 10))
        app.buttons["ios.classification.catalog.add"].tap()
        XCTAssertTrue(app.buttons["ios.classification.catalog.create-label"].waitForExistence(timeout: 5))
        app.buttons["ios.classification.catalog.create-label"].tap()

        let editor = app.textFields["ios.classification.editor.name"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        typeTextReliably(labelName, into: editor)
        app.buttons["ios.classification.editor.save"].tap()

        let search = app.searchFields["搜索分类与标签"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        typeTextReliably("disposable", into: search)
        XCTAssertTrue(app.staticTexts[labelName].waitForExistence(timeout: 10))
        let searchKeyboardButton = app.keyboards.buttons["search"]
        if searchKeyboardButton.exists {
            searchKeyboardButton.tap()
        }
        let closeSearchButton = app.buttons["close"]
        XCTAssertTrue(closeSearchButton.waitForExistence(timeout: 5))
        closeSearchButton.tap()

        let label = app.staticTexts[labelName]
        XCTAssertTrue(scrollUntilExists(label, in: app))
        label.swipeLeft()
        let archiveAction = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'ios.classification.archive.'")
        ).firstMatch
        XCTAssertTrue(archiveAction.waitForExistence(timeout: 5))
        archiveAction.tap()
        let saveAlert = app.alerts["无法保存"]
        if saveAlert.waitForExistence(timeout: 2) {
            let message = saveAlert.staticTexts.allElementsBoundByIndex
                .map(\.label)
                .joined(separator: " | ")
            XCTFail("分类归档提交失败并弹出保存错误：\(message)")
        }
        XCTAssertFalse(app.staticTexts[labelName].waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.buttons["ios.classification.catalog.archived-toggle"].waitForExistence(timeout: 5),
            "归档后分类目录 sheet 已消失。Accessibility hierarchy:\n\(app.debugDescription)"
        )

        app.buttons["ios.classification.catalog.archived-toggle"].tap()
        XCTAssertTrue(scrollUntilExists(label, in: app))
        label.swipeLeft()
        let restoreAction = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'ios.classification.restore.'")
        ).firstMatch
        XCTAssertTrue(restoreAction.waitForExistence(timeout: 5))
        restoreAction.tap()
        XCTAssertTrue(scrollUntilExists(label, in: app, resetToTop: true))

        label.swipeLeft()
        let hardDeleteAction = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'ios.classification.hard-delete.'")
        ).firstMatch
        XCTAssertTrue(hardDeleteAction.waitForExistence(timeout: 5))
        hardDeleteAction.tap()
        let deleteAlert = app.alerts.firstMatch
        XCTAssertTrue(
            deleteAlert.waitForExistence(timeout: 5),
            "硬删除确认 Alert 未出现。Accessibility hierarchy:\n\(app.debugDescription)"
        )
        let confirmDelete = deleteAlert.buttons["删除"]
        XCTAssertTrue(
            confirmDelete.waitForExistence(timeout: 5),
            "硬删除确认 Alert 没有“删除”按钮。Alert hierarchy:\n\(deleteAlert.debugDescription)"
        )
        confirmDelete.tap()
        XCTAssertFalse(app.staticTexts[labelName].waitForExistence(timeout: 5))
    }

    func testUserCanSaveDailyReviewAndReadItAfterRestartInSimulator() throws {
        let app = launchApp()
        openPage("calendar", in: app)
        let reviewButton = app.buttons["编辑日复盘"]
        for _ in 0 ..< 4 where reviewButton.exists == false {
            app.swipeUp()
        }
        XCTAssertTrue(reviewButton.waitForExistence(timeout: 10))
        reviewButton.tap()

        let summary = app.textFields["ios.daily.review.summary"]
        let unfinished = app.textFields["ios.daily.review.unfinished"]
        let tomorrow = app.textFields["ios.daily.review.tomorrow"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        summary.tap()
        summary.typeText("iOS simulator review summary")
        unfinished.tap()
        unfinished.typeText("iOS simulator review reason")
        tomorrow.tap()
        tomorrow.typeText("iOS simulator review tomorrow")
        app.buttons["ios.daily.review.save"].tap()

        app.terminate()
        app.launch()
        openPage("calendar", in: app)
        let reopenedReviewButton = app.buttons["编辑日复盘"]
        for _ in 0 ..< 4 where reopenedReviewButton.exists == false {
            app.swipeUp()
        }
        XCTAssertTrue(reopenedReviewButton.waitForExistence(timeout: 10))
        reopenedReviewButton.tap()
        XCTAssertEqual(app.textFields["ios.daily.review.summary"].value as? String, "iOS simulator review summary")
        XCTAssertEqual(app.textFields["ios.daily.review.unfinished"].value as? String, "iOS simulator review reason")
        XCTAssertEqual(app.textFields["ios.daily.review.tomorrow"].value as? String, "iOS simulator review tomorrow")
    }

    func testUserCanOpenAndCancelDataPackageFileFlowsInSimulator() throws {
        let app = launchApp()
        openPage("settings", in: app)

        let importButton = app.buttons["ios.data-package.import"]
        XCTAssertTrue(scrollUntilExists(importButton, in: app))
        importButton.tap()
        cancelDocumentPicker(in: app)
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))

        let exportButton = app.buttons["ios.data-package.export"]
        XCTAssertTrue(scrollUntilExists(exportButton, in: app, resetToTop: true))
        exportButton.tap()
        cancelDocumentPicker(in: app)
        XCTAssertTrue(exportButton.waitForExistence(timeout: 5))
    }

    func testUserCanOpenAndCancelDataPackageExportInSimulator() throws {
        let app = launchApp()
        openPage("settings", in: app)

        let exportButton = app.buttons["ios.data-package.export"]
        XCTAssertTrue(scrollUntilExists(exportButton, in: app))
        exportButton.tap()
        cancelDocumentPicker(in: app)
        XCTAssertTrue(exportButton.waitForExistence(timeout: 5))
    }

    func testUserCanEditTaskSubtaskAndTraceNoteInSimulator() throws {
        let app = launchApp()
        let taskTitle = "iOS simulator task detail parity"
        let subtaskTitle = "iOS simulator subtask"
        let renamedSubtask = "iOS simulator renamed subtask"
        let noteBody = "iOS simulator trace note"
        let editedNoteBody = "iOS simulator edited trace note"

        let composer = app.textFields["ios.composer.记录今天要推进的任务"]
        composer.tap()
        composer.typeText(taskTitle)
        app.buttons["加入"].tap()
        XCTAssertTrue(app.staticTexts[taskTitle].waitForExistence(timeout: 10))
        app.staticTexts[taskTitle].tap()

        XCTAssertTrue(app.textFields["ios.task.detail.title"].waitForExistence(timeout: 10))
        let subtaskInput = app.textFields["ios.task.detail.subtask.add"]
        subtaskInput.tap()
        subtaskInput.typeText(subtaskTitle)
        app.buttons["ios.task.detail.subtask.addButton"].tap()
        XCTAssertTrue(app.staticTexts[subtaskTitle].waitForExistence(timeout: 10))

        app.staticTexts[subtaskTitle].tap()
        let subtaskEditor = app.textFields["子任务名称"]
        XCTAssertTrue(subtaskEditor.waitForExistence(timeout: 5))
        replaceText(in: subtaskEditor, with: renamedSubtask, app: app)
        app.buttons["ios.task.detail.subtask.save"].tap()
        XCTAssertTrue(app.staticTexts[renamedSubtask].waitForExistence(timeout: 10))

        let noteInput = app.textFields["ios.task.detail.note.add"]
        noteInput.tap()
        noteInput.typeText(noteBody)
        app.buttons["ios.task.detail.note.addButton"].tap()
        XCTAssertTrue(app.staticTexts[noteBody].waitForExistence(timeout: 10))

        app.staticTexts[noteBody].swipeLeft()
        XCTAssertTrue(app.buttons["编辑"].waitForExistence(timeout: 5))
        app.buttons["编辑"].tap()
        let noteEditor = app.textViews["ios.note.editor"]
        XCTAssertTrue(noteEditor.waitForExistence(timeout: 5))
        replaceText(in: noteEditor, with: editedNoteBody, app: app)
        app.navigationBars.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts[editedNoteBody].waitForExistence(timeout: 10))

        app.staticTexts[editedNoteBody].swipeLeft()
        app.buttons["删除"].tap()
        XCTAssertFalse(app.staticTexts[editedNoteBody].waitForExistence(timeout: 2))
    }

    func testUserCanEditPoolPlannedSubtaskAndNoteInSimulator() throws {
        let app = launchApp()
        openPage("pool", in: app)

        let taskTitle = "iOS simulator pool detail parity"
        let subtaskTitle = "iOS simulator planned subtask"
        let renamedSubtask = "iOS simulator renamed planned subtask"
        let noteBody = "iOS simulator pool note"

        let composer = app.textFields["ios.composer.先放入任务池"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText(taskTitle)
        app.buttons["新增"].tap()
        XCTAssertTrue(app.staticTexts[taskTitle].waitForExistence(timeout: 10))
        app.staticTexts[taskTitle].tap()

        XCTAssertTrue(app.textFields["ios.pool.detail.title"].waitForExistence(timeout: 10))
        let subtaskInput = app.textFields["ios.pool.detail.subtask.add"]
        subtaskInput.tap()
        subtaskInput.typeText(subtaskTitle)
        app.buttons["ios.pool.detail.subtask.addButton"].tap()
        XCTAssertTrue(app.staticTexts[subtaskTitle].waitForExistence(timeout: 10))

        app.staticTexts[subtaskTitle].tap()
        let subtaskEditor = app.textFields["计划子任务名称"]
        XCTAssertTrue(subtaskEditor.waitForExistence(timeout: 5))
        replaceText(in: subtaskEditor, with: renamedSubtask, app: app)
        app.buttons["ios.pool.detail.subtask.save"].tap()
        XCTAssertTrue(app.staticTexts[renamedSubtask].waitForExistence(timeout: 10))

        let noteInput = app.textFields["ios.pool.detail.note.add"]
        noteInput.tap()
        noteInput.typeText(noteBody)
        app.buttons["ios.pool.detail.note.addButton"].tap()
        XCTAssertTrue(app.staticTexts[noteBody].waitForExistence(timeout: 10))

        app.staticTexts[noteBody].swipeLeft()
        XCTAssertTrue(app.buttons["删除"].waitForExistence(timeout: 5))
        app.buttons["删除"].tap()
        XCTAssertFalse(app.staticTexts[noteBody].waitForExistence(timeout: 2))
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--ios-ui-test"]
        app.launch()
        XCTAssertTrue(app.buttons["打开目录"].waitForExistence(timeout: 10))
        return app
    }

    private func openPage(_ page: String, in app: XCUIApplication) {
        let menuButton = app.buttons["打开目录"]
        XCTAssertTrue(menuButton.waitForExistence(timeout: 10))
        let hittable = NSPredicate(format: "exists == true AND hittable == true")
        XCTAssertEqual(
            XCTWaiter().wait(
                for: [XCTNSPredicateExpectation(predicate: hittable, object: menuButton)],
                timeout: 10
            ),
            .completed
        )
        menuButton.tap()
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 10))
        let pageIdentifier = "ios.page.\(page)"
        let windowFrame = app.windows.firstMatch.frame
        for _ in 0 ..< 12 {
            let pageButton = app.buttons[pageIdentifier]
            let buttonFrame = pageButton.frame
            let isVisible = pageButton.exists
                && buttonFrame.width > 0
                && buttonFrame.height > 0
                && buttonFrame.intersects(windowFrame)
            if isVisible {
                tapPageButton(pageButton, in: app)
                return
            }
            let collectionView = app.collectionViews.firstMatch
            if collectionView.exists, collectionView.isHittable {
                collectionView.swipeUp()
            } else {
                app.swipeUp()
            }
        }
        let pageButton = app.buttons[pageIdentifier]
        XCTAssertTrue(
            pageButton.exists
                && pageButton.frame.width > 0
                && pageButton.frame.height > 0
                && pageButton.frame.intersects(windowFrame),
            "Missing page button ios.page.\(page). Accessibility hierarchy:\n\(app.debugDescription)"
        )
        tapPageButton(pageButton, in: app)
    }

    private func tapPageButton(_ pageButton: XCUIElement, in app: XCUIApplication) {
        let windowFrame = app.windows.firstMatch.frame
        let buttonFrame = pageButton.frame
        let normalizedX = (buttonFrame.midX - windowFrame.minX) / windowFrame.width
        let normalizedY = (buttonFrame.midY - windowFrame.minY) / windowFrame.height
        guard windowFrame.width > 0,
              windowFrame.height > 0,
              normalizedX >= 0,
              normalizedX <= 1,
              normalizedY >= 0,
              normalizedY <= 1
        else {
            pageButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return
        }
        app.coordinate(
            withNormalizedOffset: CGVector(dx: normalizedX, dy: normalizedY)
        ).tap()
    }

    private func replaceText(in element: XCUIElement, with text: String, app: XCUIApplication) {
        element.tap()
        if (element.value as? String)?.isEmpty != false {
            element.typeText(text)
            return
        }
        element.press(forDuration: 1.0)
        let selectAll = app.menuItems.matching(
            NSPredicate(format: "label IN %@", ["全选", "选择全部", "Select All"])
        ).firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
        selectAll.tap()
        element.typeText(text)
    }

    private func typeTextReliably(_ text: String, into element: XCUIElement) {
        var chunk = ""
        for character in text {
            chunk.append(character)
            if chunk.count == 4 {
                element.typeText(chunk)
                chunk = ""
            }
        }
        if chunk.isEmpty == false {
            element.typeText(chunk)
        }
    }

    private func cancelDocumentPicker(in app: XCUIApplication) {
        let documentsApp = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        let labels = ["取消", "Cancel"]
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            for root in [documentsApp, app] {
                let cancel = root
                    .descendants(matching: .any)
                    .matching(NSPredicate(format: "label IN %@", labels))
                    .firstMatch
                if cancel.exists {
                    cancel.tap()
                    return
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }

        XCTAssertTrue(
            false,
            "文件面板没有取消按钮。App hierarchy:\n\(app.debugDescription)"
        )
    }

    private func scrollUntilExists(
        _ element: XCUIElement,
        in app: XCUIApplication,
        resetToTop: Bool = false
    ) -> Bool {
        let windowFrame = app.windows.firstMatch.frame
        if resetToTop {
            for _ in 0 ..< 4 {
                app.swipeDown()
            }
        }
        for _ in 0 ..< 12 {
            if element.exists {
                let frame = element.frame
                if frame.width > 0,
                   frame.height > 0,
                   frame.intersects(windowFrame)
                {
                    return true
                }
            }
            app.swipeUp()
        }
        guard element.exists else { return false }
        let frame = element.frame
        return frame.width > 0
            && frame.height > 0
            && frame.intersects(windowFrame)
    }
}
