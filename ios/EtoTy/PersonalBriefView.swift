import SwiftUI
import UniformTypeIdentifiers

private typealias BriefState<Value> = State<Value>

struct PersonalBriefView: View {
    @ObservedObject var session: CareSession
    private var plan: CarePlan { session.plan }
    private var documents: [CareDocument] { session.archivedDocuments }
    @Environment(\.dismiss) private var dismiss
    @BriefState private var includeTopic = false
    @BriefState private var includeAnswer = false
    @BriefState private var includedIDs = Set<String>()
    @BriefState private var area: Region?
    @BriefState private var includedQuestions = Set<UUID>()
    @BriefState private var draft = ""
    @FocusState private var typingQuestion: Bool
    @BriefState private var confirmingDiscard = false
    @BriefState private var pendingDeletion: CareVisitQuestion?
    @BriefState private var questionError: String?
    @BriefState private var preview: String?
    @BriefState private var file: BriefFile?
    @BriefState private var exporting = false
    @BriefState private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let preview {
                    VStack(alignment: .leading, spacing: 12) {
                        ScrollView {
                            Text(preview).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                        Button("Сохранить этот текст как PDF") { export(preview) }
                            .buttonStyle(.borderedProminent)
                        Button("Изменить состав") {
                            self.preview = nil
                            file = nil
                            errorMessage = nil
                        }
                    }.padding()
                } else {
                    selection
                }
            }
            .navigationTitle(preview == nil ? "Сводка к приёму" : "Предпросмотр")
            .toolbar {
                Button("Закрыть") {
                    if hasDraft { confirmingDiscard = true } else { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(hasDraft)
        .confirmationDialog("Вопрос ещё не сохранён", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Выйти без сохранения", role: .destructive) { dismiss() }
            Button("Продолжить редактирование", role: .cancel) {}
        }
        .fileExporter(isPresented: $exporting, document: file, contentType: .pdf, defaultFilename: "Сводка-к-приёму") { result in
            if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError {
                errorMessage = "Не удалось сохранить PDF. Проверь выбранное место и попробуй снова."
            }
            file = nil
        }
        .alert("Удалить сохранённый вопрос?", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { question in
            Button("Удалить", role: .destructive) {
                if session.deleteVisitQuestion(id: question.id) {
                    includedQuestions.remove(question.id)
                    questionError = nil
                } else {
                    questionError = session.statusText ?? "Вопрос не удалён. Попробуй ещё раз."
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: { question in
            Text(question.text)
        }
        .onChange(of: selectedText) { _, text in
            if let preview, preview != text {
                self.preview = nil
                file = nil
            }
        }
    }

    private var selection: some View {
        List {
            questions
            if let topic = plan.topic {
                Section("Текущая тема") {
                    Toggle(isOn: $includeTopic) {
                        Text(topic)
                    }
                }
            }
            if let answer = plan.lastAnswer {
                Section("Последний ответ в диалоге") {
                    Toggle(isOn: $includeAnswer) {
                        Text(answer.text)
                    }
                }
            }
            Section {
                if !session.archiveAvailable {
                    Text("Документы сейчас недоступны.")
                        .foregroundStyle(.secondary)
                    Button("Попробовать открыть архив снова") { session.refreshDocuments() }
                } else if documents.isEmpty {
                    Text("В списке нет документов для выбора.").foregroundStyle(.secondary)
                } else {
                    Picker("Показать документы", selection: $area) {
                        Text("Все области").tag(nil as Region?)
                        ForEach(Region.allCases) { region in
                            Text(region.rawValue).tag(Optional(region))
                        }
                    }
                    if !chosen.isEmpty {
                        Text("Включены в сводку").font(.subheadline.bold())
                        ForEach(chosen) { document in documentToggle(document) }
                    }
                    let choices = BriefDocumentSelection.available(in: documents, area: area, selected: includedIDs)
                    if !choices.isEmpty {
                        Text("Можно добавить").font(.subheadline.bold())
                        ForEach(choices) { document in documentToggle(document) }
                    } else if let area {
                        Text("Больше документов для выбора в области «" + area.rawValue + "» нет.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Документы")
            } footer: {
                Text("В PDF попадут сведения о выбранных документах и подтверждённые фрагменты. Перед сохранением можно прочитать весь текст.")
            }
            Button("Предпросмотр") {
                preview = selectedText
                errorMessage = nil
            }.disabled(!hasSelection)
        }
    }

    private var chosen: [CareDocument] {
        BriefDocumentSelection.chosen(in: documents, selected: includedIDs)
    }

    private func documentToggle(_ document: CareDocument) -> some View {
        Toggle(isOn: Binding {
            includedIDs.contains(document.id)
        } set: { included in
            if included { includedIDs.insert(document.id) }
            else { includedIDs.remove(document.id) }
        }) {
            VStack(alignment: .leading, spacing: 4) {
                Text(document.name)
                if session.activeDocumentSource?.id == document.id {
                    Label("Источник текущего дела", systemImage: "link")
                        .font(.footnote)
                }
                if let region = document.region { Text(region.rawValue).font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }

    private var questions: some View {
        Section {
            TextField("Что хочешь спросить у врача?", text: $draft, axis: .vertical)
                .focused($typingQuestion)
                .accessibilityIdentifier("brief.question.draft")
            Button("Сохранить вопрос") {
                if session.addVisitQuestion(draft) {
                    draft = ""
                    typingQuestion = false
                    questionError = nil
                } else {
                    questionError = session.statusText ?? "Вопрос не сохранён. Попробуй ещё раз."
                }
            }
            .disabled(!hasDraft)
            .accessibilityIdentifier("brief.question.save")
            if let questionError { Text(questionError).foregroundStyle(.red) }
            ForEach(plan.visitQuestions) { question in
                HStack(spacing: 16) {
                    Toggle(isOn: Binding {
                        includedQuestions.contains(question.id)
                    } set: { included in
                        if included { includedQuestions.insert(question.id) }
                        else { includedQuestions.remove(question.id) }
                    }) { Text(question.text) }
                    .accessibilityHint("Включить вопрос в сводку для врача.")
                    Button(role: .destructive) {
                        pendingDeletion = question
                    } label: {
                        Image(systemName: "trash")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Удалить вопрос «" + question.text + "»")
                }
            }
        } header: {
            Text("Мои вопросы врачу")
        } footer: {
            Text("Вопросы сохраняются на этом устройстве. Отметь те, которые хочешь включить в сводку.")
        }
    }

    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasSelection: Bool {
        (includeTopic && plan.topic != nil) || (includeAnswer && plan.lastAnswer != nil) ||
        !chosen.isEmpty ||
        plan.visitQuestions.contains { includedQuestions.contains($0.id) }
    }

    private var selectedText: String {
        PersonalBrief.text(plan: plan, documents: chosen,
                           includeTopic: includeTopic, includeAnswer: includeAnswer, includeQuestionIDs: includedQuestions)
    }

    private func export(_ exactText: String) {
        do {
            file = try BriefFile(VisitPDF.render(exactText))
            errorMessage = nil
            exporting = true
        } catch {
            errorMessage = "Не удалось сформировать PDF. Попробуй ещё раз."
        }
    }
}
