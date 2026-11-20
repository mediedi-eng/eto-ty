#if DEBUG && targetEnvironment(simulator) && os(iOS)
import Foundation

/// Drives the real conversation UI in a fresh simulator without opening its microphone.
@MainActor
final class UITestVoiceAudio: VoiceAudioDriving {
    private var greeted = false
    private var work: Task<Void, Never>?
    private var finishCapture: (() -> Void)?
    private let realSpeech: VoiceAudio? = ProcessInfo.processInfo.arguments.contains("--eto-ty-ui-test-native-tts")
        ? VoiceAudio() : nil

    func listen(allowNetwork: Bool, endOnSilence: Bool, onPartial: @escaping (String) -> Void,
                onFinal: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        stop()
        if !endOnSilence {
            finishCapture = { onFinal("Тест диктовки.") }
            onPartial("Тест диктовки")
        } else if !greeted {
            greeted = true
            work = Task {
                do { try await Task.sleep(nanoseconds: 450_000_000) } catch { return }
                onFinal("Привет!")
            }
        } else {
            onPartial("Второй тестовый ход")
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
