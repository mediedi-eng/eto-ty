import Foundation

enum VisitSourceChecks {
    static func run() {
        for kind in [CareDocumentKind.jpeg, .pdf] {
            let page = kind == .pdf ? 2 : 1
            let evidence = CareDocumentEvidence(studyDate: "2026-02-10", page: page, quote: "УЗИ почек")
            var source = CareDocument(id: "source", name: "Example." + kind.rawValue, kind: kind,
                                      imported: Date(timeIntervalSince1970: 0), evidence: evidence)
            let other = CareDocument(id: "other", name: "Other.pdf", kind: .pdf,
                                     imported: source.imported, region: .heart)
            let hint = CareRegionSuggestion.hint(name: source.name, quote: evidence.quote, page: evidence.page)
            precondition(hint?.region == .kidneys && hint?.quotePage == page)
            precondition(CareMapRegion(.kidneys, documents: [source]).documents.isEmpty)

            // The user accepts the suggestion and then opens the visit brief from that area.
            source.region = hint?.region
            let archive = [other, source]
            let row = CareMapRegion(.kidneys, documents: archive)
            precondition(row.latestDatedSource == source)
            precondition(BriefDocumentSelection.chosen(in: archive, selected: []).isEmpty)
            precondition(BriefDocumentSelection.available(in: archive, area: row.area, selected: []) == [source])
            let include: Set<String> = [source.id]
            precondition(BriefDocumentSelection.available(in: archive, area: .heart, selected: include) == [other])
            let selected = BriefDocumentSelection.chosen(in: archive, selected: include)
            precondition(selected.count == 1 && selected.first?.evidence == evidence)
            precondition(BriefDocumentSelection.chosen(in: [other], selected: include).isEmpty)
        }
    }
}
