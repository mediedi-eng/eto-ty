import Foundation

enum MapCoverageChecks {
    static func run() {
        let time = Date(timeIntervalSince1970: 1_860_000_000)
        func item(_ id: String, area: Region?, study: String?, quote: String?, page: Int?, imported: Date) -> CareDocument {
            CareDocument(id: id, name: "Пример.pdf", kind: .pdf, imported: imported, region: area,
                         evidence: CareDocumentEvidence(studyDate: study, page: page, quote: quote))
        }
        let previous = item("second-import", area: .heart, study: "2021-04-03", quote: "Строка А", page: 1, imported: time)
        let recent = item("first-import", area: .heart, study: "2025-03-02", quote: "Строка Б", page: 2, imported: time.addingTimeInterval(-60))
        let noDate = item("undated", area: .kidneys, study: nil, quote: "Без даты", page: 1, imported: time)
        let noFragment = item("date-only", area: .liver, study: "2026-11-02", quote: nil, page: nil, imported: time)
        let noPage = item("no-page", area: .liver, study: "2026-11-03", quote: "Пример", page: nil, imported: time)
        let noArea = item("unlinked", area: nil, study: "2026-11-03", quote: "Пример", page: 1, imported: time)
        let archive = [previous, recent, noDate, noFragment, noPage, noArea]
        let rows = Region.allCases.map { CareMapRegion($0, documents: archive) }
        precondition(rows.compactMap(\.latestDatedSource) == [recent])
        precondition(CareMapRegion(.kidneys, documents: archive).hasConfirmedExcerpt)
        precondition(!CareMapRegion(.liver, documents: archive).hasConfirmedExcerpt)
        precondition(CareMapRegion(.heart, documents: [noArea]).documents.isEmpty)
    }
}
