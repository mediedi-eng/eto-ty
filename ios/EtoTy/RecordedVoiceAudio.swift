#if os(iOS)
import AVFoundation
import UIKit

/// A complete voice message is uploaded only after the user or turn detector ends recording.
@MainActor
final class RecordedVoiceAudio: NSObject, AVAudioRecorderDelegate {
    private enum Phase { case idle, permission, recording, transcribing }
    private static let maximumSeconds: TimeInterval = 120
    private static var cleanedPreviousLaunch = false
    private let session = AVAudioSession.sharedInstance()
    private var recorder: AVAudioRecorder?
    private var ownsAudioSession = false
    private var clip: URL?
    private var phase = Phase.idle
    private var token = UUID()
    private var startedAt: TimeInterval = 0
    private var timer: Task<Void, Never>?
    private var upload: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var transcribing: (() -> Void)?
    private var final: ((String) -> Void)?
    private var errorHandler: ((String) -> Void)?

    #if DEBUG && targetEnvironment(simulator)
    private var syntheticClip: URL?
    convenience init(syntheticClip: URL) {
        self.init()
        self.syntheticClip = syntheticClip
    }
    #endif

    override init() {
        super.init()
        // A terminated process may have left a protected clip before it could run stop().
        _ = try? Self.clipDirectory()
    }

    deinit {
        timer?.cancel()
        upload?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        recorder?.delegate = nil
        recorder?.stop()
        if ownsAudioSession { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
        if let clip { try? FileManager.default.removeItem(at: clip) }
    }

    func listen(endOnSilence: Bool, onRecordingStarted: @escaping () -> Void,
                onTranscribing: @escaping () -> Void,
                onFinal: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        stop()
        phase = .permission
        transcribing = onTranscribing
        final = onFinal
        errorHandler = onError
        let id = token
        observeInterruptions(id)

        #if DEBUG && targetEnvironment(simulator)
        if let syntheticClip {
            do {
                let url = try Self.newClipURL()
                clip = url
                try FileManager.default.copyItem(at: syntheticClip, to: url)
                try Self.protect(url)
                phase = .recording
                if endOnSilence {
                    timer = Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
                        guard self?.token == id else { return }
                        self?.finishListening()
                    }
                }
                onRecordingStarted()
            } catch {
                fail("Не удалось подготовить тестовую запись.")
            }
            return
        }
        #endif

        Task { [weak self] in
            let allowed = await AVAudioApplication.requestRecordPermission()
            guard let self, self.token == id else { return }
            guard allowed else {
                self.fail("Разреши доступ к микрофону для «Это ты» в настройках iPhone.")
                return
            }
            self.startRecording(endOnSilence: endOnSilence, token: id, onRecordingStarted: onRecordingStarted)
        }
    }

    private static func newClipURL() throws -> URL {
        try clipDirectory().appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
    }

    private static func clipDirectory() throws -> URL {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent("EtoTyVoiceClips", isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true,
                                  attributes: [.protectionKey: FileProtectionType.complete])
        if !cleanedPreviousLaunch {
            for url in try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where url.pathExtension == "m4a" {
                try files.removeItem(at: url)
            }
            cleanedPreviousLaunch = true
        }
        return folder
    }

    private static func protect(_ url: URL) throws {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    }

    private func startRecording(endOnSilence: Bool, token id: UUID, onRecordingStarted: () -> Void) {
        do {
            let url = try Self.newClipURL()
            clip = url
            try session.setCategory(.record, mode: .default, options: [.allowBluetooth])
            try session.setActive(true)
            ownsAudioSession = true
            guard session.isInputAvailable else {
                fail("Микрофон недоступен. Проверь гарнитуру или повтори запись.")
                return
            }
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                          AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1,
                                          AVEncoderBitRateKey: 48_000]
            let capture = try AVAudioRecorder(url: url, settings: settings)
            recorder = capture
            capture.delegate = self
            capture.isMeteringEnabled = endOnSilence
            guard capture.prepareToRecord() else { throw VoiceTranscriptionError.invalidClip }
            try Self.protect(url)
            guard capture.record(forDuration: Self.maximumSeconds) else { throw VoiceTranscriptionError.invalidClip }
            phase = .recording
            startedAt = ProcessInfo.processInfo.systemUptime
            monitor(endOnSilence: endOnSilence, token: id)
            onRecordingStarted()
        } catch {
            fail("Не удалось начать запись. Проверь доступ к микрофону и свободное место на iPhone.")
        }
    }

    private func monitor(endOnSilence: Bool, token id: UUID) {
        timer = Task { [weak self] in
            var lastSpeech: TimeInterval?
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
                guard let self, self.token == id, let recorder = self.recorder else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if now - self.startedAt >= Self.maximumSeconds {
                    self.finishListening()
                    return
                }
                guard endOnSilence else { continue }
                recorder.updateMeters()
                if recorder.averagePower(forChannel: 0) > -45 { lastSpeech = now }
                if let lastSpeech, now - lastSpeech >= 1.8 {
                    self.finishListening()
                    return
                }
                if lastSpeech == nil && now - self.startedAt >= 15 {
                    self.fail("Не услышал речь. Нажми микрофон, чтобы начать снова.")
                    return
                }
            }
        }
    }

    func finishListening() {
        if phase == .permission {
            fail("Запись остановлена до включения микрофона.")
            return
        }
        guard phase == .recording, let url = clip else { return }
        phase = .transcribing
        let id = token
        releaseRecorder()
        timer?.cancel()
        transcribing?()
        guard token == id else { return }
        timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 70_000_000_000) } catch { return }
            guard self?.token == id else { return }
            self?.fail(VoiceTranscriptionError.timeout.localizedDescription)
        }
        upload = Task { [weak self] in
            do {
                let bytes = try await VoiceTranscription.consumeClip(url)
                try Task.checkCancellation()
                let text = try await VoiceTranscription.transcribe(bytes)
                guard let self, self.token == id else { return }
                let callback = self.final
                self.stop()
                callback?(text)
            } catch {
                guard let self, self.token == id else { return }
                self.fail((error as? VoiceTranscriptionError ?? .unavailable).localizedDescription)
            }
        }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder, self.phase == .recording else { return }
            if flag && ProcessInfo.processInfo.systemUptime - self.startedAt >= Self.maximumSeconds - 1 {
                self.finishListening()
            } else {
                self.fail("Запись прервалась. Можно записать фразу ещё раз.")
            }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            self.fail("Не удалось сохранить звук. Попробуй записать фразу ещё раз.")
        }
    }

    private func observeInterruptions(_ id: UUID) {
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereResetNotification, UIApplication.didEnterBackgroundNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] note in
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
                    self.fail("Голосовой ввод остановлен. Можно продолжить из диалога.")
                }
            }
            observers.append(observer)
        }
    }

    private func releaseRecorder() {
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        if ownsAudioSession {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
    }

    private func fail(_ message: String) {
        let callback = errorHandler
        stop()
        callback?(message)
    }

    func stop() {
        token = UUID()
        phase = .idle
        timer?.cancel()
        timer = nil
        upload?.cancel()
        upload = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        releaseRecorder()
        if let clip { try? FileManager.default.removeItem(at: clip) }
        clip = nil
        final = nil
        transcribing = nil
        errorHandler = nil
    }
}
#endif
