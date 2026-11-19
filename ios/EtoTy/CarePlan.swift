import Foundation

/// A consented wall-clock slot in its original time zone. DST changes do not move the chosen weekday.
struct CareWeeklyContact: Codable, Equatable {
    let weekday: Int
    let hour: Int
    let minute: Int
    let timeZoneID: String

    init(at date: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        weekday = calendar.component(.weekday, from: date)
        hour = calendar.component(.hour, from: date)
        minute = calendar.component(.minute, from: date)
        timeZoneID = timeZone.identifier
    }

    var displayText: String {
        let weekdays = ["воскресенье", "понедельник", "вторник", "среда", "четверг", "пятница", "суббота"]
        let day = (1...7).contains(weekday) ? weekdays[weekday - 1] : "раз в неделю"
        return String(format: "%@, %02d:%02d (%@)", day, hour, minute, timeZoneID)
    }

    private var calendar: Calendar? {
        guard let timeZone = TimeZone(identifier: timeZoneID) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    func next(after date: Date) -> Date? {
        guard let calendar, (1...7).contains(weekday), (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        let components = DateComponents(hour: hour, minute: minute, second: 0, weekday: weekday)
        return calendar.nextDate(after: date, matching: components,
                                 matchingPolicy: .nextTimePreservingSmallerComponents, repeatedTimePolicy: .first)
    }

    func next(afterAnswer date: Date) -> Date? {
        // A late reply on the regular weekday should not trigger a second check-in that day.
        guard let calendar, let endOfDay = calendar.dateInterval(of: .day, for: date)?.end else { return nil }
        return next(after: endOfDay.addingTimeInterval(-1))
    }
}

struct CareMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let fromUser: Bool
    let createdAt: Date

    init(_ text: String, fromUser: Bool = false, at date: Date = Date()) {
        self.id = UUID()
        self.text = text
        self.fromUser = fromUser
        self.createdAt = date
    }
}

struct CareVisitQuestion: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
}

/// Local one-topic agreement. Saving the document and delivering a notification
/// are separate operations performed by the app.
struct CarePlan: Codable, Equatable {
    private(set) var messages = [CareMessage("Какое дело о здоровье ты хочешь снять с головы? Расскажи своими словами или пришли прошлый результат через скрепку. Можно начать и без документов.")]
    private(set) var topic: String?
    private(set) var nextContact: Date?
    private(set) var weeklyContact: CareWeeklyContact?
    private(set) var isPaused = false
    private(set) var isClosed = false
    private(set) var hasDueQuestion = false
    private(set) var lastAnswer: CareMessage?
    private(set) var activeSource: CareSourceReference?
    // Optional fields preserve compatibility with the first personal profiles.
    private var followUpDecisions: [String: [String: CareFollowUpDecision]]?
    private var savedVisitQuestions: [CareVisitQuestion]?

    var visitQuestions: [CareVisitQuestion] { savedVisitQuestions ?? [] }

