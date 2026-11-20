#if ETO_TY_LIVE_SMOKE
import UIKit
import XCTest

final class LiveConversationUITests: XCTestCase {
    @MainActor
    func testTwoServiceRepliesSurviveRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        let settings = app.buttons["care.cloud.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 12))
        settings.tap()
        app.buttons["Сервис «Это ты»"].tap()
        XCTAssertTrue(app.staticTexts["care.chat.disclosure"].waitForExistence(timeout: 5))

        let composer = app.descendants(matching: .any)["care.composer"]
        let replies = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND label BEGINSWITH %@",
            "care.message.service", "Это ты · ИИ"
        ))
        XCTAssertEqual(replies.count, 0, "This opt-in scenario requires an empty simulator.")
        for message in ["Say hello in one word.", "Say goodbye in one word."] {
            composer.tap()
            composer.typeText(message)
            app.buttons["care.send"].tap()
        }

        let secondReply = replies.element(boundBy: 1)
        XCTAssertTrue(secondReply.waitForExistence(timeout: 65), failureState(in: app))
        XCTAssertTrue(secondReply.isHittable, "The newest service reply should be visible without scrolling.")
        XCTAssertFalse(app.descendants(matching: .any)["care.chat.pending"].exists)
        let beforeRelaunch = replies.allElementsBoundByIndex.map { $0.label }
        XCTAssertEqual(beforeRelaunch.count, 2)
        XCTAssertTrue(beforeRelaunch.allSatisfy { $0.count > "Это ты · ИИ".count + 2 })
        let frame = XCTAttachment(screenshot: app.screenshot())
        frame.name = "Live-dialog-two-synthetic-replies"
        frame.lifetime = .keepAlways
        add(frame)

        app.terminate()
        app.launchArguments.append("--eto-ty-ui-test-voice")
        app.launch()
        XCTAssertTrue(secondReply.waitForExistence(timeout: 12))
        XCTAssertTrue(replies.allElementsBoundByIndex.map { $0.label } == beforeRelaunch,
                      "Both delivered replies should survive relaunch in the same order.")
        XCTAssertFalse(app.descendants(matching: .any)["care.chat.pending"].exists)

        // Feed a synthetic recognized phrase through the real hosted service using the voice UI.
        app.buttons["care.voice.call"].tap()
        let localSpeech = app.buttons["care.voice.consent.local"]
        XCTAssertTrue(localSpeech.waitForExistence(timeout: 8))
        localSpeech.tap()
        XCTAssertTrue(app.staticTexts["Второй тестовый ход"].waitForExistence(timeout: 35),
                      failureState(in: app))
        XCTAssertEqual(replies.count, 3, "The voice turn should add one delivered service reply.")
        let newest = replies.allElementsBoundByIndex.last
        XCTAssertNotNil(newest)
        XCTAssertTrue(newest?.isHittable == true)
        let voiceFrame = XCTAttachment(screenshot: app.screenshot())
        voiceFrame.name = "Live-dialog-after-voice-reply"
        voiceFrame.lifetime = .keepAlways
        add(voiceFrame)
        app.buttons["care.voice.call"].tap()
    }

    @MainActor
    private func failureState(in app: XCUIApplication) -> String {
        let elements = app.descendants(matching: .any)
        let isPending = elements["care.chat.pending"].exists
        let canRetry = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "повтор")).count > 0
        return "Missing a delivered service reply. Pending indicator: \(isPending). Retry control: \(canRetry)."
    }
}
#endif
