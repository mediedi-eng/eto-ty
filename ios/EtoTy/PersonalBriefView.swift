import SwiftUI
import UniformTypeIdentifiers

private typealias BriefState<Value> = State<Value>

struct PersonalBriefView: View {
    let plan: CarePlan
    let documents: [CareDocument]
    @Environment(\.dismiss) private var dismiss
    @BriefState private var includeTopic = false
    @BriefState private var includeAnswer = false
    @BriefState private var includedIDs = Set<String>()
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
            .toolbar { Button("Закрыть") { dismiss() } }
        }
        .fileExporter(isPresented: $exporting, document: file, contentType: .pdf, defaultFilename: "Сводка-к-приёму") { result in
            if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError {
                errorMessage = "Не удалось сохранить PDF. Проверь выбранное место и попробуй снова."
            }
            file = nil
        }
    }

    private var selection: some View {
        List {
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
                if documents.isEmpty {
                    Text("В списке нет документов для выбора.").foregroundStyle(.secondary)
                }
                ForEach(documents) { document in
                    Toggle(isOn: Binding {
                        includedIDs.contains(document.id)
                    } set: { included in
                        if included { includedIDs.insert(document.id) }
                        else { includedIDs.remove(document.id) }
                    }) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(document.name)
                            if let region = document.region { Text(region.rawValue).font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                }
            } header: {
                Text("Документы")
            } footer: {
                Text("В PDF попадут сведения о выбранных документах и подтверждённые фрагменты. Перед сохранением можно прочитать весь текст.")
            }
            Button("Предпросмотр") {
                preview = PersonalBrief.text(plan: plan, documents: documents.filter { includedIDs.contains($0.id) },
                                            includeTopic: includeTopic, includeAnswer: includeAnswer)
                errorMessage = nil
            }.disabled(!includeTopic && !includeAnswer && includedIDs.isEmpty)
        }
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
