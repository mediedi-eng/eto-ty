import QuickLook
import SwiftUI

private typealias PreparationState<Value> = State<Value>

struct PersonalPreventionView: View {
    @ObservedObject var session: CareSession
    let onExampleChoose: ((String) -> Bool)?
    let onGoalCreated: () -> Void
    @Environment(\.dismiss) private var dismiss
    @PreparationState private var customQuestion: String?
    @PreparationState private var issue: String?

    private var preparation: CarePreventionPreparation { session.plan.preparation }
    private var question: String { customQuestion ?? preparation.step.visitQuestion }

    var body: some View {
        NavigationStack {
            List {
                Section("Давление · подготовка к приёму") {
                    Text(preparation.step.action).font(.headline)
                        .accessibilityIdentifier("care.preparation.step")
                    Text(preparation.step.reason)
                    if session.plan.canStartPreparationGoal {
                        Button("Добавить это дело в диалог") {
                            if session.startPreparationGoal(preparation.step) { onGoalCreated() }
                            else { issue = session.statusText }
                        }.accessibilityIdentifier("care.preparation.start")
                    }
                }
                questionSection
                Section("Уточнить для себя") {
                    NavigationLink {
                        PressureAnswerView(session: session, editRecord: true)
                    } label: {
                        answerLabel("Последнее измерение", answer: preparation.record?.label)
                    }.accessibilityIdentifier("care.preparation.record")
                    if (preparation.record != nil && preparation.showsContextQuestion) || preparation.context != nil {
                        NavigationLink {
                            PressureAnswerView(session: session, editRecord: false)
                        } label: {
                            answerLabel("Моя ситуация", answer: preparation.context?.label)
                        }.accessibilityIdentifier("care.preparation.context")
                    }
                    if session.archiveAvailable && !session.archivedDocuments.isEmpty {
                        NavigationLink("Свериться со своим документом") {
                            PreparationDocumentList(session: session)
                        }.accessibilityIdentifier("care.preparation.documents")
                    }
                }
                Section("Руководство по скринингу гипертонии") {
                    Text(CarePreventionPreparation.sourceScope).font(.callout)
                    Link(CarePreventionPreparation.sourceLabel, destination: CarePreventionPreparation.sourceURL)
                        .accessibilityIdentifier("care.preparation.source")
                }
                NavigationLink("Посмотреть вымышленные примеры") {
                    CarePreventionView(onChoose: onExampleChoose)
                }.accessibilityIdentifier("care.preparation.examples")
            }
            .navigationTitle("Что проверить?")
            .toolbar { Button("Закрыть") { dismiss() } }
        }
    }

    private var questionSection: some View {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = session.plan.visitQuestions.contains { $0.text == trimmed }
        return Section("Вопрос врачу") {
            TextField("Что спросить на приёме?", text: Binding(get: { question }, set: { changed in
                customQuestion = changed
                issue = nil
            }), axis: .vertical)
                .accessibilityLabel("Вопрос врачу, можно изменить")
                .accessibilityIdentifier("care.preparation.question")
            if customQuestion != nil && question != preparation.step.visitQuestion {
                Button("Вернуть предложенный вопрос") { customQuestion = nil; issue = nil }
            }
            if saved {
                Label("Вопрос сохранён в сводке к приёму", systemImage: "checkmark")
                    .accessibilityIdentifier("care.preparation.saved")
            } else {
                Button("Сохранить вопрос к приёму") {
                    issue = session.addVisitQuestion(trimmed) ? nil : session.statusText ?? "Не удалось сохранить вопрос."
                }.disabled(trimmed.isEmpty || session.storageUnavailable)
                    .accessibilityIdentifier("care.preparation.saveQuestion")
            }
            if let issue { Text(issue).foregroundStyle(.secondary) }
        }
    }

    private func answerLabel(_ title: String, answer: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(answer ?? "Уточнить, если хочешь").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct PressureAnswerView: View {
    @ObservedObject var session: CareSession
    let editRecord: Bool
    @Environment(\.dismiss) private var dismiss
    @PreparationState private var issue: String?

    var body: some View {
        let preparation = session.plan.preparation
        List {
            Section {
                if editRecord {
                    ForEach(CarePressureRecord.allCases) { record in
                        choice(record.label, selected: preparation.record == record) {
                            save(session.setPressureRecord(record))
                        }.accessibilityIdentifier("care.preparation.record." + record.rawValue)
                    }
                } else {
                    ForEach(CarePressureContext.allCases) { context in
                        choice(context.label, selected: preparation.context == context) {
                            save(session.setPressureContext(context))
                        }.accessibilityIdentifier("care.preparation.context." + context.rawValue)
                    }
                }
            } header: {
                Text(editRecord ? CarePressureRecord.question : CarePressureContext.question)
                    .font(.headline).textCase(nil)
            } footer: {
                Text("Ответ сохранится только на этом устройстве. Его можно изменить или удалить.")
            }
            if editRecord ? preparation.record != nil : preparation.context != nil {
                Button("Удалить мой ответ", role: .destructive) {
                    save(editRecord ? session.setPressureRecord(nil) : session.setPressureContext(nil))
                }.accessibilityIdentifier("care.preparation.clear")
            }
            Button("Вернуться без изменений") { dismiss() }
            if let issue { Text(issue).foregroundStyle(.secondary) }
        }.navigationTitle(editRecord ? "Последнее измерение" : "Моя ситуация")
    }

    private func choice(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).multilineTextAlignment(.leading)
                if selected { Spacer(); Image(systemName: "checkmark").accessibilityHidden(true) }
            }
        }.accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func save(_ succeeded: Bool) {
        if succeeded { dismiss() }
        else { issue = session.statusText ?? "Не удалось сохранить изменение. Попробуй ещё раз." }
    }
}

private struct PreparationDocumentList: View {
    @ObservedObject var session: CareSession
    @PreparationState private var original: URL?
    @PreparationState private var issue: String?

    var body: some View {
        List {
            ForEach(session.archivedDocuments) { document in
                Button(document.name) {
                    do {
                        original = try session.originalURL(for: document)
                        issue = nil
                    } catch {
                        issue = "Не удалось открыть оригинал. Проверь доступ к документу."
                        session.refreshDocuments()
                    }
                }.accessibilityLabel("Открыть оригинал файла " + document.name)
            }
            if session.archivedDocuments.isEmpty {
                Text(session.archiveAvailable ? "Сохранённых документов пока нет." : "Архив сейчас недоступен.")
            }
            if let issue { Text(issue).foregroundStyle(.secondary) }
        }
        .navigationTitle("Выбрать оригинал")
        .quickLookPreview($original)
    }
}
