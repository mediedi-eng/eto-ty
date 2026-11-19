import Foundation

enum CareChecks {
    static func run() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let firstDate = now.addingTimeInterval(300)
        let laterDate = firstDate.addingTimeInterval(600)
        var plan = CarePlan()
        let initial = plan
        precondition(plan.topic == nil && plan.messages.count == 1)
        plan.receive(" \n", now: now)
        plan.schedule(at: firstDate, now: now)
        plan.pause()
        plan.finish()
        precondition(plan == initial, "An empty personal profile has no agreement")

        var noRecords = initial
        noRecords.receive("У меня пока нет документов.", now: now)
        precondition(noRecords.topic == nil && noRecords.nextContact == nil)
        precondition(noRecords.messages.last?.text.contains("один вопрос") == true)
        noRecords.receive("Обсудить сон на приёме", now: now)
        precondition(noRecords.topic == "Обсудить сон на приёме")

        for request in ["Нужна срочная помощь!", "Как вызвать скорую?", "Please call an ambulance"] {
            var urgent = initial
            urgent.receive(request, now: now)
            precondition(urgent.isAskingForUrgentHelp && !urgent.isDiscussingPrevention)
            precondition(urgent.messages.last!.text.contains("местную экстренную службу"))
            precondition(urgent.topic == nil && urgent.nextContact == nil && urgent.lastAnswer == nil)
        }
        var other = initial
        other.receive("Мне не нужна срочная помощь", now: now)
        precondition(!other.isAskingForUrgentHelp)

        plan.receive("  Подготовить вопросы к следующей встрече  ", now: now)
        precondition(plan.topic == "Подготовить вопросы к следующей встрече")
        precondition(plan.nextContact == nil && plan.lastAnswer == nil)
        plan.schedule(at: firstDate, now: now)
        let scheduled = plan
        plan.schedule(at: firstDate, now: now)
        precondition(plan == scheduled, "Repeating a successful schedule must not add a message")
        plan.schedule(at: now, now: now)
        precondition(plan.nextContact == firstDate, "An invalid replacement must preserve the original time")
        plan.receive("Перенеси на пятницу вечером", now: now)
        precondition(plan.nextContact == firstDate, "Unconfirmed natural-language dates never replace the agreed time")

        plan.schedule(at: laterDate, now: now)
        plan.checkDue(now: firstDate)
        precondition(!plan.hasDueQuestion && plan.nextContact == laterDate)
        plan = try roundTrip(plan)
        plan.checkDue(now: laterDate)
        let waiting = plan
        precondition(waiting.hasDueQuestion && waiting.nextContact == nil)
        var urgentWhileDue = waiting
        urgentWhileDue.receive("Пожалуйста, вызови скорую", now: laterDate)
        precondition(urgentWhileDue.hasDueQuestion && urgentWhileDue.lastAnswer == nil)
        precondition(urgentWhileDue.topic == waiting.topic && urgentWhileDue.nextContact == nil)
        plan.checkDue(now: laterDate)
        plan = try roundTrip(plan)
        plan.checkDue(now: laterDate.addingTimeInterval(60))
        precondition(plan == waiting, "One contact produces at most one question, including after restart")

        plan.receive("Покажи мой план?", now: laterDate)
        precondition(plan.hasDueQuestion && plan.lastAnswer == nil)
        plan.receive("Вопросы готовы", now: laterDate)
        precondition(!plan.hasDueQuestion && plan.lastAnswer?.text == "Вопросы готовы")
        precondition(plan.lastAnswer?.fromUser == true && plan.lastAnswer?.createdAt == laterDate)
        precondition(plan.nextContact == nil, "A reply is not permission to schedule another contact")
        let answered = try roundTrip(plan)
        precondition(answered == plan)

        plan.schedule(at: laterDate.addingTimeInterval(300), now: laterDate)
        plan.pause()
        let paused = plan
        plan.pause()
        plan.checkDue(now: laterDate.addingTimeInterval(400))
        plan.schedule(at: laterDate.addingTimeInterval(600), now: laterDate)
        precondition(plan == paused && plan.nextContact == nil && !plan.hasDueQuestion)
        plan.resume()
        let resumed = plan
        plan.resume()
        precondition(plan == resumed && !plan.isPaused && plan.nextContact == nil)
        plan.finish()
        let finished = plan
        plan.finish()
        plan.resume()
        plan.schedule(at: laterDate.addingTimeInterval(600), now: laterDate)
        precondition(plan == finished && plan.isClosed && plan.lastAnswer != nil)
        plan.receive("Хочу начать с профилактики", now: laterDate)
        precondition(plan.topic == "Хочу начать с профилактики" && plan.lastAnswer == nil && !plan.isClosed)
        precondition(plan.isDiscussingPrevention)
        precondition(plan.messages.contains { $0.text == "Вопросы готовы" })
        precondition(Set(plan.messages.map(\.id)).count == plan.messages.count)

        var cancelled = scheduled
        cancelled.receive("Отмени напоминание", now: firstDate)
        cancelled.checkDue(now: laterDate)
        precondition(!cancelled.hasDueQuestion && cancelled.nextContact == nil && !cancelled.isClosed)
        var stopped = scheduled
        stopped.receive("Пока не пиши первым", now: laterDate)
        precondition(stopped.isPaused && stopped.nextContact == nil)
        precondition(!stopped.messages.contains { $0.text.contains("Как продвинулось?") })
        var arrivedWhileDue = scheduled
        arrivedWhileDue.receive("Хочу добавить заметку", now: firstDate)
        precondition(arrivedWhileDue.hasDueQuestion && arrivedWhileDue.lastAnswer == nil,
                     "A message cannot answer a question the user has not yet seen")

        var guideLink = scheduled
        guideLink.receive("Какие обследования сейчас имеют смысл?", now: now)
        precondition(guideLink.isDiscussingPrevention && guideLink.topic == scheduled.topic)
        guideLink.finish()
        precondition(!guideLink.isDiscussingPrevention)

        for route in CareIntentRoute.allCases {
            precondition(CareIntentInterpreter.interpretedLabel(route.rawValue) == .suggested(route))
        }
        if case .suggested = CareIntentInterpreter.interpretedLabel("unknown") {
            preconditionFailure("Ambiguous requests must permit manual navigation")
        }
        if case .suggested = CareIntentInterpreter.interpretedLabel("Some generated free text") {
            preconditionFailure("Arbitrary model content may not route to a screen")
        }

        let initialSteps = PreventionExample.first.steps
        precondition(Set(initialSteps.map(\.status)) == Set(PreventionStatus.allCases))
        let familiar = PreventionExample.family.steps.first { $0.id == "lipids" }!
        let firstLipids = initialSteps.first { $0.id == "lipids" }!
        let previous = PreventionExample.record.steps.first { $0.id == "lipids" }!
        precondition(firstLipids.status == .next && previous.status == .known)
        precondition(familiar.reason != firstLipids.reason && familiar.goal != firstLipids.goal)
        precondition(PreventionExample.family.steps.last?.status != .later)
        for example in PreventionExample.allCases {
            precondition(Set(example.steps.map(\.id)).count == example.steps.count)
            for step in example.steps {
                precondition(step.source.url.scheme == "https")
                precondition(!step.reason.isEmpty && !step.revisit.isEmpty)
                if step.status == .later { precondition(step.goal == nil) }
            }
        }
    }

    private static func roundTrip(_ plan: CarePlan) throws -> CarePlan {
        let data = try JSONEncoder().encode(plan)
        return try JSONDecoder().decode(CarePlan.self, from: data)
    }
}