    @discardableResult
    mutating func addVisitQuestion(_ input: String) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !visitQuestions.contains(where: { $0.text == text }) else { return false }
        savedVisitQuestions = visitQuestions + [CareVisitQuestion(id: UUID(), text: text)]
        return true
    }

    mutating func deleteVisitQuestion(id: UUID) {
        guard var questions = savedVisitQuestions else { return }
        questions.removeAll { $0.id == id }
        savedVisitQuestions = questions.isEmpty ? nil : questions
    }

    init() {}

    func documentFollowUp(for document: CareDocument) -> CareDocumentFollowUp? {
        let offer = CareDocumentFollowUp(document: document)
        return canDecide(offer) ? offer : nil
    }

    private func canDecide(_ offer: CareDocumentFollowUp) -> Bool {
        activeSource == nil && !isPaused && !hasDueQuestion && !isAskingForUrgentHelp
            && followUpDecisions?[offer.documentID]?[offer.id] == nil
    }

    mutating func acceptFollowUp(_ offer: CareDocumentFollowUp, now: Date = Date()) {
        guard canDecide(offer) else { return }
        let createsTopic = topic == nil || isClosed
        if createsTopic {
            topic = offer.action
            isClosed = false
            lastAnswer = nil
        }
        remember(.accepted, for: offer)
        activeSource = CareSourceReference(documentID: offer.documentID, versionID: offer.id, createdTopic: createsTopic)
        let response = createsTopic
            ? "Дело добавлено. В карточке можно открыть его источник и выбрать, когда вернуться к нему."
            : "Источник привязан к текущему делу. Его можно открыть из карточки дела."
        reply(response, at: now)
    }

    mutating func dismissFollowUp(_ offer: CareDocumentFollowUp) {
        guard canDecide(offer) else { return }
        remember(.dismissed, for: offer)
    }

    private mutating func remember(_ decision: CareFollowUpDecision, for offer: CareDocumentFollowUp) {
        if followUpDecisions == nil { followUpDecisions = [:] }
        followUpDecisions?[offer.documentID, default: [:]][offer.id] = decision
    }

    /// Caller supplies a complete, successfully read archive snapshot.
    mutating func reconcileFollowUpSources(_ documents: [CareDocument], now: Date = Date()) {
        if let decisions = followUpDecisions {
            let liveIDs = Set(documents.map(\.id))
            let retained = decisions.filter { liveIDs.contains($0.key) }
            followUpDecisions = retained.isEmpty ? nil : retained
        }
        guard let source = activeSource else { return }
        let current = documents.first { $0.id == source.documentID }.map { CareDocumentFollowUp(document: $0) }
        guard current?.id != source.versionID else { return }
        activeSource = nil
        let reason = current == nil ? "Источник удалён." : "Сведения в источнике изменились."
        if source.createdTopic {
            weeklyContact = nil
            isClosed = true
            isPaused = false
            nextContact = nil
            hasDueQuestion = false
            reply(reason + " Дело по прежней записи закрыто, напоминание снято.", at: now)
        } else {
            reply(reason + " Привязка снята. Твоя договорённость по теме сохранена.", at: now)
        }
    }

    var isAskingForUrgentHelp: Bool {
        guard let message = messages.last(where: { $0.fromUser }) else { return false }
        return Self.isExplicitEmergencyRequest(message.text)
    }

    var isDiscussingPrevention: Bool {
        guard !isClosed, !isAskingForUrgentHelp else { return false }
        return Self.mentionsPrevention(topic ?? "") ||
            Self.mentionsPrevention(messages.last(where: { $0.fromUser })?.text ?? "")
    }

    private static func mentionsPrevention(_ text: String) -> Bool {
        let value = text.lowercased()
        return ["чекап", "чек-ап", "профилакти", "что проверить", "что мне проверить",
                "что стоит проверить", "какие обследования", "какие анализы"].contains { value.contains($0) }
    }

    // Recognise direct requests to contact emergency services, never infer
    // severity from symptoms or infer a jurisdiction from the interface language.
    private static func isExplicitEmergencyRequest(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }
        let request = words.drop(while: { ["пожалуйста", "сейчас", "please"].contains(String($0)) })
            .joined(separator: " ")
        let directRequests = ["нужна срочная помощь", "мне нужна срочная помощь",
                              "срочно нужна помощь", "нужна экстренная помощь", "мне нужна экстренная помощь",
                              "как вызвать скорую", "вызови скорую", "вызовите скорую", "нужна скорая",
                              "i need urgent help", "i need emergency help", "call an ambulance",
                              "how do i call an ambulance", "call emergency services"]
        return directRequests.contains { request == $0 || request.hasPrefix($0 + " ") }
    }

    mutating func receive(_ text: String, now: Date = Date()) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }

        let message = CareMessage(value, fromUser: true, at: now)
        if Self.isExplicitEmergencyRequest(value) {
            messages.append(message)
            reply("Сейчас позвони в местную экстренную службу или попроси человека рядом вызвать помощь. На iPhone доступна функция «Экстренный вызов — SOS». Врача в этом чате нет, приложение не передало вызов.", at: now)
            return
        }
        if CareHistoryQuery.parse(value) != nil {
            messages.append(message)
            reply("Показываю доступные записи из личного архива.", at: now)
            return
        }

        let command = value.lowercased().replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))

        if topic == nil || isClosed {
            switch command {
            case "нет документов", "документов нет", "пока нет документов", "документов пока нет",
                 "у меня нет документов", "у меня пока нет документов", "без документов":
                messages.append(message)
                reply("Начнём с твоих слов. Какой один вопрос о здоровье ты хотел бы обсудить на следующем приёме? Я запомню его, и мы сможем договориться, когда к нему вернуться.", at: now)
                return
            default: break
            }
        }

        // Put an overdue question before the user's arrival. An explicit stop
        // takes effect immediately, including when the app was closed at its due time.
        switch command {
        case "пауза", "поставь на паузу", "пока не пиши первым":
            messages.append(message)
            if topic != nil && !isClosed && !isPaused { pause(at: now) }
            else { reply(statusText, at: now) }
            return
        case "завершить", "закрой дело", "закрыть дело", "заверши дело":
            messages.append(message)
            if topic != nil && !isClosed { finish(at: now) }
            else { reply(statusText, at: now) }
            return
        case "отмени напоминание", "отменить напоминание":
            messages.append(message)
            if nextContact != nil || hasDueQuestion || weeklyContact != nil {
                weeklyContact = nil
                nextContact = nil
                hasDueQuestion = false
                reply("Напоминание снято. Дело остаётся открытым.", at: now)
            } else {
                reply(statusText, at: now)
            }
            return
        case "отключи повтор", "отмени повтор", "выключи еженедельные напоминания":
            messages.append(message)
            if weeklyContact != nil { stopWeeklyContacts(now: now) }
            else { reply("Еженедельный повтор уже выключен.", at: now) }
            return
        default:
            break
        }

        let wasWaitingForAnswer = hasDueQuestion
        checkDue(now: now)
        messages.append(message)
        if topic != nil, !isClosed, command.hasPrefix("перенеси на ") || command.hasPrefix("перенести на ") {
            reply(statusText + " Подтверди новый срок в карточке дела.", at: now)
            return
        }

        switch command {
        case "продолжить", "возобновить", "снять с паузы":
            if isPaused { resume(at: now) } else { reply(statusText, at: now) }
        case "план", "мой план", "покажи план", "покажи мой план", "что ты ведешь", "что ты сейчас ведешь":
            reply(statusText, at: now)
        case "перенести", "перенеси", "изменить время", "когда напомнишь":
            reply(statusText + (topic != nil && !isClosed && !isPaused ? " Другой срок можно выбрать в карточке дела." : ""), at: now)
        default:
            if topic == nil || isClosed {
                topic = value
                isClosed = false
                lastAnswer = nil
                if Self.mentionsPrevention(value) {
                    reply("Для разговора о профилактике полезны даты прошлых обследований. Можно найти старый результат или записать вопрос к приёму. Что из этого хочешь сделать первым?", at: now)
                } else {
                    reply("Это твоё текущее дело. Если хочешь вернуться к нему позже, выбери дату и время в карточке.", at: now)
                }
            } else if wasWaitingForAnswer && !value.hasSuffix("?") {
                lastAnswer = message
                hasDueQuestion = false
                if let weeklyContact, let next = weeklyContact.next(afterAnswer: now) {
                    nextContact = next
                    reply("Ответ добавлен к делу. " + contactDescription, at: now)
                } else {
                    weeklyContact = nil
                    reply("Ответ добавлен к делу. Можно завершить его или выбрать время следующего разговора.", at: now)
                }
            } else if hasDueQuestion {
                reply("Запись добавлена к переписке. Когда будешь готов, расскажи, как продвинулось дело, или выбери другой срок.", at: now)
            } else if isPaused {
                reply("Запись добавлена к делу. Пауза действует, срок следующего разговора ещё не выбран.", at: now)
            } else if nextContact != nil {
                reply("Запись добавлена к делу. " + contactDescription, at: now)
            } else {
                reply("Запись добавлена к делу. Можно выбрать, когда вернуться к нему, или завершить его.", at: now)
            }
        }
    }

    mutating func schedule(at date: Date, now: Date = Date(), weekly: Bool = false,
                           timeZone: TimeZone = .current) {
        guard topic != nil, !isPaused, !isClosed else { return }
        guard date.timeIntervalSinceReferenceDate.isFinite, date > now else {
            reply("Выбери время в будущем. " + contactDescription, at: now)
            return
        }
        let repetition = weekly ? CareWeeklyContact(at: date, timeZone: timeZone) : nil
        guard nextContact != date || weeklyContact != repetition else { return }
        weeklyContact = repetition
        nextContact = date
        hasDueQuestion = false
        reply(contactDescription, at: now)
    }

    mutating func stopWeeklyContacts(now: Date = Date()) {
        guard weeklyContact != nil else { return }
        weeklyContact = nil
        reply(nextContact == nil ? "Еженедельный повтор выключен." : "Еженедельный повтор выключен. Ближайший согласованный контакт сохранён.", at: now)
    }

    mutating func checkDue(now: Date = Date()) {
        guard !isPaused, !isClosed, let topic, let due = nextContact, due <= now else { return }
        nextContact = nil
        hasDueQuestion = true
        reply("Договорились вернуться к делу «" + topic + "». Как продвинулось?", at: now)
    }

    mutating func pause() { pause(at: Date()) }
    mutating func resume() { resume(at: Date()) }
    mutating func finish() { finish(at: Date()) }

    private mutating func pause(at now: Date) {
        guard topic != nil, !isClosed, !isPaused else { return }
        isPaused = true
        weeklyContact = nil
        nextContact = nil
        hasDueQuestion = false
        reply("Поставил дело на паузу. Будущий контакт снят.", at: now)
    }

    private mutating func resume(at now: Date) {
        guard isPaused, !isClosed, topic != nil else { return }
        isPaused = false
        reply("Снова на связи по этому делу. Выбери новое время, если захочешь к нему вернуться.", at: now)
    }

    private mutating func finish(at now: Date) {
        guard topic != nil, !isClosed else { return }
        activeSource = nil
        isClosed = true
        weeklyContact = nil
        isPaused = false
        nextContact = nil
        hasDueQuestion = false
        reply("Дело закрыто. История здесь, будущих контактов по нему нет.", at: now)
    }

    private var statusText: String {
        guard let topic else { return "Договорённостей пока нет. Что хочешь поручить?" }
        let subject = "Дело «" + topic + "». "
        if isClosed { return subject + "Завершено. Новая тема начнётся с твоего следующего поручения." }
        if isPaused { return subject + "На паузе." }
        if hasDueQuestion { return subject + "Вопрос уже в диалоге, жду твоего ответа." }
        return subject + contactDescription
    }

    private var contactDescription: String {
        guard let nextContact else { return "Следующий контакт пока не запланирован." }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("d MMMM yyyy HH:mm")
        let agreed = "Время разговора в плане — " + formatter.string(from: nextContact) + "."
        guard let weeklyContact else { return agreed }
        return agreed + " Еженедельный контакт: " + weeklyContact.displayText + ". Следующий появится после твоего ответа."
    }

    private mutating func reply(_ text: String, at now: Date) {
        messages.append(CareMessage(text, at: now))
    }
}
