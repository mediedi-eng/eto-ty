import Combine
import Foundation

@MainActor
protocol CareReminderDelivery: AnyObject {
    var onEvent: ((CareReminderEvent) -> Void)? { get set }
    func reconcile(date: Date?, requestPermission: Bool) async -> CareReminderStatus
}

extension CareReminders: CareReminderDelivery {}

/// One owner for the profile, its in-app deadline and the system notification.
@MainActor
final class CareSession: ObservableObject {
    @Published private(set) var plan = CarePlan()
    @Published private(set) var statusText: String?
    @Published private(set) var storageUnavailable = false
    @Published private(set) var notificationStatus: String?
    @Published private(set) var openChatToken = 0
    @Published private(set) var lastExternalDocumentID: String?
    @Published private(set) var suggestedContact: Date?
    @Published private(set) var contactSuggestionToken = 0
    @Published private(set) var archivedDocuments: [CareDocument] = []
    @Published private(set) var archiveAvailable = false
    @Published private(set) var generatingReplyID: UUID?
    @Published private(set) var cloudEnabled: Bool
    @Published private(set) var pendingCloudIDs = Set<UUID>()
    @Published private(set) var cloudIssues: [UUID: CloudChatError] = [:]
    private static let cloudSetting = "personal-chat.service.enabled.v1"
    private let preferences: UserDefaults
    private struct CloudRequest {
        let replyID: UUID
        let input: String
        let attempt = UUID()
    }
    private var queue: [CloudRequest] = []
    private var activeAttempt: UUID?
    private var serviceTask: Task<Void, Never>?
    private var deadlines: [UUID: Task<Void, Never>] = [:]
    private var completedInSession = Set<UUID>()
    private let replyDeadline: UInt64

    var documentSuggestion: CareDocumentFollowUp? {
        guard archiveAvailable else { return nil }
        return archivedDocuments.lazy.compactMap { self.plan.documentFollowUp(for: $0) }.first
    }

    var activeDocumentSource: CareDocument? {
        guard archiveAvailable, let reference = plan.activeSource else { return nil }
        return archivedDocuments.first { $0.id == reference.documentID && CareDocumentFollowUp(document: $0).id == reference.versionID }
    }

    private let storage: CareStorage
    private let documents: CareDocuments
    private let reminders: CareReminderDelivery
    private let now: () -> Date
    private let liveClock: Bool
    private let generateReply: ([CareMessage]) async -> String?
    private let cloudReply: (String, [CloudConversation.Turn]) async throws -> String
    private var replyTask: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    private var reminderTask: Task<Void, Never>?
    private var deliveryRevision = 0
    private var permissionDate: Date?

    convenience init() {
        self.init(storage: CareStorage(), documents: CareDocuments(), reminders: CareReminders.shared)
        LegacyChatCredential.remove()
    }

    init(storage: CareStorage, documents: CareDocuments, reminders: CareReminderDelivery,
         now: @escaping () -> Date = Date.init, liveClock: Bool = true,
         generateReply: @escaping ([CareMessage]) async -> String? = CareConversationModel.answer,
         preferences: UserDefaults = .standard,
         replyDeadline: UInt64 = 25_000_000_000,
         cloudReply: @escaping (String, [CloudConversation.Turn]) async throws -> String = { input, history in
             try await CloudConversation.answer(to: input, previous: history)
         }) {
        self.storage = storage
        self.documents = documents
        self.reminders = reminders
        self.now = now
        self.liveClock = liveClock
        self.generateReply = generateReply
        self.preferences = preferences
        self.cloudEnabled = (preferences.object(forKey: Self.cloudSetting) as? Bool)
            ?? (preferences.object(forKey: "personal-chat.openrouter.enabled.v1") as? Bool)
            ?? true
        self.replyDeadline = replyDeadline
        self.cloudReply = cloudReply
        restore()
        reminders.onEvent = { [weak self] event in
            guard let self else { return }
            if case .opened = event { self.openChatToken += 1 }
            self.refresh()
        }
    }

