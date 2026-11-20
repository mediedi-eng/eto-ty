#if os(iOS)
import AVFoundation
import Speech
import UIKit

/// Called on the audio render queue. Keep the tap independent of UI actor isolation.
private final class VoiceInput {
    let request = SFSpeechAudioBufferRecognitionRequest()
    private let lock = NSLock()
    private var open = true
    private var lastSound: TimeInterval = 0

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard open else { return }
        request.append(buffer)
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var energy: Float = 0
        let count = Int(buffer.frameLength)
        for i in stride(from: 0, to: count, by: 8) { energy += samples[i] * samples[i] }
        if energy > 0.000075 * Float((count + 7) / 8) { lastSound = ProcessInfo.processInfo.systemUptime }
    }

    func latestSound() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return lastSound
    }

    func close() {
        lock.lock()
        let needsEnd = open
        open = false
        lock.unlock()
        if needsEnd { request.endAudio() }
    }
}

private func makeVoiceTap(_ input: VoiceInput) -> AVAudioNodeTapBlock {
    { buffer, _ in input.append(buffer) }
}

private func speechPermission() async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
}

@MainActor
final class VoiceAudio: NSObject, AVSpeechSynthesizerDelegate {
    private let audio = AVAudioSession.sharedInstance()
    private let synth = AVSpeechSynthesizer()
    private var engine: AVAudioEngine?
    private var input: VoiceInput?
    private var recognizer: SFSpeechRecognizer?
    private var recognition: SFSpeechRecognitionTask?
    private var utterance: AVSpeechUtterance?
    private var token = UUID()
    private var timer: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var ownsSession = false
    private var lastText = ""
    private var lastPartialAt: TimeInterval = 0
    private var finishing = false
    private var partial: ((String) -> Void)?
    private var final: ((String) -> Void)?
    private var failure: ((String) -> Void)?
    private var spoken: (() -> Void)?
    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    override init() {
        super.init()
        synth.delegate = self
        synth.usesApplicationAudioSession = true
    }

    deinit {
        timer?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        input?.close()
        recognition?.cancel()
        synth.stopSpeaking(at: .immediate)
        if ownsSession { try? audio.setActive(false, options: .notifyOthersOnDeactivation) }
    }

    func listen(endOnSilence: Bool, onPartial: @escaping (String) -> Void,
                onFinal: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        stop()
        let id = token
        partial = onPartial
        final = onFinal
        failure = onError
        observeInterruptions(id)
        Task { [weak self] in
            let microphone = await AVAudioApplication.requestRecordPermission()
            guard let self, self.token == id else { return }
            guard microphone else {
                self.fail("Разреши доступ к микрофону для «Это ты» в настройках iPhone.")
                return
            }
            let authorization = await speechPermission()
            guard self.token == id else { return }
            guard authorization == .authorized else {
                self.fail("Разреши распознавание речи для «Это ты» в настройках iPhone.")
                return
            }
            self.startCapture(id, endOnSilence: endOnSilence)
        }
    }

