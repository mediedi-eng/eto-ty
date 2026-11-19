import Foundation

enum HistoryQueryChecks {
    static func run() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let scanned = CareDocument(id: "a", name: "IMG_0123.jpg", kind: .jpeg, imported: now, region: .kidneys,
                                   evidence: CareDocumentEvidence(studyDate: "2025-09-10", page: 1, quote: "УЗИ почек"))
        let ecg = CareDocument(id: "b", name: "Электрокардиограмма.pdf", kind: .pdf,
                               imported: now.addingTimeInterval(-20), region: nil)
        let unrelated = CareDocument(id: "c", name: "Протокол.pdf", kind: .pdf, imported: now, region: .heart)
        let documents = [ecg, unrelated, scanned]

        precondition(CareHistoryQuery.parse("Хочу найти старый результат") == nil)
        precondition(CareHistoryQuery.parse("Не ищи ЭКГ") == nil)
        precondition(CareHistoryQuery.parse("Покажи план") == nil)
        precondition(CareHistoryQuery.parse("Найди клинику рядом") == nil)
        precondition(CareHistoryQuery.parse("Найди где сделать ЭКГ") == nil)
        precondition(CareHistoryQuery.parse("Пожалуйста, покажи последние документы!") == .recent)
        precondition(CareHistoryQuery.recent.matches(in: documents).map(\.id) == ["a", "c", "b"])

        let kidneys = CareHistoryQuery.parse("Что мы знаем о почках?")!
        precondition(kidneys.matches(in: documents) == [scanned])
        precondition(CareHistoryQuery.parse("Покажи документы по почкам")?.matches(in: documents) == [scanned])
        precondition(CareHistoryQuery.parse("Найди УЗИ почек")?.matches(in: documents) == [scanned])
        precondition(CareHistoryQuery.parse("Найди ЭКГ")?.matches(in: documents) == [ecg])
        precondition(CareHistoryQuery.parse("Найди в документах 2025-09-10")?.matches(in: documents) == [scanned])
        precondition(CareHistoryQuery.parse("Что известно о печени?")?.matches(in: documents).isEmpty == true)
        precondition(kidneys.matches(in: []).isEmpty)

        var changed = scanned
        changed.region = nil
        changed.evidence = nil
        precondition(kidneys.matches(in: [changed, ecg]).isEmpty)
        var plan = CarePlan()
        plan.receive("Найди ЭКГ", now: now)
        precondition(CareHistoryQuery.latest(in: plan)?.matches(in: documents) == [ecg])
        plan.receive("Хочу подготовиться к приёму", now: now)
        precondition(CareHistoryQuery.latest(in: plan) == nil)
    }
}
