import Foundation

enum CareDocumentKind: String, Codable {
    case pdf, jpeg, png, heic
}

struct CareDocumentEvidence: Codable, Equatable {
    let studyDate: String?
    let page: Int?
    let quote: String?

    static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}

struct CareDocument: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: CareDocumentKind
    let imported: Date
    var region: Region?
    var evidence: CareDocumentEvidence?
}
