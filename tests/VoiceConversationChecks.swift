import Foundation

@MainActor
private final class VoiceAudioProbe: VoiceAudioDriving {
    var partial: ((String) -> Void)?
    var final: ((String) -> Void)?
    var failure: ((String) -> Void)?
    var didSpeak: (() -> Void)?
    var spoken: [String] = []
    var networkFlags: [Bool] = []
    var finishRequests = 0

    func listen(allowNetwork: Bool, onPartial: @escaping (String) -> Void,
                onFinal: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        networkFlags.append(allowNetwork)
        partial = onPartial
        final = onFinal
        failure = onError
    }

    func finishListening() { finishRequests += 1 }

    func speak(_ text: String, onFinished: @escaping () -> Void, onError: @escaping (String) -> Void) {
        spoken.append(text)
        didSpeak = onFinished
        failure = onError
    }

    // Keeping callback copies simulates late events from cancelled system work.
    func stop() {}
}

enum VoiceConversationChecks {
    @MainActor
    static func run(storage: CareStorage, docs: CareDocuments, reminders: CareReminderDelivery) async throws {
        let audio = VoiceAudioProbe()
        let voice = VoiceConversation(audio: audio)
        var edits: [String] = []
        voice.startDictation(allowNetwork: false) { edits.append($0) }
        let oldFinal = audio.final!
        audio.partial?("Прив")
        voice.finishListening()
        audio.final?("Привет")
        oldFinal("Лишняя копия")
        precondition(edits == ["Прив", "Привет"] && voice.mode == .idle && audio.finishRequests == 1)
        precondition(audio.spoken.isEmpty && audio.networkFlags == [false])

        let suite = "voice-tests." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        var remote: CheckedContinuation<String, Never>?
        var calls = 0
        let session = CareSession(storage: storage, documents: docs, reminders: reminders, liveClock: false,
                                  preferences: prefs) { _, _ in
            calls += 1
            if calls == 1 { return await withCheckedContinuation { remote = $0 } }
            throw CloudChatError.connection
        }
        session.setCloudEnabled(true)
        voice.startConversation(session: session, allowNetwork: true)
        precondition(voice.phase == .listening)
        audio.partial?("При")
        precondition(session.plan.messages.count == 1)
        audio.final?("Привет")
        let voiceReply = session.plan.messages.last!.id
        precondition(voice.phase == .waiting && session.pendingCloudIDs.contains(voiceReply))
        // A newer local command and unrelated archive reply must not get voiced.
        session.send("Покажи мои документы", conversation: true)
        try await wait { remote != nil }
        remote!.resume(returning: "Синтетический первый ответ")
        try await wait { voice.phase == .speaking }
        precondition(audio.spoken == ["Синтетический первый ответ"])
        precondition(session.plan.messages.last?.id != voiceReply)
        let finishedFirst = audio.didSpeak!
        finishedFirst()
        precondition(voice.phase == .listening)
        let listens = audio.networkFlags.count
        finishedFirst()
        precondition(audio.networkFlags.count == listens)
        audio.final?("Ещё раз")
        try await wait { voice.mode == .idle && voice.issue != nil }
        precondition(audio.spoken.count == 1 && calls == 2)
        voice.clearIssue()
        precondition(voice.issue == nil)

        voice.startConversation(session: session, allowNetwork: false)
        let cancelledFinal = audio.final!
        voice.stop()
        let count = session.plan.messages.count
        cancelledFinal("Поздний результат")
        precondition(session.plan.messages.count == count && voice.phase == .idle)

        // Urgent help follows the normal local path even in service mode and ends the call.
        voice.startConversation(session: session, allowNetwork: false)
        audio.final?("Вызови скорую")
        precondition(voice.phase == .speaking && audio.spoken.last == session.plan.messages.last?.text)
        audio.didSpeak?()
        precondition(voice.mode == .idle && calls == 2)

        session.setCloudEnabled(false)
        voice.startConversation(session: session, allowNetwork: false)
        audio.final?("Привет")
        precondition(voice.phase == .speaking && calls == 2)
        let lateSpeech = audio.didSpeak!
        voice.stop()
        lateSpeech()
        precondition(voice.phase == .idle)
    }

    @MainActor
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        preconditionFailure("The expected voice or session event did not arrive.")
    }
}