    deinit {
        serviceTask?.cancel()
        for timer in deadlines.values { timer.cancel() }
        replyTask?.cancel()
        clock?.cancel()
        reminderTask?.cancel()
    }

    func send(_ text: String, conversation: Bool = false) {
        let instant = now()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              apply({ $0.receive(text, now: instant, conversation: conversation) }) else { return }
        replyTask?.cancel()
        generatingReplyID = nil
        if plan.isAskingForUrgentHelp { cancelCloudRequests() }
        if let latest = plan.messages.last, let kind = latest.kind {
            if conversation && cloudEnabled {
                enqueueCloudReply(to: text, replyID: latest.id)
                return
            }
            if kind != .greeting && kind != .help {
                let history = Array(plan.messages.dropLast().suffix(7))
                generatingReplyID = latest.id
                replyTask = Task { [weak self, generateReply] in
                    let result = await generateReply(history)
                    guard let self, !Task.isCancelled, self.generatingReplyID == latest.id else { return }
                    self.generatingReplyID = nil
                    if let result, self.plan.messages.last?.id == latest.id {
                        self.apply { $0.replaceConversationReply(id: latest.id, with: result) }
                    }
                }
            }
            return
        }
        guard plan.topic != nil,
              !plan.isPaused, !plan.isClosed, !plan.isAskingForUrgentHelp, CareHistoryQuery.parse(text) == nil,
              let date = ContactTimeSuggestion.parse(text, now: instant) else { return }
        suggestedContact = date
        contactSuggestionToken += 1
    }

    func makeConversationTopic(replyID: UUID) {
        apply { $0.makeConversationTopic(replyID: replyID, now: self.now()) }
    }

    func setCloudEnabled(_ enabled: Bool) {
        if enabled != cloudEnabled { resetCloudConversation() }
        preferences.set(enabled, forKey: Self.cloudSetting)
        cloudEnabled = enabled
    }

    private func resetCloudConversation() {
        replyTask?.cancel()
        generatingReplyID = nil
        cancelCloudRequests()
        completedInSession.removeAll()
        cloudIssues.removeAll()
    }

    private func cancelCloudRequests() {
        serviceTask?.cancel()
        serviceTask = nil
        activeAttempt = nil
        for timer in deadlines.values { timer.cancel() }
        deadlines.removeAll()
        queue.removeAll()
        pendingCloudIDs.removeAll()
    }

    func retryCloudReply(_ replyID: UUID) {
        guard cloudEnabled, cloudIssues[replyID] != nil,
              let i = plan.messages.firstIndex(where: { $0.id == replyID }), i > 0,
              plan.messages[i - 1].fromUser else { return }
        enqueueCloudReply(to: plan.messages[i - 1].text, replyID: replyID)
    }

    private func enqueueCloudReply(to input: String, replyID: UUID) {
        guard !pendingCloudIDs.contains(replyID) else { return }
        guard input.utf16.count <= 4000 else {
            cloudIssues[replyID] = .tooLong
            return
        }
        cloudIssues[replyID] = nil
        let request = CloudRequest(replyID: replyID, input: input)
        queue.append(request)
        pendingCloudIDs.insert(replyID)
        // Bound the time shown on screen, including time spent waiting for the previous turn.
        deadlines[request.attempt] = Task { [weak self, replyDeadline] in
            do { try await Task.sleep(nanoseconds: replyDeadline) } catch { return }
            self?.finishCloudReply(request, result: .failure(.timedOut))
        }
        runNextCloudReply()
    }

    private func runNextCloudReply() {
        guard activeAttempt == nil, let request = queue.first else { return }
        activeAttempt = request.attempt
        // Only earlier turns completed in this cloud session may be sent as context.
        var history: [CloudConversation.Turn] = []
        let messages = plan.messages.prefix { $0.id != request.replyID }
        for i in messages.indices.reversed() where i > 0 && completedInSession.contains(messages[i].id) {
            history.insert(contentsOf: [.init(role: "user", content: messages[i - 1].text),
                                        .init(role: "assistant", content: messages[i].text)], at: 0)
            if history.count == 6 { break }
        }
        serviceTask = Task { [weak self, cloudReply] in
            do {
                try Task.checkCancellation()
                let answer = try await cloudReply(request.input, history)
                self?.finishCloudReply(request, result: .success(answer))
            } catch {
                self?.finishCloudReply(request, result: .failure(error as? CloudChatError ?? .connection))
            }
        }
    }

