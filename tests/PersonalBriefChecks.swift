import Foundation
import PDFKit

enum PersonalBriefChecks {
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
    }
}
