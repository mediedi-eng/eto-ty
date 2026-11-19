import Foundation
import PDFKit

enum PersonalBriefChecks {
    @MainActor
    static func run() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        var plan = CarePlan()
        plan.receive("Цель вымышленного визита", now: now)
        plan.schedule(at: now.addingTimeInterval(30), now: now)
        plan.checkDue(now: now.addingTimeInterval(31))
        plan.receive("Только выбранный ответ", now: now.addingTimeInterval(32))
        plan.receive("Непубличная запись", now: now.addingTimeInterval(33))
        let item = CareDocument(id: "synthetic", name: "Образец.pdf", kind: .pdf, imported: now, region: .heart,
                                evidence: CareDocumentEvidence(studyDate: "2026-10-02", page: 2, quote: "Фрагмент документа"))

        let empty = PersonalBrief.text(plan: plan, documents: [], includeTopic: false, includeAnswer: false)
        precondition(!empty.contains("визита") && !empty.contains("выбранный ответ"))
        let partial = PersonalBrief.text(plan: plan, documents: [item], includeTopic: false, includeAnswer: true)
        precondition(partial.contains("Только выбранный ответ") && !partial.contains("Цель вымышленного визита"))
        precondition(partial.contains("стр. 2") && partial.contains("2026-10-02"))
        precondition(!partial.contains("Непубличная запись"))
        let data = try VisitPDF.render(partial)
        let text = PDFDocument(data: data)?.string ?? ""
        precondition(text.contains("Образец.pdf") && text.contains("Фрагмент документа"))
        let context = PersonalBrief.text(plan: plan, documents: [], includeTopic: true, includeAnswer: false)
        precondition(context.contains("Цель вымышленного визита") && !context.contains("выбранный ответ"))
        var suggested = CarePlan()
        suggested.acceptFollowUp(CareDocumentFollowUp(document: item), now: now)
        let agreed = PersonalBrief.text(plan: suggested, documents: [], includeTopic: true, includeAnswer: false)
        precondition(agreed.contains("Согласованное дело в личном плане") && !agreed.contains("со слов пользователя"))
        precondition(!agreed.contains(item.name) && !agreed.contains("Фрагмент документа"))
        try checkSavedQuestions()
    }

    @MainActor
    private static func checkSavedQuestions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("profile")
        let storage = CareStorage(directory: directory)
        let docs = CareDocuments(directory: root.appendingPathComponent("archive"))
        func open() -> CareSession {
            CareSession(storage: storage, documents: docs, reminders: BriefReminderStub(), liveClock: false)
        }

        // An existing profile without the optional questions field opens normally.
        var original = CarePlan()
        original.receive("Подготовка к встрече")
        try storage.save(original)
        let session = open()
        precondition(session.plan.topic == original.topic && session.plan.visitQuestions.isEmpty)
        precondition(!session.addVisitQuestion(" \n "))
        precondition(session.addVisitQuestion("  Что обсудить на следующем приёме? \n"))
        precondition(!session.addVisitQuestion("Что обсудить на следующем приёме?"))
        precondition(session.addVisitQuestion("Как получить копию заключения?"))
        let questions = session.plan.visitQuestions
        precondition(questions.count == 2 && questions[0].text == "Что обсудить на следующем приёме?")
        let reopened = open()
        precondition(reopened.plan.visitQuestions == questions)
        func brief(_ ids: Set<UUID> = []) -> String {
            PersonalBrief.text(plan: reopened.plan, documents: [], includeTopic: false,
                               includeAnswer: false, includeQuestionIDs: ids)
        }
        precondition(!brief().contains("Мои вопросы врачу"))
        let selected = brief([questions[1].id])
        precondition(selected.contains(questions[1].text) && !selected.contains(questions[0].text))
        precondition(!selected.contains("Подготовка к встрече"))
        let pdf = PDFDocument(data: try VisitPDF.render(selected))?.string ?? ""
        precondition(pdf.contains(questions[1].text) && !pdf.contains(questions[0].text))

        // A failed write or delete must preserve the last saved selection and permit retry.
        let url = directory.appendingPathComponent("personal-profile.json")
        let saved = try Data(contentsOf: url)
        try Data([0]).write(to: url, options: .atomic)
        precondition(!reopened.addVisitQuestion("Ещё один вопрос") && reopened.statusText != nil)
        precondition(!reopened.deleteVisitQuestion(id: questions[1].id) && reopened.statusText != nil)
        precondition(reopened.plan.visitQuestions == questions)
        try saved.write(to: url, options: .atomic)
        precondition(reopened.deleteVisitQuestion(id: questions[1].id))
        precondition(!brief([questions[1].id]).contains(questions[1].text))
        precondition(open().plan.visitQuestions == [questions[0]])
        precondition(reopened.deleteVisitQuestion(id: questions[0].id))
        precondition(open().plan.visitQuestions.isEmpty)
    }
}

@MainActor
private final class BriefReminderStub: CareReminderDelivery {
    var onEvent: ((CareReminderEvent) -> Void)?
    func reconcile(date: Date?, requestPermission: Bool) async -> CareReminderStatus { .none }
}
