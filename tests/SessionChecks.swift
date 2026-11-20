import Foundation

@MainActor
private final class SessionReminderProbe: CareReminderDelivery {
    var onEvent: ((CareReminderEvent) -> Void)?
    var requests: [(Date?, Bool)] = []
    var hold = false
    var waiting: CheckedContinuation<CareReminderStatus, Never>?

    func reconcile(date: Date?, requestPermission: Bool) async -> CareReminderStatus {
        requests.append((date, requestPermission))
        if date != nil && hold {
            hold = false
            return await withCheckedContinuation { waiting = $0 }
        }
        return date == nil ? .none : .denied
    }
}

enum SessionChecks {
    @MainActor
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = CareStorage(directory: root.appendingPathComponent("profile"))
        let docs = CareDocuments(directory: root.appendingPathComponent("files"))
        let delivery = SessionReminderProbe()
        try await checkCloudTransport()
        try await VoiceConversationChecks.run(storage: CareStorage(directory: root.appendingPathComponent("voice")),
                                              docs: docs, reminders: SessionReminderProbe())
        let chatStorage = CareStorage(directory: root.appendingPathComponent("chat"))
        let suite = "chat-checks." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: "personal-chat.openrouter.enabled.v1")
        var modelTurns = 0
        let chat = CareSession(storage: chatStorage, documents: docs, reminders: SessionReminderProbe(),
                               liveClock: false, generateReply: { history in
            modelTurns += 1
            precondition(history.last?.fromUser == true && history.last?.text == "Хочу поговорить")
            precondition(history.contains(where: { $0.kind == .greeting }))
            return "О чём ты хочешь поговорить?"
        }, preferences: preferences, cloudReply: { _, _ in
            preconditionFailure("Local-only conversations must stay on the device")
        })
        precondition(!chat.cloudEnabled)
        chat.send("Привет", conversation: true)
        precondition(chat.plan.topic == nil && chat.generatingReplyID == nil)
        chat.send("Хочу поговорить", conversation: true)
        try await waitUntil { chat.plan.messages.last?.kind == .model }
        precondition(modelTurns == 1 && tryLoad(chatStorage)?.messages.last?.text == "О чём ты хочешь поговорить?")
        // Reopen a populated local profile. Only messages deliberately sent in cloud mode may leave.
        preferences.removeObject(forKey: "personal-chat.openrouter.enabled.v1")
        var cloudCalls = 0
        let online = CareSession(storage: chatStorage, documents: docs, reminders: SessionReminderProbe(),
                                 liveClock: false, preferences: preferences) { text, history in
            cloudCalls += 1
            switch cloudCalls {
            case 1:
                precondition(history.isEmpty && text == "Привет!")
                return "Привет из тестового API"
            case 2:
                precondition(text == "Люблю читать" && history.map(\.role) == ["user", "assistant"])
                precondition(history.map(\.content) == ["Привет!", "Привет из тестового API"])
                return "Какие книги тебе нравятся?"
            case 3:
                precondition(history.count == 4)
                throw CloudChatError.limit
            default:
                precondition(history.isEmpty && text == "Начнём снова")
                return "Хорошо"
            }
        }
        precondition(online.cloudEnabled && cloudCalls == 0)
        online.send("Привет!", conversation: true)
        try await waitUntil { online.plan.messages.last?.kind == .service }
        online.send("Люблю читать", conversation: true)
        try await waitUntil { online.plan.messages.last?.text == "Какие книги тебе нравятся?" }
        precondition(online.plan.topic == nil && online.plan.nextContact == nil)
        online.send("Плохо сплю", conversation: true)
        try await waitUntil { !online.cloudIssues.isEmpty }
        precondition(online.plan.messages.last?.kind == .sleep && cloudCalls == 3)
        online.send("Покажи мои документы", conversation: true)
        online.send("Вызови скорую", conversation: true)
        precondition(online.generatingReplyID == nil && cloudCalls == 3 && online.plan.isAskingForUrgentHelp)
        online.setCloudEnabled(false)
        online.send("Привет", conversation: true)
        precondition(online.plan.messages.last?.kind == .greeting && cloudCalls == 3)
        let reopened = CareSession(storage: chatStorage, documents: docs, reminders: SessionReminderProbe(),
                                   liveClock: false, preferences: preferences)
        precondition(!reopened.cloudEnabled)
        online.setCloudEnabled(true)
        online.send("Начнём снова", conversation: true)
        try await waitUntil { online.plan.messages.last?.text == "Хорошо" }
        try await checkOverlappingReplies(root: root, docs: docs, preferences: preferences)
        var instant = Date(timeIntervalSince1970: 1_900_000_000)
        let session = CareSession(storage: storage, documents: docs, reminders: delivery,
                                  now: { instant }, liveClock: false)
        precondition(session.plan.topic == nil)
        precondition(tryLoad(storage) == nil)
        precondition(CareRegionSuggestion.fromTitle("2025_ЭКГ_покоя.PDF") == .heart)
        precondition(CareRegionSuggestion.fromTitle("УЗИ-почек.jpeg") == .kidneys)
        precondition(CareRegionSuggestion.fromTitle("Liver ultrasound.pdf") == .liver)
        precondition(CareRegionSuggestion.fromTitle("УЗИ печени и почек.pdf") == nil)
        precondition(CareRegionSuggestion.fromTitle("IMG_0174.HEIC") == nil)
        session.send("Вымышленное дело для проверки")
        session.send("Найди в документах фразу напомни через две минуты")
        precondition(session.suggestedContact == nil && session.contactSuggestionToken == 0)
        session.send("Напомни через две минуты")
        precondition(session.suggestedContact == instant.addingTimeInterval(120))
        precondition(session.plan.nextContact == nil && session.contactSuggestionToken == 1)
        precondition(ContactTimeSuggestion.parse("Не напомни через две минуты", now: instant) == nil)
        precondition(ContactTimeSuggestion.parse("Через две минуты закончил читать", now: instant) == nil)
        let calendar = Calendar(identifier: .gregorian)
        let tomorrow = ContactTimeSuggestion.parse("Спроси завтра в 14:30", now: instant, calendar: calendar)!
        precondition(calendar.component(.hour, from: tomorrow) == 14 && calendar.component(.minute, from: tomorrow) == 30)
        precondition(ContactTimeSuggestion.parse("Напомни завтра в 14:99", now: instant) == nil)
        let later = instant.addingTimeInterval(90)
        session.schedule(at: later)
        try await waitUntil { session.notificationStatus == CareReminderStatus.denied.text }
        precondition(delivery.requests.contains { $0.0 == later && $0.1 })
        precondition(tryLoad(storage)?.nextContact == later)
        // A refused lock-screen notification still leaves the agreed question in the inbox.
        instant = later
        delivery.onEvent?(.opened)
        precondition(session.openChatToken == 1 && session.plan.hasDueQuestion)
        let count = session.plan.messages.count
        session.refresh()
        precondition(session.plan.messages.count == count)
        session.send("Нашёл документ")
        precondition(!session.plan.hasDueQuestion)
        let restored = CareSession(storage: storage, documents: docs, reminders: SessionReminderProbe(),
                                   now: { instant }, liveClock: false)
        precondition(restored.plan == session.plan)

        let weeklyDate = instant.addingTimeInterval(120)
        precondition(!session.schedule(at: instant, weekly: true))
        precondition(session.schedule(at: weeklyDate, weekly: true))
        try await waitUntil { delivery.requests.last?.0 == weeklyDate }
        precondition(delivery.requests.last?.1 == true)
        instant = weeklyDate
        session.refresh()
        try await waitUntil { delivery.requests.last?.0 == nil }
        precondition(session.plan.hasDueQuestion && session.plan.nextContact == nil)
        session.send("Вопросы готовы")
        let agreedNext = session.plan.nextContact!
        try await waitUntil { delivery.requests.last?.0 == agreedNext }
        precondition(delivery.requests.last?.1 == false && tryLoad(storage)?.nextContact == agreedNext)
        session.stopWeeklyContacts()
        precondition(tryLoad(storage)?.weeklyContact == nil && session.plan.nextContact == agreedNext)

        delivery.hold = true
        session.schedule(at: later.addingTimeInterval(300))
        try await waitUntil { delivery.waiting != nil }
        session.pause()
        try await waitUntil { delivery.requests.last?.0 == nil }
        delivery.waiting?.resume(returning: .scheduled)
        delivery.waiting = nil
        await Task.yield()
        precondition(session.notificationStatus != CareReminderStatus.scheduled.text)
        precondition(tryLoad(storage)?.isPaused == true)
        session.deleteProfile()
        precondition(session.plan.topic == nil && tryLoad(storage) == nil)

        let docID = try docs.add(VisitPDF.render("Вымышленный фрагмент"), name: "Справка.pdf").id
        session.refreshDocuments()
        let initialOffer = session.documentSuggestion!
        try docs.annotate(docID, studyDate: instant, page: 1, quote: "Вымышленный фрагмент")
        session.acceptDocumentSuggestion(initialOffer)
        precondition(session.plan.topic == nil && session.documentSuggestion?.isReviewed == true)
        let correctedOffer = session.documentSuggestion!
        session.acceptDocumentSuggestion(correctedOffer)
        precondition(session.activeDocumentSource?.id == docID && session.documentSuggestion == nil)
        session.schedule(at: instant.addingTimeInterval(180))
        precondition(tryLoad(storage)?.nextContact != nil)
        // An unreadable archive must never be treated as confirmation that a source was removed.
        let metadata = root.appendingPathComponent("files").appendingPathComponent(docID).appendingPathComponent("record.json")
        let saved = try Data(contentsOf: metadata)
        try Data([0]).write(to: metadata, options: .atomic)
        session.refreshDocuments()
        precondition(!session.archiveAvailable && session.plan.activeSource != nil && session.plan.nextContact != nil)
        try saved.write(to: metadata, options: .atomic)
        session.refreshDocuments()
        precondition(session.activeDocumentSource?.id == docID)
        try docs.remove(docID)
        session.refresh()
        precondition(session.plan.activeSource == nil && session.plan.nextContact == nil && session.activeDocumentSource == nil)
        precondition(tryLoad(storage) == session.plan)
        session.deleteProfile()

        // Failure to persist must leave the previous state available for a retry.
        let badPath = root.appendingPathComponent("blocked")
        try Data([1]).write(to: badPath)
        let blocked = CareSession(storage: CareStorage(directory: badPath), documents: docs,
                                  reminders: SessionReminderProbe(), liveClock: false)
        blocked.send("Эта запись не должна появиться")
        precondition(blocked.plan.topic == nil && blocked.statusText != nil)
    }

    private static func checkCloudTransport() async throws {
        let previous = (0..<10).map { CloudConversation.Turn(role: $0.isMultiple(of: 2) ? "user" : "assistant", content: String($0)) }
        let answer = try await CloudConversation.answer(to: "Привет", previous: previous) { request in
            precondition(request.url?.absoluteString == "https://eto-ty-pilot-chat.sacredarbor.chatgpt.site/v1/chat")
            precondition(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            precondition(request.value(forHTTPHeaderField: "Origin") == "https://eto-ty-pilot-chat.sacredarbor.chatgpt.site")
            precondition(request.value(forHTTPHeaderField: "Accept") == "application/json")
            precondition(request.value(forHTTPHeaderField: "User-Agent") == "EtoTy-iOS/1.0")
            precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            precondition(Set(body.keys) == ["message", "history"] && body["message"] as? String == "Привет")
            let turns = body["history"] as! [[String: String]]
            precondition(turns.count == 6 && turns.first == ["role": "user", "content": "4"])
            return (Data(#"{"reply":"Привет! Как дела?"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        precondition(answer == "Привет! Как дела?")
        do {
            _ = try await CloudConversation.answer(to: "Пример", previous: []) { request in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!)
            }
            preconditionFailure("The service budget must be respected")
        } catch CloudChatError.limit {}
        do {
            _ = try await CloudConversation.answer(to: String(repeating: "а", count: 4001), previous: []) { _ in
                preconditionFailure("Oversized input must stay on the device")
            }
            preconditionFailure("Oversized input must be rejected")
        } catch CloudChatError.tooLong {}
    }

    private static func tryLoad(_ storage: CareStorage) -> CarePlan? {
        do { return try storage.load() } catch { preconditionFailure("Unexpected profile read failure") }
    }

    @MainActor
    private static func checkOverlappingReplies(root: URL, docs: CareDocuments, preferences: UserDefaults) async throws {
        let storage = CareStorage(directory: root.appendingPathComponent("overlap"))
        var first: CheckedContinuation<String, Never>?
        let session = CareSession(storage: storage, documents: docs, reminders: SessionReminderProbe(),
                                  liveClock: false, preferences: preferences) { input, history in
            if input == "Привет" {
                precondition(history.isEmpty)
                return await withCheckedContinuation { first = $0 }
            }
            precondition(history.map(\.content) == ["Привет", "Первый ответ"])
            return "Второй ответ"
        }
        session.send("Привет", conversation: true)
        let firstID = session.plan.messages.last!.id
        session.send("Мой второй вопрос", conversation: true)
        let secondID = session.plan.messages.last!.id
        session.send("Покажи мои документы", conversation: true)
        precondition(session.pendingCloudIDs == [firstID, secondID])
        try await waitUntil { first != nil }
        first!.resume(returning: "Первый ответ")
        try await waitUntil { session.pendingCloudIDs.isEmpty }
        let answers = tryLoad(storage)!.messages.filter { $0.kind == .service }
        precondition(answers.map(\.id) == [firstID, secondID])
        precondition(answers.map(\.text) == ["Первый ответ", "Второй ответ"])
        precondition(session.plan.messages.last?.kind == nil && session.cloudIssues.isEmpty)

        // A transport may finish after cancellation. A late response must not overwrite its retry.
        let retryStorage = CareStorage(directory: root.appendingPathComponent("retry"))
        var late: CheckedContinuation<String, Never>?
        var calls = 0
        let retry = CareSession(storage: retryStorage, documents: docs, reminders: SessionReminderProbe(),
                                liveClock: false, preferences: preferences, replyDeadline: 50_000_000) { _, _ in
            calls += 1
            if calls == 1 { return await withCheckedContinuation { late = $0 } }
            return "Ответ после повтора"
        }
        retry.send("Привет", conversation: true)
        let id = retry.plan.messages.last!.id
        try await waitUntil { retry.cloudIssues[id] == .timedOut }
        precondition(retry.pendingCloudIDs.isEmpty && late != nil)
        retry.retryCloudReply(id)
        try await waitUntil { retry.plan.messages.last?.kind == .service }
        late!.resume(returning: "Устаревший ответ")
        await Task.yield()
        precondition(retry.plan.messages.last?.text == "Ответ после повтора")
        precondition(retry.plan.messages.count == 3 && retry.cloudIssues.isEmpty && calls == 2)
    }

    @MainActor
    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        preconditionFailure("Reminder state did not converge")
    }
}
