import XCTest

final class CareJourneyUITests: XCTestCase {
    @MainActor
    func testPersonalConversationSurvivesRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        let guidance = app.buttons["Что проверить?"]
        XCTAssertTrue(guidance.waitForExistence(timeout: 10))
        guidance.tap()
        XCTAssertTrue(app.navigationBars["Что проверить?"].waitForExistence(timeout: 5))
        app.buttons["Закрыть"].tap()

        let composer = app.descendants(matching: .any)["care.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let topic = "Prepare for my visit"
        composer.tap()
        composer.typeText(topic)
        app.buttons["care.send"].tap()

        let sentMessage = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "care.message.user", topic)
        ).firstMatch
        XCTAssertTrue(sentMessage.waitForExistence(timeout: 5))
        let chooseTime = app.buttons["Выбрать время"]
        XCTAssertTrue(chooseTime.waitForExistence(timeout: 5))
        chooseTime.tap()
        XCTAssertTrue(app.navigationBars["Следующий контакт"].waitForExistence(timeout: 5))
        let weekly = app.switches["care.schedule.weekly"]
        XCTAssertTrue(weekly.waitForExistence(timeout: 5))
        XCTAssertEqual(weekly.value as? String, "0")
        weekly.tap()
        XCTAssertEqual(weekly.value as? String, "1")
        app.buttons["Отмена"].tap()
        chooseTime.tap()
        XCTAssertTrue(weekly.waitForExistence(timeout: 5))
        XCTAssertEqual(weekly.value as? String, "0")
        app.buttons["Отмена"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(sentMessage.waitForExistence(timeout: 10))

        let level = app.tabBars.buttons["Мой уровень"]
        XCTAssertTrue(level.waitForExistence(timeout: 5))
        level.tap()
        XCTAssertTrue(app.navigationBars["Мой уровень"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Карта тела"].tap()
        XCTAssertTrue(app.navigationBars["Карта тела"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Диалог"].tap()
        composer.tap()
        composer.typeText("Покажи мои документы")
        app.buttons["care.send"].tap()
        let emptyArchive = app.staticTexts["Сохранённых документов пока нет."]
        XCTAssertTrue(emptyArchive.waitForExistence(timeout: 5))

        app.buttons["Открыть и добавить документы"].tap()
        XCTAssertTrue(app.navigationBars["Мои документы"].waitForExistence(timeout: 5))
        for title in ["Сканировать документ", "Выбрать файл", "Выбрать фото"] {
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5), title)
        }
        app.buttons["Готово"].tap()
        XCTAssertTrue(emptyArchive.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Личный диалог — поиск в пустом архиве"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
