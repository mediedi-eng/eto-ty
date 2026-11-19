import Foundation

enum DocumentFollowUpChecks {
    static func run() throws {
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        let later = start.addingTimeInterval(600)
        let blank = CareDocument(id: "file-a", name: "Пример.pdf", kind: .pdf, imported: start)
        var reviewed = blank
        reviewed.evidence = CareDocumentEvidence(studyDate: "2026-01-12", page: 2, quote: "Вымышленный исходный фрагмент")
        var corrected = reviewed
        corrected.evidence = CareDocumentEvidence(studyDate: "2026-01-12", page: 3, quote: "Исправленная строка")
        let other = CareDocument(id: "file-b", name: "Фото", kind: .jpeg, imported: start)

        var plan = CarePlan()
        let initial = plan.documentFollowUp(for: blank)!
        precondition(!initial.isReviewed && initial.quote == nil && initial.page == nil)
        let known = plan.documentFollowUp(for: reviewed)!
        precondition(known.isReviewed && known.id != initial.id && known.page == 2 && known.studyDate == "2026-01-12")

        // The source file identity and confirmed facts determine sameness; an alias or second import is immaterial.
        let duplicate = CareDocument(id: blank.id, name: "другое имя.pdf", kind: .pdf,
                                     imported: later, evidence: reviewed.evidence)
        precondition(plan.documentFollowUp(for: duplicate)?.id == known.id)
        plan.dismissFollowUp(initial)
        plan.dismissFollowUp(initial)
        plan = try roundTrip(plan)
        precondition(plan.documentFollowUp(for: blank) == nil && plan.documentFollowUp(for: reviewed) != nil)
        plan.acceptFollowUp(initial, now: start)
        precondition(plan.topic == nil)
        plan.acceptFollowUp(known, now: start)
        let accepted = plan
        plan.acceptFollowUp(known, now: start)
        plan.reconcileFollowUpSources([reviewed], now: start)
        precondition(plan == accepted && plan.activeSource?.versionID == known.id && plan.activeSource?.createdTopic == true)
        precondition(plan.documentFollowUp(for: other) == nil && plan.nextContact == nil)
        let persisted = try JSONEncoder().encode(plan)
        let serialized = String(decoding: persisted, as: UTF8.self)
        precondition(!serialized.contains(reviewed.name) && !serialized.contains(known.quote!))
        plan = try roundTrip(plan)
        plan.schedule(at: later, now: start)
        plan.reconcileFollowUpSources([corrected], now: start)
        precondition(plan.activeSource == nil && plan.nextContact == nil && plan.isClosed && !plan.hasDueQuestion)
        let count = plan.messages.count
        plan.reconcileFollowUpSources([corrected], now: start)
        precondition(plan.messages.count == count && plan.documentFollowUp(for: corrected) != nil)

        var independent = CarePlan()
        independent.receive("Подготовить вопросы", now: start)
        independent.schedule(at: later, now: start)
        let attached = independent.documentFollowUp(for: reviewed)!
        independent.acceptFollowUp(attached, now: start)
        precondition(independent.topic == "Подготовить вопросы" && independent.nextContact == later)
        precondition(independent.activeSource?.createdTopic == false)
        var paused = independent
        paused.pause()
        paused.reconcileFollowUpSources([], now: start)
        precondition(paused.isPaused && !paused.isClosed && paused.activeSource == nil)
        precondition(paused.documentFollowUp(for: other) == nil)
        independent.reconcileFollowUpSources([corrected], now: start)
        precondition(independent.nextContact == later && !independent.isClosed && independent.activeSource == nil)
        independent.checkDue(now: later)
        precondition(independent.documentFollowUp(for: corrected) == nil && independent.hasDueQuestion)
        independent.receive("Записал", now: later)
        independent.acceptFollowUp(independent.documentFollowUp(for: corrected)!, now: later)
        independent.finish()
        precondition(independent.activeSource == nil && independent.documentFollowUp(for: corrected) == nil)
        independent.reconcileFollowUpSources([], now: later)
        precondition(independent.documentFollowUp(for: corrected) != nil)

        // A legacy version-1 file lacking both new optional keys can be read without migration.
        let old = Data(#"{"messages":[],"topic":"Старое дело","isPaused":false,"isClosed":false,"hasDueQuestion":false}"#.utf8)
        let legacy = try JSONDecoder().decode(CarePlan.self, from: old)
        precondition(legacy.activeSource == nil && legacy.topic == "Старое дело" && legacy.documentFollowUp(for: blank) != nil)
    }

    private static func roundTrip(_ plan: CarePlan) throws -> CarePlan {
        try JSONDecoder().decode(CarePlan.self, from: JSONEncoder().encode(plan))
    }
}
