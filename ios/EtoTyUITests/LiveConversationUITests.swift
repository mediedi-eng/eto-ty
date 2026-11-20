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
        let callConsent = app.buttons["care.voice.consent.cloudCall"]
        XCTAssertTrue(callConsent.waitForExistence(timeout: 8))
        callConsent.tap()
        XCTAssertTrue(replies.element(boundBy: 2).waitForExistence(timeout: 35), failureState(in: app))
        let phase = app.descendants(matching: .any)["care.voice.phase"]
        let isRecording = NSPredicate(format: "value == %@", "recording")
        let resumed = XCTNSPredicateExpectation(predicate: isRecording, object: phase)
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 12), .completed,
                       "After reading the service answer, hands-free mode should start the next recording.")
        XCTAssertEqual(replies.count, 3, "The voice turn should add one delivered service reply.")
        let newest = replies.allElementsBoundByIndex.last
        XCTAssertNotNil(newest)
        XCTAssertTrue(newest?.isHittable == true)
        let voiceFrame = XCTAttachment(screenshot: app.screenshot())
        voiceFrame.name = "Live-dialog-after-voice-reply"
        voiceFrame.lifetime = .keepAlways
        add(voiceFrame)
        app.buttons["care.voice.call"].tap()

        // Swap only the microphone source. The production iPhone driver must read the M4A,
        // POST its bytes, show what was actually transcribed, and wait for manual send.
        app.terminate()
        app.launchArguments = ["--eto-ty-ui-test-recorded-file"]
        app.launch()
        let microphone = app.buttons["care.voice.mic"]
        XCTAssertTrue(microphone.waitForExistence(timeout: 8))
        microphone.tap()
        let consent = app.buttons["care.voice.consent.cloud"]
        if consent.waitForExistence(timeout: 2) { consent.tap() }
        let recording = XCTNSPredicateExpectation(predicate: isRecording, object: phase)
        XCTAssertEqual(XCTWaiter.wait(for: [recording], timeout: 5), .completed)
        microphone.tap()

        let hasTranscript = NSPredicate(format: "value CONTAINS[c] %@ AND value CONTAINS[c] %@", "стол", "яблок")
        let draft = XCTNSPredicateExpectation(predicate: hasTranscript, object: composer)
        XCTAssertEqual(XCTWaiter.wait(for: [draft], timeout: 60), .completed,
                       "The real transcriber did not return the two expected words to the draft.")
        let postedTranscript = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND label CONTAINS[c] %@", "care.message.user", "яблок"
        )).firstMatch
        XCTAssertFalse(postedTranscript.exists, "Finishing a dictation must not send the draft into chat.")
        app.buttons["care.send"].tap()
        XCTAssertTrue(postedTranscript.waitForExistence(timeout: 6))
        // The list may recycle older offscreen bubbles. Look at the adjacent user/answer pair.
        let messages = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR identifier == %@", "care.message.user", "care.message.service"
        ))
        let delivered = NSPredicate { _, _ in
            let rows = messages.allElementsBoundByIndex
            guard let index = rows.firstIndex(where: {
                $0.identifier == "care.message.user" && $0.label.localizedCaseInsensitiveContains("яблок")
            }), index + 1 < rows.count else { return false }
            let next = rows[index + 1]
            return next.identifier == "care.message.service" && next.label.hasPrefix("Это ты · ИИ") && next.isHittable
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: delivered, object: app)],
                                     timeout: 35), .completed, failureState(in: app))
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
