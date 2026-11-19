import UIKit
import XCTest

final class CareJourneyUITests: XCTestCase {
    @MainActor
    func testPersonalConversationSurvivesRelaunch() throws {
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

        try openSyntheticDocument(in: app, emptyArchive: emptyArchive)
    }

    @MainActor
    private func openSyntheticDocument(in app: XCUIApplication, emptyArchive: XCUIElement) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Example-report.pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 500))
        try renderer.writePDF(to: url) { context in
            context.beginPage()
            ("Synthetic archive test" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: nil)
        }

        app.open(url)
        let cancel = app.buttons["care.incoming.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()
        XCTAssertTrue(emptyArchive.waitForExistence(timeout: 5))

        app.open(url)
        let save = app.buttons["care.incoming.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        save.tap()
        let original = app.buttons.matching(NSPredicate(
            format: "identifier == %@ AND label == %@", "care.history.original", "Открыть оригинал: " + url.lastPathComponent
        )).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 10))
        original.tap()
        XCTAssertTrue(app.navigationBars[url.lastPathComponent].waitForExistence(timeout: 5))
        app.buttons["Готово"].tap()
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Личный диалог — найденный вымышленный документ"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
