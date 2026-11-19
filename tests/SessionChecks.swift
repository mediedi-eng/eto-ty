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
        var instant = Date(timeIntervalSince1970: 1_900_000_000)
        let session = CareSession(storage: storage, documents: docs, reminders: delivery,
                                  now: { instant }, liveClock: false)
        precondition(session.plan.topic == nil)
        precondition(tryLoad(storage) == nil)
        session.send("Вымышленное дело для проверки")
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

        // Failure to persist must leave the previous state available for a retry.
        let badPath = root.appendingPathComponent("blocked")
        try Data([1]).write(to: badPath)
        let blocked = CareSession(storage: CareStorage(directory: badPath), documents: docs,
                                  reminders: SessionReminderProbe(), liveClock: false)
        blocked.send("Эта запись не должна появиться")
        precondition(blocked.plan.topic == nil && blocked.statusText != nil)
    }

    private static func tryLoad(_ storage: CareStorage) -> CarePlan? {
        do { return try storage.load() } catch { preconditionFailure("Unexpected profile read failure") }
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