    private func finishCloudReply(_ request: CloudRequest, result: Result<String, CloudChatError>) {
        guard let i = queue.firstIndex(where: { $0.attempt == request.attempt }) else { return }
        queue.remove(at: i)
        deadlines.removeValue(forKey: request.attempt)?.cancel()
        if activeAttempt == request.attempt {
            serviceTask?.cancel()
            serviceTask = nil
            activeAttempt = nil
        }
        switch result {
        case .success(let text):
            if apply({ $0.replaceConversationReply(id: request.replyID, with: text, kind: .service) }) {
                completedInSession.insert(request.replyID)
            } else {
                cloudIssues[request.replyID] = .saveFailed
            }
        case .failure(let error):
            cloudIssues[request.replyID] = error
        }
        pendingCloudIDs.remove(request.replyID)
        runNextCloudReply()
    }

    @discardableResult
    func schedule(at date: Date, weekly: Bool = false) -> Bool {
        let instant = now()
        guard date.timeIntervalSinceReferenceDate.isFinite, date > instant, plan.topic != nil, !plan.isClosed, !plan.isPaused else {
            statusText = "Сначала выбери тему и время в будущем."
            return false
        }
        guard apply(requestPermission: true, { $0.schedule(at: date, now: instant, weekly: weekly) }) else { return false }
        suggestedContact = nil
        return true
    }

    func stopWeeklyContacts() {
        apply { $0.stopWeeklyContacts(now: self.now()) }
    }

    @discardableResult
    func setPressureRecord(_ value: CarePressureRecord?) -> Bool {
        apply { $0.setPressureRecord(value) }
    }

    @discardableResult
    func setPressureContext(_ value: CarePressureContext?) -> Bool {
        apply { $0.setPressureContext(value) }
    }

    @discardableResult
    func startPreparationGoal(_ displayed: CarePreparationStep) -> Bool {
        var started = false
        let saved = apply { started = $0.startPreparationGoal(displayed, now: self.now()) }
        if saved && !started { statusText = "Проверь текущий шаг и открытое дело." }
        return saved && started
    }

    func addVisitQuestion(_ text: String) -> Bool {
        var inserted = false
        let saved = apply { inserted = $0.addVisitQuestion(text) }
        if saved && !inserted {
            statusText = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Сначала введи вопрос." : "Этот вопрос уже сохранён."
        }
        return saved && inserted
    }

    func deleteVisitQuestion(id: UUID) -> Bool {
        apply { $0.deleteVisitQuestion(id: id) }
    }

    func pause() { apply { $0.pause() } }
    func resume() { apply { $0.resume() } }
    func finish() { apply { $0.finish() } }

    func refresh() {
        if storageUnavailable {
            restore()
            return
        }
        refreshArchive(andDelivery: true)
    }

    func refreshDocuments() { refreshArchive(andDelivery: false) }

    func didImportExternalDocument(_ document: CareDocument) {
        refreshDocuments()
        lastExternalDocumentID = document.id
        openChatToken += 1
    }

    func originalURL(for document: CareDocument) throws -> URL {
        try documents.originalURL(for: document)
    }

    func acceptDocumentSuggestion(_ displayed: CareDocumentFollowUp) {
        guard let current = currentSuggestion(matching: displayed) else { return }
        apply { $0.acceptFollowUp(current, now: self.now()) }
    }

    func dismissDocumentSuggestion(_ displayed: CareDocumentFollowUp) {
        guard let current = currentSuggestion(matching: displayed) else { return }
        apply { $0.dismissFollowUp(current) }
    }

