import Foundation

/// A hint about the title only. The archive applies it after the owner confirms.
enum CareRegionSuggestion {
    static func fromTitle(_ name: String) -> Region? {
        let words = (name as NSString).deletingPathExtension.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let heart: Set<String> = ["экг", "эхокг", "электрокардиограмма", "эхокардиография",
                                  "сердца", "сердце", "ecg", "ekg", "echocardiogram", "cardiac", "heart"]
        let kidneys: Set<String> = ["почек", "почки", "почка", "почку", "kidneys", "kidney", "renal"]
        let liver: Set<String> = ["печени", "печень", "liver", "hepatic"]
        let tokens = Set(words)
        var found = [Region]()
        if !tokens.isDisjoint(with: heart) { found.append(.heart) }
        if !tokens.isDisjoint(with: kidneys) { found.append(.kidneys) }
        if !tokens.isDisjoint(with: liver) { found.append(.liver) }
        return found.count == 1 ? found.first : nil
    }
}
