import Foundation

enum CareHistoryQuery: Equatable {
    case recent
    case terms([String])

    static func latest(in plan: CarePlan) -> Self? {
        guard let last = plan.messages.last(where: { $0.fromUser }) else { return nil }
        return parse(last.text)
    }

    static func parse(_ text: String) -> Self? {
        let words = words(in: text).drop(while: { $0 == "пожалуйста" })
        guard !words.isEmpty else { return nil }
        let knowledge = [["что", "мы", "знаем", "о"], ["что", "мы", "знаем", "об"],
                         ["что", "мы", "знаем", "про"], ["что", "известно", "о"],
                         ["что", "известно", "об"], ["что", "есть", "по"]]
        if let intro = knowledge.first(where: { words.starts(with: $0) }) {
            let terms = searchTerms(in: words.dropFirst(intro.count))
            return terms.isEmpty ? nil : .terms(terms)
        }

        guard let verb = words.first, ["найди", "поищи", "покажи", "отыщи"].contains(verb) else { return nil }
        let rest = words.dropFirst()
        if rest.contains(where: { ["где", "сделать", "сдать", "пройти", "клинику", "врача", "записаться", "запись"].contains($0) }) {
            // An explicit search inside the archive can still include any of these words.
            let phrase = rest.joined(separator: " ")
            guard ["в архиве", "в документах", "в результатах", "в файлах"].contains(where: phrase.contains) else { return nil }
        }
        let archive = rest.contains { archiveWords.contains($0) }
        let recognisable = rest.contains { word in recordTerms.contains(normalized(word)) }
        guard archive || recognisable else { return nil }
        let terms = searchTerms(in: rest)
        return terms.isEmpty ? .recent : .terms(terms)
    }

    func matches(in documents: [CareDocument]) -> [CareDocument] {
        let selected: [CareDocument]
        switch self {
        case .recent:
            selected = documents
        case .terms(let terms):
            selected = documents.filter { document in
                let fields = [document.name, document.region?.rawValue,
                              document.evidence?.quote, document.evidence?.studyDate]
                let tokens = Set(fields.compactMap { $0 }.flatMap { Self.words(in: $0).map(Self.normalized) })
                return terms.allSatisfy { tokens.contains($0) }
            }
        }
        return selected.sorted { lhs, rhs in
            lhs.imported == rhs.imported ? lhs.id < rhs.id : lhs.imported > rhs.imported
        }
    }

    private static func words(in text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    private static let archiveWords: Set<String> = [
        "архив", "архиве", "архива", "документы", "документ", "документах", "документа",
        "результат", "результаты", "результатах", "файл", "файлы", "файлах"
    ]
    private static let modifiers: Set<String> = [
        "мне", "мой", "моя", "мою", "мои", "моем", "моих", "у", "меня", "есть",
        "все", "в", "по", "о", "об", "про", "за", "с", "из", "на", "и", "пожалуйста",
        "последние", "последний", "последнюю", "свежие", "сохраненные", "загруженные"
    ]
    private static let recordTerms: Set<String> = [
        "экг", "эхокг", "узи", "липидограмма", "выписка", "заключение", "мрт", "кт",
        "сердце", "почки", "печень", "анализ"
    ]

    private static func searchTerms(in words: ArraySlice<String>) -> [String] {
        words.filter { !modifiers.contains($0) && !archiveWords.contains($0) }.map(normalized)
    }

    // Map only explicit forms and equivalent test names. A heart tag alone doesn't establish an ECG.
    private static func normalized(_ word: String) -> String {
        switch word {
        case "почек", "почка", "почке", "почку", "почкам", "почками", "почках", "почки": return "почки"
        case "сердце", "сердца", "сердцем", "сердцу": return "сердце"
        case "печень", "печени", "печенью": return "печень"
        case "экг", "ecg", "ekg", "электрокардиограмма", "электрокардиограмму", "электрокардиограммы": return "экг"
        case "эхокг", "эхокардиография", "эхокардиографию": return "эхокг"
        case "липидограмму", "липидограммы": return "липидограмма"
        case "выписку", "выписки": return "выписка"
        case "заключения": return "заключение"
        case "анализы", "анализа", "анализах": return "анализ"
        default: return word
        }
    }
}
