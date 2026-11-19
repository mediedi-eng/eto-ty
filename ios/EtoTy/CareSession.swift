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
    @Published private(set) var suggestedContact: Date?
    @Published private(set) var contactSuggestionToken = 0

    private let storage: CareStorage
    private let documents: CareDocuments
    private let reminders: CareReminderDelivery
    private let now: () -> Date
    private let liveClock: Bool
    private var clock: Task<Void, Never>?
    private var reminderTask: Task<Void, Never>?
    private var deliveryRevision = 0
    private var permissionDate: Date?

    convenience init() {
        self.init(storage: CareStorage(), documents: CareDocuments(), reminders: CareReminders.shared)
    }

    init(storage: CareStorage, documents: CareDocuments, reminders: CareReminderDelivery,
         now: @escaping () -> Date = Date.init, liveClock: Bool = true) {
        self.storage = storage
        self.documents = documents
        self.reminders = reminders
        self.now = now
        self.liveClock = liveClock
        restore()
        reminders.onEvent = { [weak self] event in
            guard let self else { return }
            if case .opened = event { self.openChatToken += 1 }
            self.refresh()
        }
    }

    deinit {
        clock?.cancel()
        reminderTask?.cancel()
    }

    func send(_ text: String) {
        let instant = now()
        guard apply({ $0.receive(text, now: instant) }), plan.topic != nil,
              !plan.isPaused, !plan.isClosed,
              let date = ContactTimeSuggestion.parse(text, now: instant) else { return }
        suggestedContact = date
        contactSuggestionToken += 1
    }

    func schedule(at date: Date) {
        guard date > now(), plan.topic != nil, !plan.isClosed, !plan.isPaused else {
            statusText = "Сначала выбери тему и время в будущем."
            return
        }
        if apply(requestPermission: true, { $0.schedule(at: date, now: self.now()) }) {
            suggestedContact = nil
        }
    }

    func pause() { apply { $0.pause() } }
    func resume() { apply { $0.resume() } }
    func finish() { apply { $0.finish() } }

    func refresh() {
        if storageUnavailable {
            restore()
            return
        }
        apply(refreshDelivery: true) { $0.checkDue(now: self.now()) }
    }

    func deleteProfile() {
        // Removing attachments first also makes a partially completed deletion safe to retry.
        do {
            try documents.deleteAll()
            try storage.delete()
        } catch {
            statusText = "Не удалось удалить все данные. Разблокируй телефон и повтори удаление."
            return
        }
        plan = CarePlan()
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
            apply(refreshDelivery: true) { $0.checkDue(now: self.now()) }
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
