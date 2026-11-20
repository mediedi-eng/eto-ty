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

    func listen(endOnSilence: Bool, onPartial: @escaping (String) -> Void,
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

/// Emits the same recording/upload boundary as the real service without using its microphone or network.
@MainActor
final class UITestRecordedVoiceAudio: RecordedVoiceDriving {
    private var work: Task<Void, Never>?
    private var finish: (() -> Void)?
    private var didGreet = false

    func listen(endOnSilence: Bool, onRecordingStarted: @escaping () -> Void,
                onTranscribing: @escaping () -> Void,
                onFinal: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        stop()
        onRecordingStarted()
        finish = { [weak self] in
            guard let self else { return }
            onTranscribing()
            self.work = Task {
                do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
                onFinal(endOnSilence ? "Привет!" : "Тест диктовки.")
            }
        }
        if endOnSilence && !didGreet {
            didGreet = true
            work = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                self?.finishListening()
            }
        }
    }

    func finishListening() {
        let action = finish
        finish = nil
        action?()
    }

    func stop() {
        work?.cancel()
        work = nil
        finish = nil
    }
}
#endif
