import Foundation

enum CarePressureRecord: String, Codable, CaseIterable, Identifiable {
    case clinicianPlan, previousMeasurement, noRecord, unsure

    static let question = "Что у тебя уже есть про артериальное давление?"
    var id: Self { self }
    var label: String {
        switch self {
        case .clinicianPlan: return "Есть рекомендации моего врача"
        case .previousMeasurement: return "Давление измеряли, могу поискать запись"
        case .noRecord: return "У меня нет записи с результатом"
        case .unsure: return "Не помню"
        }
    }
}

enum CarePressureContext: String, Codable, CaseIterable, Identifiable {
    case adultWithoutKnownHypertension, individualPlan, unsure

    static let question = "Какая ситуация подходит тебе?"
    var id: Self { self }
    var label: String {
        switch self {
        case .adultWithoutKnownHypertension: return "Мне 18 лет или больше, гипертонию не диагностировали, беременности нет"
        case .individualPlan: return "Мне меньше 18 лет, есть беременность или уже диагностировали гипертонию"
        case .unsure: return "Затрудняюсь ответить"
        }
    }
}

struct CarePreparationStep: Equatable {
    let action: String
    let reason: String
    let visitQuestion: String
}

/// Only explicit choices are persisted. The visit action is derived on demand and never schedules a test.
struct CarePreventionPreparation: Codable, Equatable {
    var record: CarePressureRecord?
    var context: CarePressureContext?

    static let sourceLabel = "USPSTF · США · 27 апреля 2021"
    static let sourceURL = PreventionSource.pressure.url
    static let sourceScope = "USPSTF рекомендует скрининг гипертонии взрослым с 18 лет без установленной гипертонии. У USPSTF есть отдельное руководство для беременности. Срок для себя можно обсудить со своим врачом."

    var showsContextQuestion: Bool { record != .clinicianPlan }

    var step: CarePreparationStep {
        if record == .clinicianPlan {
            return CarePreparationStep(
                action: "Найти рекомендации врача по давлению и проверить, указан ли срок",
                reason: "У тебя есть рекомендации врача. Их можно взять на приём и уточнить, актуальны ли они.",
                visitQuestion: "Есть ли в моём плане срок следующего измерения давления и остаётся ли он актуальным?"
            )
        }
        if context == .individualPlan {
            return CarePreparationStep(
                action: "Подготовить вопрос об индивидуальном плане наблюдения за давлением",
                reason: "По твоему ответу для обсуждения стоит взять индивидуальный план. Если сохранились записи давления, их можно взять к врачу.",
                visitQuestion: "Какой план наблюдения за давлением подходит в моей ситуации?"
            )
        }
        if record == .previousMeasurement {
            return CarePreparationStep(
                action: "Найти дату и запись последнего измерения давления",
                reason: "Ты помнишь измерение. Запись с датой поможет врачу увидеть, какие сведения уже есть.",
                visitQuestion: "Что важно учесть по этой записи и когда мне стоит вернуться к вопросу о давлении?"
            )
        }
        let reason: String
        switch record {
        case .noRecord:
            reason = "По твоему ответу записи под рукой нет. Можно заранее подготовить вопрос для врача."
        case .unsure:
            reason = "Ты не помнишь прошлое измерение. Этот вопрос можно обсудить, даже если запись не найдётся."
        default:
            reason = "Можно начать с вопроса к врачу, даже если сведений о прошлых измерениях пока нет."
        }
        return CarePreparationStep(
            action: "Записать вопрос врачу об измерении давления",
            reason: reason,
            visitQuestion: context == .adultWithoutKnownHypertension
                ? "Когда с учётом моей истории мне стоит проверить давление?"
                : "Как мне обсудить контроль давления с учётом моей ситуации?"
        )
    }
}