    private func currentSuggestion(matching displayed: CareDocumentFollowUp) -> CareDocumentFollowUp? {
        refreshDocuments()
        guard archiveAvailable else {
            statusText = "Не удалось открыть архив. Попробуй ещё раз после разблокировки."
            return nil
        }
        guard let current = documentSuggestion, current.id == displayed.id else {
            statusText = "Предложение изменилось. Проверь текущую карточку."
            return nil
        }
        return current
    }

    private func refreshArchive(andDelivery: Bool) {
        guard !storageUnavailable else {
            archivedDocuments = []
            archiveAvailable = false
            return
        }
        let snapshot = try? documents.list()
        if let snapshot, archivedDocuments != snapshot { archivedDocuments = snapshot }
        if snapshot == nil { archivedDocuments = [] }
        archiveAvailable = snapshot != nil
        // A locked or unreadable archive says nothing about whether the source still exists.
        apply(refreshDelivery: andDelivery) { updated in
            if let snapshot { updated.reconcileFollowUpSources(snapshot, now: self.now()) }
            updated.checkDue(now: self.now())
        }
    }

    func deleteProfile() {
        resetCloudConversation()
        // Removing attachments first also makes a partially completed deletion safe to retry.
        do {
            try documents.deleteAll()
            try storage.delete()
        } catch {
            statusText = "Не удалось удалить все данные. Разблокируй телефон и повтори удаление."
            return
        }
        plan = CarePlan()
        lastExternalDocumentID = nil
        archivedDocuments = []
        archiveAvailable = true
        suggestedContact = nil
        storageUnavailable = false
        statusText = "Личные данные удалены с этого устройства."
        notificationStatus = nil
        updateDelivery(requestPermission: false)
    }

    private func restore() {
        do {
            plan = try storage.load() ?? CarePlan()
            storageUnavailable = false
            statusText = nil
            refreshArchive(andDelivery: true)
        } catch let error as CareStorageError {
            storageUnavailable = true
            statusText = error.localizedDescription + " Профиль можно открыть снова после восстановления или обновления приложения."
        } catch {
            storageUnavailable = true
            statusText = "Не удалось открыть личный профиль. Разблокируй телефон и попробуй снова. Доступно также удаление локальных данных."
        }
    }

    @discardableResult
    private func apply(requestPermission: Bool = false, refreshDelivery: Bool = false,
                       _ edit: (inout CarePlan) -> Void) -> Bool {
        guard !storageUnavailable else { return false }
        var updated = plan
        edit(&updated)
        let oldDue = plan.nextContact
        if updated != plan {
            do {
                try storage.save(updated)
            } catch {
                statusText = "Изменение не сохранилось. Разблокируй устройство и попробуй снова."
                return false
            }
            plan = updated
            statusText = nil
        }
        if oldDue != plan.nextContact || requestPermission || refreshDelivery {
            updateDelivery(requestPermission: requestPermission)
        }
        return true
    }

    private func updateDelivery(requestPermission: Bool) {
        clock?.cancel()
        let due = plan.nextContact
        if liveClock, let due {
            clock = Task { [weak self] in
                guard let currentTime = self?.now() else { return }
                // A capped sleep also handles wall-clock or time-zone changes after foregrounding.
                let seconds = min(86_400, max(0, due.timeIntervalSince(currentTime)))
                do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
                catch { return }
                self?.refresh()
            }
        }
        notificationStatus = nil
        // Preserve an explicit request across refreshes while the permission sheet is open.
        if due != permissionDate { permissionDate = nil }
        if requestPermission { permissionDate = due }
        let mayAsk = due != nil && permissionDate == due
        deliveryRevision += 1
        let revision = deliveryRevision
        let gateway = reminders
        reminderTask?.cancel()
        reminderTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let result = await gateway.reconcile(date: due, requestPermission: mayAsk)
            guard let self, self.deliveryRevision == revision else { return }
            self.permissionDate = nil
            self.notificationStatus = result.text
            self.reminderTask = nil
        }
    }
}
