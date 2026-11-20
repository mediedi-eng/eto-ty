import Foundation

@MainActor
private final class VoiceAudioProbe: VoiceAudioDriving {
    var partial: ((String) -> Void)?
    var final: ((String) -> Void)?
    var failure: ((String) -> Void)?
    var didSpeak: (() -> Void)?
    var spoken: [String] = []
    var finishRequests = 0
    var silenceFlags: [Bool] = []

    func listen(endOnSilence: Bool, onPartial: @escaping (String) -> Void,
                onFinal: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        silenceFlags.append(endOnSilence)
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

@MainActor
private final class RecordedVoiceProbe: RecordedVoiceDriving {
    var silenceFlags: [Bool] = []
    var startImmediately = true
    var started: (() -> Void)?
    var transcribing: (() -> Void)?
    var final: ((String) -> Void)?
    var error: ((String) -> Void)?
    var stops = 0

    func listen(endOnSilence: Bool, onRecordingStarted: @escaping () -> Void,
                onTranscribing: @escaping () -> Void,
                onFinal: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        silenceFlags.append(endOnSilence)
        started = onRecordingStarted
        transcribing = onTranscribing
        final = onFinal
        error = onError
        if startImmediately { onRecordingStarted() }
    }

    func finishListening() { transcribing?() }
    func deliver(_ text: String) { transcribing?(); final?(text) }
    func stop() { stops += 1 }
}

enum VoiceConversationChecks {
    @MainActor
    static func run(storage: CareStorage, docs: CareDocuments, reminders: CareReminderDelivery) async throws {
        let audio = VoiceAudioProbe()
        let recorder = RecordedVoiceProbe()
        let voice = VoiceConversation(audio: audio, recorder: recorder)
        var edits: [String] = []
        voice.startDictation(useRecording: false) { edits.append($0) }
        let oldFinal = audio.final!
        audio.partial?("Прив")
        voice.finishListening()
        audio.final?("Привет")
        oldFinal("Лишняя копия")
        precondition(edits == ["Прив", "Привет"] && voice.mode == .idle && audio.finishRequests == 1 && audio.silenceFlags == [false])
        precondition(audio.spoken.isEmpty && recorder.silenceFlags.isEmpty)

        edits = []
        recorder.startImmediately = false
        voice.startDictation(useRecording: true) { edits.append($0) }
        precondition(voice.phase == .preparing && voice.recordingStartedAt == nil)
        let cancelledStart = recorder.started!
        voice.stop()
        cancelledStart()
        precondition(voice.mode == .idle && voice.recordingStartedAt == nil)
        voice.startDictation(useRecording: true) { edits.append($0) }
        cancelledStart()
        precondition(voice.phase == .preparing && voice.recordingStartedAt == nil)
        recorder.started?()
        precondition(voice.phase == .recording && voice.recordingStartedAt != nil)
        precondition(edits.isEmpty && recorder.silenceFlags == [false, false])
        recorder.startImmediately = true
        voice.finishListening()
        precondition(voice.phase == .transcribing && voice.recordingStartedAt == nil && edits.isEmpty)
        recorder.final?(" Текст из аудиозаписи ")
        precondition(voice.mode == .idle && edits == ["Текст из аудиозаписи"])
        precondition(audio.silenceFlags == [false])

        voice.startDictation(useRecording: true) { edits.append($0) }
        voice.finishListening()
        let lateTranscription = recorder.final!
        voice.stop()
        lateTranscription("Отменённый фрагмент")
        precondition(edits.count == 1 && voice.phase == .idle)

        voice.startDictation(useRecording: true) { edits.append($0) }
        voice.finishListening()
        recorder.error?("Сервис расшифровки недоступен.")
        precondition(voice.issue != nil && voice.mode == .idle && edits.count == 1)

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
        voice.startConversation(session: session)
        precondition(voice.phase == .recording && session.plan.messages.count == 1)
        recorder.transcribing?()
        precondition(voice.phase == .transcribing && session.plan.messages.count == 1)
        recorder.final?("Привет")
        precondition(recorder.silenceFlags.last == true)
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
        precondition(voice.phase == .recording)
        let listens = recorder.silenceFlags.count
        finishedFirst()
        precondition(recorder.silenceFlags.count == listens)
        recorder.deliver("Ещё раз")
        try await wait { voice.mode == .idle && voice.issue != nil }
        precondition(audio.spoken.count == 1 && calls == 2)
        voice.clearIssue()
        precondition(voice.issue == nil)

        voice.startConversation(session: session)
        recorder.transcribing?()
        let cancelledFinal = recorder.final!
        voice.stop()
        let count = session.plan.messages.count
        cancelledFinal("Поздний результат")
        precondition(session.plan.messages.count == count && voice.phase == .idle)

        // Urgent help follows the normal local path even in service mode and ends the call.
        voice.startConversation(session: session)
        recorder.deliver("Вызови скорую")
        precondition(voice.phase == .speaking && audio.spoken.last == session.plan.messages.last?.text)
        audio.didSpeak?()
        precondition(voice.mode == .idle && calls == 2)

        session.setCloudEnabled(false)
        let recordings = recorder.silenceFlags.count
        voice.startConversation(session: session)
        precondition(voice.phase == .listening)
        audio.final?("Привет")
        precondition(recorder.silenceFlags.count == recordings)
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
