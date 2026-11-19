import Foundation

/// One row per supported area. Only user-confirmed evidence affects the level.
struct CareMapRegion: Identifiable {
    let area: Region
    let documents: [CareDocument]
    var id: Region { area }
    let latestDatedSource: CareDocument?
    let hasConfirmedExcerpt: Bool

    init(_ area: Region, documents: [CareDocument]) {
        self.area = area
        self.documents = documents.filter { $0.region == area }
        let reviewed = self.documents.filter { document in
            guard let evidence = document.evidence, let page = evidence.page, page > 0,
                  let quote = evidence.quote else { return false }
            return !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        hasConfirmedExcerpt = !reviewed.isEmpty
        latestDatedSource = reviewed.filter { $0.evidence?.studyDate != nil }.max(by: Self.earlierStudy)
    }

    // Dates from the archive use yyyy-MM-dd. A newly imported old study must not displace a newer one.
    static func earlierStudy(_ lhs: CareDocument, _ rhs: CareDocument) -> Bool {
        let left = lhs.evidence?.studyDate ?? ""
        let right = rhs.evidence?.studyDate ?? ""
        if left != right { return left < right }
        if lhs.imported != rhs.imported { return lhs.imported < rhs.imported }
        return lhs.id < rhs.id
    }

    var summary: String {
        if let date = latestDatedSource?.evidence?.studyDate { return "Сверен фрагмент · " + date }
        if hasConfirmedExcerpt { return "Сверен фрагмент · дата исследования не указана" }
        if !documents.isEmpty { return "Есть документ · фрагмент пока не выбран" }
        return "Пока нет связанных документов"
    }
}
