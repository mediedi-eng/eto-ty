import Foundation

/// Fixed teaching examples. Selecting an example never changes the personal profile.
enum PreventionExample: String, CaseIterable, Identifiable {
    case first = "Первый разговор"
    case family = "Семейная история"
    case record = "Есть результат"

    var id: Self { self }

    var summary: String {
        switch self {
        case .first:
            return "Мужчине 32 года, жалоб нет. Давление недавно измеряли в клинике, результат в обычном диапазоне. Врач оценил сердечно-сосудистый риск как низкий. Липидограмму раньше не сдавал."
        case .family:
            return "Такой же возраст, самочувствие и недавнее измерение давления. Появилось новое сведение: у отца был инфаркт в 48 лет. Врач ещё не учитывал это в оценке риска."
        case .record:
            return "Тот же мужчина с низким риском. Нашлась липидограмма за прошлый месяц. Врач уже обсудил с ним результат и указал в заключении срок следующего осмотра."
        }
    }

    var steps: [PreventionStep] {
        [Self.pressure, lipids, electrocardiogram]
    }

    private static let pressure = PreventionStep(
        id: "pressure", title: "Давление", status: .known,
        reason: "В истории примера есть недавнее измерение и его результат.",
        revisit: "При следующем обращении можно сверить срок контроля. Повышенные значения требуют подтверждения.",
        source: .pressure,
        goal: "Найти дату и результат последнего измерения давления"
    )

    private var lipids: PreventionStep {
        let status: PreventionStatus
        let reason: String
        let revisit: String
        let goal: String
        switch self {
        case .first:
            status = .next
            reason = "Предыдущей липидограммы нет. В руководстве ACC/AHA для взрослых предусмотрена проверка липидов."
            revisit = "Обсудить исходное измерение при плановом обращении. Прошлый результат, если он найдётся, может поменять этот шаг."
            goal = "Подготовить к приёму вопрос о липидограмме"
        case .family:
            status = .next
            reason = "Ранний инфаркт у родителя имеет значение для оценки сердечно-сосудистого риска и обсуждения липидов."
            revisit = "Рассказать врачу, у кого и в каком возрасте произошёл инфаркт. Уточнить, измеряли ли ранее липопротеин(а)."
            goal = "Уточнить семейную историю перед визитом к врачу"
        case .record:
            status = .known
            reason = "В заключении примера уже есть дата исследования, показатели и согласованный с врачом план."
            revisit = "Вернуться в срок, указанный врачом. Новые сведения о семейной истории могут изменить план."
            goal = "Проверить, сохранились ли прошлые анализы и рекомендации врача"
        }
        return PreventionStep(id: "lipids", title: "Липиды крови", status: status,
                              reason: reason, revisit: revisit, source: .lipids, goal: goal)
    }

    private var electrocardiogram: PreventionStep {
        if self == .family {
            return PreventionStep(
                id: "ecg", title: "Уточнение риска перед обсуждением ЭКГ", status: .next,
                reason: "Из-за новой семейной истории оценку риска предстоит уточнить. Показания к ЭКГ по одному этому сообщению неизвестны.",
                revisit: "Сначала обсудить изменившиеся сведения с врачом. Рекомендация о скрининге при низком риске относится к людям, у которых этот риск уже оценён.",
                source: .ecg, goal: "Подготовить вопрос врачу об оценке сердечно-сосудистого риска"
            )
        }
        return PreventionStep(
            id: "ecg", title: "ЭКГ", status: .later,
            reason: "В этом примере нет жалоб и установлен низкий риск. USPSTF рекомендует воздержаться от скрининговой ЭКГ в такой ситуации.",
            revisit: "Появление жалоб или изменение оценки риска создаёт другой медицинский вопрос.",
            source: .ecg, goal: nil
        )
    }
}

enum PreventionStatus: String, CaseIterable {
    case next = "Есть следующий шаг"
    case known = "Уже известно"
    case later = "Можно отложить"
}

enum PreventionSource {
    case pressure, lipids, ecg

    var label: String {
        switch self {
        case .pressure: return "USPSTF · США · 2021"
        case .lipids: return "ACC/AHA · США · 2026"
        case .ecg: return "USPSTF · США · 2018"
        }
    }

    var url: URL {
        switch self {
        case .pressure: return URL(string: "https://www.uspreventiveservicestaskforce.org/uspstf/recommendation/hypertension-in-adults-screening")!
        case .lipids: return URL(string: "https://www.jacc.org/doi/10.1016/j.jacc.2025.11.016")!
        case .ecg: return URL(string: "https://www.uspreventiveservicestaskforce.org/uspstf/recommendation/cardiovascular-disease-risk-screening-with-electrocardiography")!
        }
    }
}

struct PreventionStep: Identifiable {
    let id: String
    let title: String
    let status: PreventionStatus
    let reason: String
    let revisit: String
    let source: PreventionSource
    /// Generic first-person action. Never embeds a fact from the example.
    let goal: String?
}
