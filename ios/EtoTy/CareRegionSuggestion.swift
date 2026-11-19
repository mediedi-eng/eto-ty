import Foundation

/// The archive applies a suggestion only when the owner confirms it.
enum CareRegionSuggestion {
    struct Hint: Equatable {
        let region: Region
        let quotePage: Int?

        var explanation: String {
            if let quotePage {
                return "По сверенной цитате на стр. " + String(quotePage) + " · " + region.rawValue
            }
            return "По названию файла · " + region.rawValue
        }
    }

    static func fromTitle(_ name: String) -> Region? {
        hint(name: name, quote: nil, page: nil)?.region
    }

    static func hint(name: String, quote: String?, page: Int?) -> Hint? {
        let titleAreas = areas(in: (name as NSString).deletingPathExtension)
        guard titleAreas.count <= 1 else { return nil }
        let titleHint = titleAreas.first.map { Hint(region: $0, quotePage: nil) }
        guard let quote, let page, page > 0 else { return titleHint }
        let heading = quote.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        // Only complete study headings can introduce a new region. A mention in prose cannot.
        let area: Region
        switch heading {
        case "экг", "эхокг", "электрокардиограмма", "эхокардиография", "узи сердца",
             "ecg", "ekg", "echocardiogram": area = .heart
        case "узи почек", "ультразвуковое исследование почек", "renal ultrasound",
             "kidney ultrasound": area = .kidneys
        case "узи печени", "ультразвуковое исследование печени", "liver ultrasound": area = .liver
        default:
            if let titleHint, !areas(in: quote).subtracting([titleHint.region]).isEmpty { return nil }
            return titleHint
        }
        guard titleAreas.isEmpty || titleAreas.contains(area) else { return nil }
        return Hint(region: area, quotePage: page)
    }

    private static func areas(in text: String) -> Set<Region> {
        let words = text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
        let heart: Set<String> = ["экг", "эхокг", "электрокардиограмма", "эхокардиография",
                                  "сердца", "сердце", "ecg", "ekg", "echocardiogram", "cardiac", "heart"]
        let kidneys: Set<String> = ["почек", "почки", "почка", "почку", "kidneys", "kidney", "renal"]
        let liver: Set<String> = ["печени", "печень", "liver", "hepatic"]
        let tokens = Set(words)
        var found = Set<Region>()
        if !tokens.isDisjoint(with: heart) { found.insert(.heart) }
        if !tokens.isDisjoint(with: kidneys) { found.insert(.kidneys) }
        if !tokens.isDisjoint(with: liver) { found.insert(.liver) }
        return found
    }
}
