import Foundation
import PDFKit

@main
struct PilotChecks {
    static func main() throws {
        var profile = PilotProfile()
        precondition(profile.level == 2)
        precondition(profile.materials(for: .liver).isEmpty)
        profile.discuss(.kidneys)
        precondition(profile.messages.last!.text.contains("стр. 1"))
        profile.importExampleDiary()
        precondition(profile.level == 3 && profile.nights.count == 3)
        let count = profile.messages.count
        profile.importExampleDiary()
        precondition(profile.messages.count == count && profile.nights.count == 3)
        profile.receive("Пауза")
        profile.reviewTrend()
        precondition(profile.paused && !profile.trendReviewed)
        profile.receive("Возобновить")
        profile.reviewTrend()
        precondition(profile.level == 4 && profile.plan.contains("завершён"))

        var paused = PilotProfile()
        paused.receive("Пауза")
        paused.importExampleDiary()
        precondition(paused.level == 2 && paused.paused)
        paused.receive("Возобновить")
        precondition(paused.level == 3)

        let brief = profile.visitSummary(region: .heart)
        precondition(brief.contains("02.11.2026") && brief.contains("стр. 2"))
        precondition(!brief.contains("Протокол УЗИ") && !brief.contains("мин · Дневник"))
        let empty = profile.visitSummary(region: .liver)
        precondition(empty.contains("сведений в профиле нет"))
        let full = profile.visitSummary(region: nil)
        let pdf = try VisitPDF.render(full)
        guard let document = PDFDocument(data: pdf), let text = document.string else { fatalError("PDF is unreadable") }
        precondition(document.pageCount == 1 && text.contains("Протокол УЗИ") && text.contains("02.11.2026") && text.contains("сведений нет"))
        let long = String(repeating: "Вымышленная запись для проверки переноса строки и страницы.\n", count: 110) + "Конец сводки"
        let longPDF = PDFDocument(data: try VisitPDF.render(long))!
        precondition(longPDF.pageCount > 1 && longPDF.string!.contains("Конец сводки"))

        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--sample-pdf" {
            try pdf.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
        }
        print("Verified topic state, pause, duplicate import, source scope, searchable Russian PDF and pagination.")
    }
}
