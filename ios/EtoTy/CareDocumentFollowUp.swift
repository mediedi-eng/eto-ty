import CryptoKit
import Foundation

/// Built from the local archive when shown. The profile persists only the source reference and decision.
struct CareDocumentFollowUp: Identifiable, Equatable {
    let id: String
    let documentID: String
    let documentName: String
    let quote: String?
    let page: Int?
    let studyDate: String?

    var isReviewed: Bool { quote != nil && page != nil }
    var title: String { isReviewed ? "Есть фрагмент для обсуждения" : "Посмотреть, что важно в документе" }
    var action: String { isReviewed ? "Подготовить вопрос к приёму по выбранному фрагменту" : "Сверить документ и отметить важный фрагмент" }

    init(document: CareDocument) {
        documentID = document.id
        documentName = document.name
        quote = document.evidence?.quote
        page = document.evidence?.page
        studyDate = document.evidence?.studyDate
        // Length-prefix UTF-8 bytes so a quote with arbitrary punctuation can't collide with another field.
        // Keeping the file's display name and import time out makes repeat imports stable.
        let fields: [String?] = ["follow-up-v1", document.id, document.region?.rawValue, studyDate, page.map(String.init), quote]
        var data = Data()
        for field in fields {
            if let field {
                data.append(contentsOf: String(field.utf8.count).utf8)
                data.append(58)
                data.append(contentsOf: field.utf8)
            } else {
                data.append(contentsOf: "-:".utf8)
            }
        }
        id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct CareSourceReference: Codable, Equatable {
    let documentID: String
    let versionID: String
    let createdTopic: Bool
}

enum CareFollowUpDecision: String, Codable {
    case accepted, dismissed
}
