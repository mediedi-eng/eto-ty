import Foundation

enum PersonalBrief {
    static func text(plan: CarePlan, documents: [CareDocument], includeTopic: Bool, includeAnswer: Bool,
                     includeQuestionIDs: Set<UUID> = []) -> String {
        var sections = ["К приёму · Это ты"]
        if includeTopic, let topic = plan.topic {
            sections.append("Согласованное дело в личном плане\n" + topic)
        }
        let questions = plan.visitQuestions.filter { includeQuestionIDs.contains($0.id) }
        if !questions.isEmpty {
            let lines = questions.map { "• " + $0.text }
            sections.append("Мои вопросы врачу\n" + lines.joined(separator: "\n"))
        }
        if includeAnswer, let answer = plan.lastAnswer {
            sections.append("Последний ответ в диалоге · " + dateLabel(answer.createdAt) + "\n" + answer.text +
                            "\nИсточник: со слов пользователя.")
        }
        for doc in documents {
            var lines = [doc.name]
            if let area = doc.region { lines.append("Область, выбранная пользователем: " + area.rawValue) }
            lines.append("Дата исследования: " + (doc.evidence?.studyDate ?? "не указана"))
            lines.append("Добавлено в приложение: " + dateLabel(doc.imported))
            if let quote = doc.evidence?.quote, !quote.isEmpty {
                let location = doc.evidence?.page.map { " · стр. " + String($0) } ?? ""
                lines.append("Фрагмент, подтверждённый пользователем" + location + ":\n«" + quote + "»")
            }
            sections.append(lines.joined(separator: "\n"))
        }
        if sections.count == 1 {
            sections.append("Для сводки пока ничего не выбрано.")
        } else {
            sections.append("Сводка составлена из выбранных сведений. Оригиналы можно показать отдельно.")
        }
        return sections.joined(separator: "\n\n")
    }

    private static func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.setLocalizedDateFormatFromTemplate("d MMMM yyyy")
        return formatter.string(from: date)
    }
}
