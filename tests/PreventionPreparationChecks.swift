import Foundation

enum PreventionPreparationChecks {
    static func run() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let legacy = Data(#"{"messages":[],"isPaused":false,"isClosed":false,"hasDueQuestion":false}"#.utf8)
        var plan = try JSONDecoder().decode(CarePlan.self, from: legacy)
        let initial = plan
        let fallback = plan.preparation.step
        precondition(plan.preparation == CarePreventionPreparation() && plan.topic == nil)
        precondition(plan.canStartPreparationGoal && fallback.action.contains("вопрос") && fallback.visitQuestion.contains("?"))
        precondition(CarePreventionPreparation.sourceURL.host == "www.uspreventiveservicestaskforce.org")
        precondition(CarePreventionPreparation.sourceLabel.contains("2021") && CarePreventionPreparation.sourceLabel.contains("США"))

        plan.setPressureRecord(.previousMeasurement)
        precondition(plan.preparation.step.action.contains("дату") && plan.preparation.showsContextQuestion)
        precondition(!plan.startPreparationGoal(fallback, now: now)) // A stale displayed action cannot start a new goal.
        plan.setPressureContext(.adultWithoutKnownHypertension)
        precondition(plan.preparation.step.action.contains("последнего измерения"))
        plan.setPressureContext(.individualPlan)
        let individual = plan.preparation.step
        precondition(individual.action.contains("индивидуальном") && individual.visitQuestion.contains("моей ситуации"))
        let encoded = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(CarePlan.self, from: encoded)
        precondition(decoded == plan && decoded.topic == nil && decoded.messages == initial.messages)

        // When the user has a clinician's plan, refer to it regardless of the demographic answers.
        for context in [nil, .unsure, .adultWithoutKnownHypertension, .individualPlan] as [CarePressureContext?] {
            plan.setPressureRecord(.clinicianPlan)
            plan.setPressureContext(context)
            precondition(!plan.preparation.showsContextQuestion && plan.preparation.step.action.contains("рекомендации врача"))
        }

        // All missing answers, an explicitly unknown answer and an absent record have distinct explanations.
        plan.setPressureContext(nil)
        plan.setPressureRecord(.noRecord)
        let noRecord = plan.preparation.step
        plan.setPressureRecord(.unsure)
        let unsure = plan.preparation.step
        precondition(noRecord.reason != unsure.reason && unsure.reason != fallback.reason)
        plan.setPressureRecord(nil)
        precondition(plan == initial)
        let cleared = try JSONEncoder().encode(plan)
        precondition(!String(decoding: cleared, as: UTF8.self).contains("pressurePreparation"))

        plan.setPressureContext(.individualPlan)
        let selected = plan.preparation.step
        precondition(plan.startPreparationGoal(selected, now: now))
        precondition(plan.topic == selected.action && plan.nextContact == nil && !plan.canStartPreparationGoal)
        precondition(!plan.startPreparationGoal(selected, now: now))
        plan.schedule(at: now.addingTimeInterval(900), now: now, weekly: true)
        let scheduled = plan
        plan.setPressureRecord(.noRecord) // Answer changes never replace an agreed goal or date.
        precondition(!plan.startPreparationGoal(plan.preparation.step, now: now))
        precondition(plan.topic == scheduled.topic && plan.nextContact == scheduled.nextContact && plan.weeklyContact == scheduled.weeklyContact)
        plan.pause()
        precondition(!plan.canStartPreparationGoal && !plan.startPreparationGoal(selected, now: now))
        plan.finish()
        plan.setPressureRecord(.previousMeasurement)
        plan.setPressureContext(nil)
        precondition(plan.canStartPreparationGoal && plan.startPreparationGoal(plan.preparation.step, now: now))

        var fromChat = CarePlan()
        fromChat.receive("Что проверить?", now: now)
        precondition(fromChat.topic == nil && fromChat.isDiscussingPrevention && fromChat.canStartPreparationGoal)
        fromChat.setPressureRecord(.noRecord)
        precondition(fromChat.startPreparationGoal(fromChat.preparation.step, now: now))

        var emergency = CarePlan()
        emergency.receive("Вызови скорую", now: now)
        precondition(!emergency.canStartPreparationGoal && !emergency.startPreparationGoal(emergency.preparation.step, now: now))
        var pending = scheduled
        pending.checkDue(now: now.addingTimeInterval(901))
        pending.receive("Что проверить?", now: now.addingTimeInterval(902))
        precondition(pending.lastAnswer == nil && pending.topic == scheduled.topic)
        precondition(pending.hasDueQuestion && !pending.startPreparationGoal(pending.preparation.step, now: now))
    }
}
