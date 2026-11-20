import AVFAudio
import XCTest

final class VoiceConversationUITests: XCTestCase {
    @MainActor
    func testDictationAndHandsFreeInPersonalDialog() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments.append("--eto-ty-ui-test-voice")
        app.launch()

        let elements = app.descendants(matching: .any)
        useLocalReplies(in: app)
        let composer = elements["care.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let unedited = elements.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
                                                    "care.message.user", "Тест диктовки."))
        let initialCount = unedited.count
        let mic = app.buttons["care.voice.mic"]
        mic.tap()
        acceptLocalVoiceIfNeeded(in: app)
        let phase = elements["care.voice.phase"]
        waitFor("listening", in: phase)
        mic.tap()
        waitFor("Тест диктовки.", in: composer)
        XCTAssertEqual(unedited.count, initialCount, "Dictation should leave the recognized text in the draft.")

        let marker = "voice" + String(Int.random(in: 10000...99999))
        composer.tap()
        composer.typeText(" " + marker)
        app.buttons["care.send"].tap()
        let edited = elements.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
                                                  "care.message.user", marker)).firstMatch
        XCTAssertTrue(edited.waitForExistence(timeout: 5))

        let call = app.buttons["care.voice.call"]
        call.tap()
        acceptLocalVoiceIfNeeded(in: app)
        waitFor("speaking", in: phase)
        let greeting = elements.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
                                                    "care.message.service", "Привет!")).firstMatch
        XCTAssertTrue(greeting.exists, "The simulated audio driver should read the delivered reply.")
        waitFor("listening", in: phase)
        call.tap()
        let ended = NSPredicate(format: "exists == false OR value == %@", "idle")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ended, object: phase)],
                                     timeout: 5), .completed)
        XCTAssertTrue(mic.isEnabled)
    }

    @MainActor
    func testAppleSpeechCompletionResumesListening() throws {
        continueAfterFailure = false
        try XCTSkipIf(AVSpeechSynthesisVoice(language: "ru-RU") == nil,
                      "The iOS simulator has no ru-RU synthesis voice installed.")
        let app = XCUIApplication()
        app.launchArguments += ["--eto-ty-ui-test-voice", "--eto-ty-ui-test-native-tts"]
        app.launch()
        useLocalReplies(in: app)
        let call = app.buttons["care.voice.call"]
        call.tap()
        acceptLocalVoiceIfNeeded(in: app)

        // Only Apple's didFinish of the nonempty, delivered response can start the second capture.
        let resumed = app.staticTexts["Второй тестовый ход"]
        XCTAssertTrue(resumed.waitForExistence(timeout: 35),
                      "The production speech driver did not complete the utterance in the simulator.")
        waitFor("listening", in: app.descendants(matching: .any)["care.voice.phase"])
        call.tap()
        XCTAssertTrue(app.buttons["care.voice.mic"].isEnabled)
    }

    private func useLocalReplies(in app: XCUIApplication) {
        let settings = app.buttons["care.cloud.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        if settings.label == "Только на iPhone" { return }
        settings.tap()
        let option = app.buttons.matching(NSPredicate(
            format: "label == %@ AND identifier != %@", "Только на iPhone", "care.cloud.settings"
        )).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
    }

    private func acceptLocalVoiceIfNeeded(in app: XCUIApplication) {
        let accept = app.buttons["care.voice.consent.local"]
        if accept.waitForExistence(timeout: 1.5) { accept.tap() }
    }

    private func waitFor(_ value: String, in element: XCUIElement) {
        let matches = NSPredicate(format: "exists == true AND value == %@", value)
        let reached = XCTNSPredicateExpectation(predicate: matches, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [reached], timeout: 8), .completed,
                       "Expected \(element.identifier) to reach the requested state.")
    }
}
