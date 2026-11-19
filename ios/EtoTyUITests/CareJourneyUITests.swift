import UIKit
import XCTest

final class CareJourneyUITests: XCTestCase {
    @MainActor
    func testPersonalConversationSurvivesRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        startPersonalPrevention(in: app)

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
        waitForValue("0", of: weekly)
        weekly.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        waitForValue("1", of: weekly)
        app.buttons["Отмена"].tap()
        chooseTime.tap()
        let reopenedWeekly = app.switches["care.schedule.weekly"]
        XCTAssertTrue(reopenedWeekly.waitForExistence(timeout: 5))
        waitForValue("0", of: reopenedWeekly)
        app.buttons["Отмена"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(sentMessage.waitForExistence(timeout: 10))
        checkPreventionSurvivesRelaunch(in: app)

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

        seedSyntheticDocument(in: app)
        checkBriefFromBodyMap(in: app)
    }

    private func waitForValue(_ value: String, of element: XCUIElement) {
        let predicate = NSPredicate(format: "value == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    @MainActor
    private func startPersonalPrevention(in app: XCUIApplication) {
        let guidance = app.buttons["care.preparation.open"]
        XCTAssertTrue(guidance.waitForExistence(timeout: 10))
        guidance.tap()
        XCTAssertTrue(app.navigationBars["Что проверить?"].waitForExistence(timeout: 5))

        let record = app.buttons["care.preparation.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.tap()
        XCTAssertTrue(app.navigationBars["Последнее измерение"].waitForExistence(timeout: 5))
        let noRecord = app.buttons["care.preparation.record.noRecord"]
        XCTAssertTrue(noRecord.waitForExistence(timeout: 5))
        noRecord.tap()

        let context = app.buttons["care.preparation.context"]
        XCTAssertTrue(context.waitForExistence(timeout: 5))
        context.tap()
        XCTAssertTrue(app.navigationBars["Моя ситуация"].waitForExistence(timeout: 5))
        let adultContext = app.buttons["care.preparation.context.adultWithoutKnownHypertension"]
        XCTAssertTrue(adultContext.waitForExistence(timeout: 5))
        adultContext.tap()

        let step = app.descendants(matching: .any)["care.preparation.step"]
        XCTAssertTrue(step.waitForExistence(timeout: 5))
        XCTAssertTrue(step.label.contains("вопрос врачу"))
        let saveQuestion = app.buttons["care.preparation.saveQuestion"]
        if !saveQuestion.isHittable { app.swipeUp() }
        saveQuestion.tap()
        XCTAssertTrue(app.descendants(matching: .any)["care.preparation.saved"].waitForExistence(timeout: 5))

        let start = app.buttons["care.preparation.start"]
        if !start.isHittable { app.swipeDown() }
        XCTAssertTrue(start.waitForExistence(timeout: 5) && start.isHittable)
        start.tap()
        XCTAssertTrue(app.buttons["Выбрать время"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func checkPreventionSurvivesRelaunch(in app: XCUIApplication) {
        let guidance = app.buttons["care.preparation.open"]
        XCTAssertTrue(guidance.waitForExistence(timeout: 5))
        guidance.tap()
        XCTAssertTrue(app.descendants(matching: .any)["care.preparation.saved"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["care.preparation.context"].label.contains("гипертонию не диагностировали"))
        app.buttons["Закрыть"].tap()
    }

    @MainActor
    private func checkBriefFromBodyMap(in app: XCUIApplication) {
        app.tabBars.buttons["Карта тела"].tap()
        app.buttons["Почки"].tap()
        let brief = app.buttons["Сводка к приёму"]
        if !brief.isHittable { app.swipeUp() }
        brief.tap()

        let area = app.buttons["brief.area"]
        XCTAssertTrue(area.waitForExistence(timeout: 5))
        area.tap()
        chooseBriefArea("Почки", in: app)
        let empty = app.descendants(matching: .any)["brief.area.empty"]
        if !empty.isHittable { app.swipeUp() }
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        let preview = app.buttons["brief.preview"]
        XCTAssertFalse(preview.isEnabled)

        app.buttons["brief.area"].tap()
        chooseBriefArea("Все области", in: app)
        let document = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Example-report.png")).firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        waitForValue("0", of: document)
        document.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        waitForValue("1", of: document)
        XCTAssertTrue(preview.isEnabled)
        app.buttons["brief.area"].tap()
        chooseBriefArea("Почки", in: app)
        waitForValue("1", of: document)
        if !preview.isHittable { app.swipeUp() }
        preview.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Example-report.png")).firstMatch.waitForExistence(timeout: 5))
    }

    private func chooseBriefArea(_ title: String, in app: XCUIApplication) {
        let choice = app.collectionViews.buttons[title].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
    }

    @MainActor
    private func seedSyntheticDocument(in app: XCUIApplication) {
        app.terminate()
        app.launchEnvironment["ETO_TY_UI_TEST_SEED_DOCUMENT"] = "1"
        app.launchArguments.append("--eto-ty-ui-test-seed-document")
        app.launch()
        app.launchEnvironment.removeValue(forKey: "ETO_TY_UI_TEST_SEED_DOCUMENT")
        app.launchArguments.removeAll { $0 == "--eto-ty-ui-test-seed-document" }
        let original = app.buttons.matching(NSPredicate(
            format: "identifier == %@ AND label == %@", "care.history.original", "Открыть оригинал: Example-report.png"
        )).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Личный диалог — найденный вымышленный документ"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
