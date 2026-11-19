import Foundation

enum WeeklyCheckInChecks {
    static func run() throws {
        let newYork = TimeZone(identifier: "America/New_York")!
        let start = date("2026-02-28T09:00:00Z")
        let agreed = date("2026-03-01T07:30:00Z")

        var plan = CarePlan()
        plan.receive("Подготовить вопросы к приёму", now: start)
        plan.schedule(at: agreed, now: start)
        var single = plan
        single.checkDue(now: agreed)
        single.receive("Готово", now: agreed)
        precondition(single.lastAnswer != nil && single.nextContact == nil && single.weeklyContact == nil)

        // Same appointment, explicit opt-in. Saving the same choice twice must have no side effects.
        plan.schedule(at: agreed, now: start, weekly: true, timeZone: newYork)
        let consented = plan
        plan.schedule(at: agreed, now: start, weekly: true, timeZone: newYork)
        precondition(plan == consented)
        let weekly = plan.weeklyContact!
        precondition(weekly.weekday == 1 && weekly.hour == 2 && weekly.minute == 30 && weekly.timeZoneID == newYork.identifier)
        let spring = date("2026-03-08T07:30:00Z")
        let afterSpring = date("2026-03-15T06:30:00Z")
        precondition(weekly.next(after: agreed) == spring)
        precondition(weekly.next(after: spring) == afterSpring)
        let fall = CareWeeklyContact(at: date("2026-10-25T05:30:00Z"), timeZone: newYork)
        let overlap = date("2026-11-01T05:30:00Z")
        precondition(fall.next(after: date("2026-10-25T05:30:00Z")) == overlap)
        precondition(fall.next(afterAnswer: overlap) == date("2026-11-08T06:30:00Z"))

        // Opening weeks later delivers one question, even if the app relaunches before a reply.
        let late = date("2026-05-31T04:25:00Z") // Sunday, 00:25 in the agreed time zone.
        plan = try reload(plan)
        let before = plan.messages.count
        plan.checkDue(now: late)
        plan = try reload(plan)
        plan.checkDue(now: late)
        precondition(plan.messages.count == before + 1 && plan.hasDueQuestion && plan.nextContact == nil)
        precondition(plan.weeklyContact == weekly)
        plan.receive("Покажи документы", now: late)
        plan.receive("Когда обсудим?", now: late)
        plan.receive("План", now: late)
        precondition(plan.hasDueQuestion && plan.lastAnswer == nil && plan.nextContact == nil)
        plan.receive("Записал вопросы", now: late)
        let followingWeek = date("2026-06-07T06:30:00Z")
        precondition(!plan.hasDueQuestion && plan.nextContact == followingWeek && plan.weeklyContact == weekly)
        let restored = try reload(plan)
        precondition(restored == plan)
        plan.receive("Записал ещё один", now: late)
        precondition(plan.nextContact == followingWeek && plan.lastAnswer?.text == "Записал вопросы")

        // Turning off recurrence preserves the single agreed appointment, including an open question.
        var stopped = consented
        stopped.stopWeeklyContacts(now: start)
        precondition(stopped.nextContact == agreed && stopped.weeklyContact == nil)
        stopped.checkDue(now: agreed)
        stopped.receive("Готово", now: agreed)
        precondition(stopped.nextContact == nil && stopped.lastAnswer != nil)
        stopped = consented
        stopped.checkDue(now: agreed)
        stopped.receive("отключи повтор", now: agreed)
        precondition(stopped.hasDueQuestion && stopped.weeklyContact == nil)
        stopped.receive("Готово", now: agreed)
        precondition(stopped.nextContact == nil && stopped.lastAnswer != nil)
        stopped = consented
        stopped.schedule(at: agreed, now: start)
        precondition(stopped.weeklyContact == nil && stopped.nextContact == agreed)
        // Moving an active agreement anchors an explicitly repeated rule to the newly chosen local time.
        let updated = date("2026-03-03T14:45:00Z")
        stopped.schedule(at: updated, now: start, weekly: true, timeZone: newYork)
        precondition(stopped.weeklyContact?.next(after: updated) == date("2026-03-10T13:45:00Z"))
        for command in ["пауза", "закрой дело", "отмени напоминание"] {
            var item = consented
            item.receive(command, now: agreed)
            precondition(item.weeklyContact == nil && item.nextContact == nil && !item.hasDueQuestion)
            item.receive("возобновить", now: agreed)
            precondition(item.weeklyContact == nil && item.nextContact == nil)
        }

        let document = CareDocument(id: "weekly-fixture", name: "Пример.pdf", kind: .pdf, imported: start)
        var fromDocument = CarePlan()
        fromDocument.acceptFollowUp(fromDocument.documentFollowUp(for: document)!, now: start)
        fromDocument.schedule(at: agreed, now: start, weekly: true, timeZone: newYork)
        var correction = document
        correction.evidence = CareDocumentEvidence(studyDate: "2026-02-01", page: 1, quote: "Пример")
        for snapshot in [[], [correction]] {
            var derived = fromDocument
            derived.checkDue(now: agreed)
            derived.reconcileFollowUpSources(snapshot, now: agreed)
            precondition(derived.isClosed && !derived.hasDueQuestion && derived.weeklyContact == nil && derived.nextContact == nil)
            var independent = consented
            independent.acceptFollowUp(independent.documentFollowUp(for: document)!, now: start)
            independent.reconcileFollowUpSources(snapshot, now: start)
            precondition(independent.nextContact == agreed && independent.weeklyContact == weekly && independent.activeSource == nil)
        }
    }

    private static func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private static func reload(_ plan: CarePlan) throws -> CarePlan {
        try JSONDecoder().decode(CarePlan.self, from: JSONEncoder().encode(plan))
    }
}
