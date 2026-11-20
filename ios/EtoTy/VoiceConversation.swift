import Combine
import Foundation

@MainActor
protocol VoiceAudioDriving: AnyObject {
    func listen(allowNetwork: Bool, endOnSilence: Bool, onPartial: @escaping (String) -> Void,
                onFinal: @escaping (String) -> Void, onError: @escaping (String) -> Void)
    func finishListening()
    func speak(_ text: String, onFinished: @escaping () -> Void, onError: @escaping (String) -> Void)
    func stop()
}

#if os(iOS)
extension VoiceAudio: VoiceAudioDriving {}
#endif

@MainActor
final class VoiceConversation: ObservableObject {
    enum Mode { case idle, dictation, conversation }
    enum Phase: String { case idle, listening, waiting, speaking }

    @Published private(set) var mode = Mode.idle
    @Published private(set) var phase = Phase.idle
    @Published private(set) var transcript = ""
    @Published private(set) var issue: String?

    private let audio: VoiceAudioDriving
    private var turn = UUID()
    private var sessionObservation: AnyCancellable?
    private var waitDeadline: Task<Void, Never>?
    private weak var session: CareSession?
    private var profileID: UUID?
    private var replyID: UUID?
    private var allowNetwork = false
    private var cloudAtStart = false
    private var expectsServiceReply = false
    private var dictationOutput: ((String) -> Void)?

    #if os(iOS)
    convenience init() {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--eto-ty-ui-test-voice") {
            self.init(audio: UITestVoiceAudio())
            return
        }
        #endif
        self.init(audio: VoiceAudio())
    }
    #endif

    init(audio: VoiceAudioDriving) { self.audio = audio }

    func startDictation(allowNetwork: Bool, onText: @escaping (String) -> Void) {
        stop()
        self.allowNetwork = allowNetwork
        dictationOutput = onText
        mode = .dictation
        listen()
    }

    func startConversation(session: CareSession, allowNetwork: Bool) {
        stop()
        guard !session.storageUnavailable else {
            issue = "Не удалось открыть профиль. Разблокируй iPhone и попробуй ещё раз."
            return
        }
        self.session = session
        self.allowNetwork = allowNetwork
        cloudAtStart = session.cloudEnabled
        profileID = session.plan.messages.first?.id
        mode = .conversation
        // Published properties notify before mutation. Read the complete state on the next actor turn.
        sessionObservation = session.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.sessionChanged() }
        }
        listen()
    }

    func finishListening() {
        if phase == .listening { audio.finishListening() }
    }

    func clearIssue() { issue = nil }

    func stop() {
        turn = UUID()
        sessionObservation = nil
        waitDeadline?.cancel()
        waitDeadline = nil
        session = nil
        profileID = nil
        replyID = nil
        dictationOutput = nil
        mode = .idle
        phase = .idle
        transcript = ""
        issue = nil
        audio.stop()
    }

    private func listen() {
        let current = UUID()
        turn = current
        phase = .listening
        transcript = ""
        audio.listen(allowNetwork: allowNetwork, endOnSilence: mode == .conversation, onPartial: { [weak self] text in
            guard let self, self.turn == current, self.phase == .listening else { return }
            self.transcript = text
            self.dictationOutput?(text)
        }, onFinal: { [weak self] text in
            guard let self, self.turn == current, self.phase == .listening else { return }
            self.received(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }, onError: { [weak self] error in
            guard let self, self.turn == current, self.phase == .listening else { return }
            self.fail(error)
        })
    }

    private func received(_ text: String) {
        guard !text.isEmpty else {
            fail("Речь не распознана. Попробуй ещё раз.")
            return
        }
        if mode == .dictation {
            let output = dictationOutput
            stop()
            output?(text)
            return
        }
        guard let session, validSession(session) else { stop(); return }
        phase = .waiting
        // Stop capture before handing the recognized text to the ordinary message path.
        audio.stop()
        transcript = text
        let previous = session.plan.messages.last?.id
        session.send(text, conversation: true)
        guard let reply = session.plan.messages.last, !reply.fromUser, reply.id != previous else {
            fail(session.statusText ?? "Сообщение не сохранилось. Попробуй отправить его в диалоге.")
            return
        }
        replyID = reply.id
        expectsServiceReply = session.cloudEnabled && reply.kind != nil
        let current = turn
        waitDeadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 32_000_000_000) } catch { return }
            guard let self, self.turn == current, self.phase == .waiting else { return }
            self.fail("Ответ задержался. Голосовой разговор остановлен, сообщение осталось в диалоге.")
        }
        sessionChanged()
    }

    private func validSession(_ session: CareSession) -> Bool {
        !session.storageUnavailable && session.cloudEnabled == cloudAtStart &&
            session.plan.messages.first?.id == profileID
    }

    private func sessionChanged() {
        guard mode == .conversation else { return }
        guard let session, validSession(session) else { stop(); return }
        guard phase == .waiting, let replyID else { return }
        if let error = session.cloudIssues[replyID] { fail(error.localizedDescription); return }
        guard !session.pendingCloudIDs.contains(replyID), session.generatingReplyID != replyID else { return }
        guard let reply = session.plan.messages.first(where: { $0.id == replyID }) else { stop(); return }
        if expectsServiceReply && reply.kind != .service {
            fail("Голосовой разговор остановлен. Отправку сообщения можно проверить в диалоге.")
            return
        }
        waitDeadline?.cancel()
        waitDeadline = nil
        phase = .speaking
        let current = turn
        let endAfterSpeaking = session.plan.isAskingForUrgentHelp
        audio.speak(reply.text, onFinished: { [weak self] in
            guard let self, self.turn == current, self.phase == .speaking else { return }
            if endAfterSpeaking { self.stop() } else { self.listen() }
        }, onError: { [weak self] error in
            guard let self, self.turn == current, self.phase == .speaking else { return }
            self.fail(error)
        })
    }

    private func fail(_ message: String) {
        stop()
        issue = message
    }
}