    private func startCapture(_ id: UUID, endOnSilence: Bool) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU")),
              recognizer.isAvailable else {
            fail("Русское распознавание речи сейчас недоступно на этом iPhone.")
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            fail("Локальное распознавание русского языка недоступно. Можно ввести сообщение с клавиатуры.")
            return
        }
        self.recognizer = recognizer
        let source = VoiceInput()
        source.request.requiresOnDeviceRecognition = true
        source.request.shouldReportPartialResults = true
        source.request.taskHint = .dictation
        input = source
        do {
            try audio.setCategory(.record, mode: .measurement, options: [.allowBluetooth])
            try audio.setActive(true)
            ownsSession = true
            let capture = AVAudioEngine()
            let node = capture.inputNode
            let format = node.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0, audio.isInputAvailable else {
                fail("Микрофон сейчас недоступен. Проверь подключение гарнитуры или повтори запись.")
                return
            }
            node.installTap(onBus: 0, bufferSize: 1024, format: format, block: makeVoiceTap(source))
            engine = capture
            recognizer.queue = .main
            recognition = recognizer.recognitionTask(with: source.request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                let complete = result?.isFinal == true
                let failed = error != nil
                Task { @MainActor in
                    guard let self, self.token == id else { return }
                    if let text, !text.isEmpty, text != self.lastText {
                        self.lastText = text
                        self.lastPartialAt = self.uptime
                        self.partial?(text)
                    }
                    guard self.token == id else { return }
                    if complete || (failed && self.finishing) {
                        self.deliver()
                    } else if failed {
                        self.fail("Распознавание прервалось. Проверь текст и попробуй ещё раз.")
                    }
                }
            }
            capture.prepare()
            try capture.start()
            monitorSilence(id, from: uptime, endOnSilence: endOnSilence)
        } catch {
            fail("Не удалось включить микрофон. Проверь доступ и повтори запись.")
        }
    }

    private func monitorSilence(_ id: UUID, from start: TimeInterval, endOnSilence: Bool) {
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                guard let self, self.token == id else { return }
                let now = self.uptime
                let activity = max(self.lastPartialAt, self.input?.latestSound() ?? 0)
                let noSpeech = activity < start && now - start >= 12
                let endOfTurn = endOnSilence && activity >= start && now - activity >= 1.8
                if noSpeech || endOfTurn || now - start >= 55 {
                    self.finishListening()
                    return
                }
            }
        }
    }

    func finishListening() {
        guard final != nil, !finishing else { return }
        guard recognition != nil else {
            fail("Запись завершена до начала распознавания.")
            return
        }
        finishing = true
        stopMicrophone()
        input?.close()
        timer?.cancel()
        let id = token
        timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 2_500_000_000) } catch { return }
            guard let self, self.token == id else { return }
            self.deliver()
        }
    }

    private func deliver() {
        guard !lastText.isEmpty else {
            fail("Не удалось разобрать речь. Нажми микрофон и попробуй ещё раз.")
            return
        }
        let result = lastText
        let callback = final
        stop()
        callback?(result)
    }

    func speak(_ text: String, onFinished: @escaping () -> Void, onError: @escaping (String) -> Void) {
        stop()
        guard !text.isEmpty else { onFinished(); return }
        failure = onError
        spoken = onFinished
        let id = token
        observeInterruptions(id)
        do {
            try audio.setCategory(.playback, mode: .spokenAudio)
            try audio.setActive(true)
            ownsSession = true
        } catch {
            fail("Не удалось включить звук. Ответ доступен в диалоге.")
            return
        }
        guard let voice = AVSpeechSynthesisVoice(language: "ru-RU") else {
            fail("Русский голос озвучивания недоступен. Ответ сохранён в диалоге.")
            return
        }
        let speech = AVSpeechUtterance(string: text)
        speech.voice = voice
        utterance = speech
        synth.speak(speech)
        let seconds = min(600.0, max(30.0, Double(text.count) * 0.25 + 15))
        timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
            guard let self, self.token == id else { return }
            self.fail("Озвучивание прервалось. Ответ сохранён в диалоге.")
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, let current = self.utterance, ObjectIdentifier(current) == key else { return }
            let callback = self.spoken
            self.stop()
            callback?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, let current = self.utterance, ObjectIdentifier(current) == key else { return }
            self.fail("Озвучивание остановлено. Ответ доступен в диалоге.")
        }
    }

    private func observeInterruptions(_ id: UUID) {
        let center = NotificationCenter.default
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereResetNotification, UIApplication.didEnterBackgroundNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if note.name == AVAudioSession.interruptionNotification {
                    guard let value = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                          value == AVAudioSession.InterruptionType.began.rawValue else { return }
                }
                if note.name == AVAudioSession.routeChangeNotification {
                    guard let value = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                          value == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                }
                Task { @MainActor in
                    guard let self, self.token == id else { return }
                    self.fail("Голосовой режим остановлен. Можно продолжить из диалога.")
                }
            }
            observers.append(observer)
        }
    }

    private func fail(_ message: String) {
        let callback = failure
        stop()
        callback?(message)
    }

    private func stopMicrophone() {
        guard let engine else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
    }

    func stop() {
        token = UUID()
        timer?.cancel()
        timer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        stopMicrophone()
        input?.close()
        input = nil
        recognition?.cancel()
        recognition = nil
        recognizer = nil
        let wasSpeaking = utterance != nil
        utterance = nil
        if wasSpeaking { synth.stopSpeaking(at: .immediate) }
        if ownsSession {
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            ownsSession = false
        }
        lastText = ""
        lastPartialAt = 0
        finishing = false
        partial = nil
        final = nil
        failure = nil
        spoken = nil
    }
}
#endif
