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
        let topic = "Find my previous report"
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
    }
}
