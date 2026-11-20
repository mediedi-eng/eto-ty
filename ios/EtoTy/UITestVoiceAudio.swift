#if DEBUG && targetEnvironment(simulator) && os(iOS)
import Foundation

/// Drives the real conversation UI in a fresh simulator without opening its microphone.
@MainActor
final class UITestVoiceAudio: VoiceAudioDriving {
    private var capture = 0
    private var work: Task<Void, Never>?
    private var finishCapture: (() -> Void)?
    private let realSpeech: VoiceAudio? = ProcessInfo.processInfo.arguments.contains("--eto-ty-ui-test-native-tts")
        ? VoiceAudio() : nil

    func listen(allowNetwork: Bool, onPartial: @escaping (String) -> Void,
                onFinal: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        stop()
        capture += 1
        if realSpeech != nil {
            if capture == 1 {
                work = Task {
                    do { try await Task.sleep(nanoseconds: 450_000_000) } catch { return }
                    onFinal("Привет!")
                }
            } else {
                // A distinct partial proves a second listening turn began after Apple's completion callback.
                onPartial("Второй тестовый ход")
            }
            return
        }
        switch capture {
        case 1:
            // Manual dictation only finishes when the user taps the microphone again.
            finishCapture = { onFinal("Тест диктовки.") }
            onPartial("Тест диктовки")
        case 2:
            // In conversation mode the recognizer signals the end of an utterance.
            work = Task {
                do { try await Task.sleep(nanoseconds: 450_000_000) } catch { return }
                onFinal("Привет!")
            }
        default:
            // Wait in silence so the test can hang up the next listening turn.
            break
        }
    }

    func finishListening() {
        let finish = finishCapture
        stop()
        finish?()
    }

    func speak(_ text: String, onFinished: @escaping () -> Void, onError: @escaping (String) -> Void) {
        stop()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            onError("Пустой текст для озвучивания.")
            return
        }
        if let realSpeech {
            realSpeech.speak(text, onFinished: onFinished, onError: onError)
            return
        }
        work = Task {
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            onFinished()
        }
    }

    func stop() {
        work?.cancel()
        realSpeech?.stop()
        work = nil
        finishCapture = nil
    }
}
#endif
