import Foundation

enum Region: String, CaseIterable, Identifiable {
    case heart = "Сердце", liver = "Печень", kidneys = "Почки"
    var id: Self { self }
}

struct SourceExcerpt: Identifiable {
    let id: String
    let region: Region
    let document: String
    let eventDate: String
    let uploaded: String
    let page: Int
    let quote: String
    let question: String?
}

struct Night: Equatable {
    let date: String
    let minutes: Int
    let source: String
}

struct ChatLine: Identifiable {
    let id = UUID()
    let text: String
    let fromUser: Bool
}

struct PilotProfile {
    // The first build is a one-session synthetic fixture, with no disk or network writes.
    let excerpts = [
        SourceExcerpt(id: "ecg", region: .heart, document: "Заключение ЭКГ", eventDate: "02.11.2026",
                      uploaded: "18.11.2026", page: 2, quote: "Обсудить результат ЭКГ на приёме 20 ноября.",
                      question: "Что означает указанная в заключении рекомендация обсудить результат?"),
        SourceExcerpt(id: "us", region: .kidneys, document: "Протокол УЗИ", eventDate: "12.03.2026",
                      uploaded: "18.11.2026", page: 1, quote: "В протоколе есть раздел «Почки».",
                      question: nil)
    ]
    private(set) var nights = [Night(date: "15.11.2026", minutes: 440, source: "Дневник")]
    private(set) var messages = [ChatLine(text: "Мы договаривались вернуться к твоим записям сна в пятницу. Здесь уже есть запись за 15 ноября. Хочешь посмотреть наш план?", fromUser: false)]
    private(set) var paused = false
    private(set) var trendReviewed = false
    private(set) var trendEstablished = false

    var level: Int { trendReviewed ? 4 : (trendEstablished ? 3 : 2) }

    var levelReason: String {
        if trendReviewed { return "Итог по сну отмечен, согласованный цикл завершён." }
        if trendEstablished { return "По сну получены записи за разные ночи из одного источника при согласованном наблюдении." }
        return "Есть исходная запись дневника за 15 ноября и договорённость о разговоре."
    }

    var plan: String {
        if paused { return "Инициативные обращения на паузе. Можно продолжать писать самостоятельно." }
        if trendReviewed { return "Цикл по сну завершён. Следующий контакт пока не согласован." }
        return "В пятницу, 20 ноября, вернёмся к дневнику сна. В этой сборке внешняя отправка ещё не подключена."
    }

    func materials(for region: Region?) -> [SourceExcerpt] {
        excerpts.filter { region == nil || $0.region == region }
    }

    mutating func importExampleDiary() {
        let example = [Night(date: "16.11.2026", minutes: 425, source: "Дневник"),
                       Night(date: "17.11.2026", minutes: 450, source: "Дневник")]
        let fresh = example.filter { candidate in
            !nights.contains { $0.date == candidate.date && $0.source == candidate.source }
        }
        guard !fresh.isEmpty else { return }
        nights.append(contentsOf: fresh)
        if !paused { trendEstablished = true }
        reply("Добавлены две вымышленные записи из дневника. Теперь доступны даты 15, 16 и 17 ноября.")
    }

    mutating func reviewTrend() {
        guard trendEstablished, !paused, !trendReviewed else { return }
        trendReviewed = true
        reply("Ты отметил, что записи просмотрены. Закрыл этот цикл и снял будущий вопрос.")
    }

    mutating func discuss(_ region: Region) {
        messages.append(ChatLine(text: "Что мы знаем по теме «" + region.rawValue + "»?", fromUser: true))
        let records = materials(for: region)
        if records.isEmpty { reply("В профиле пока нет подтверждённых материалов по этой области."); return }
        reply(records.map { "«" + $0.quote + "» — " + $0.document + ", " + $0.eventDate + ", стр. " + String($0.page) }.joined(separator: "\n"))
    }

    mutating func receive(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        messages.append(ChatLine(text: value, fromUser: true))
        switch value.lowercased() {
        case "пауза", "пока не пиши первым":
            paused = true
            reply(plan)
        case "возобновить":
            paused = false
            if Set(nights.filter { $0.source == "Дневник" }.map(\.date)).count >= 2 { trendEstablished = true }
            reply(plan)
        case "план", "что ты ведёшь?":
            reply(plan)
        default:
            reply("В этой локальной сборке свободный разбор ещё не подключён. Могу показать план или поставить обращения на паузу.")
        }
    }

    private mutating func reply(_ text: String) { messages.append(ChatLine(text: text, fromUser: false)) }

    func visitSummary(region: Region?) -> String {
        let records = materials(for: region)
        var lines = ["Это ты · вымышленный профиль", "Сводка к приёму · демонстрационные данные",
                     "Цель: обсудить уже имеющиеся материалы.", "Область: " + (region?.rawValue ?? "общий обзор")]
        lines.append("Подтверждённые записи")
        if records.isEmpty { lines.append("По выбранной области сведений в профиле нет.") }
        for record in records {
            lines.append(record.region.rawValue + " · " + record.document + " · " + record.eventDate + " · стр. " + String(record.page))
            lines.append("«" + record.quote + "»")
        }
        if region == nil {
            lines.append("Со слов пользователя · дневник сна")
            lines.append(contentsOf: nights.map { $0.date + " · " + String($0.minutes) + " мин · " + $0.source })
        }
        let questions = records.compactMap(\.question)
        if !questions.isEmpty { lines.append("Вопросы к врачу"); lines.append(contentsOf: questions) }
        lines.append("Лекарства и аллергии: в этом примере сведений нет.")
        return lines.joined(separator: "\n")
    }
}
