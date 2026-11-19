import SwiftUI

private typealias IntentViewState<Value> = State<Value>

struct CareIntentView: View {
    let onChoose: (CareIntentRoute) -> Void

    @IntentViewState private var phrase = ""
    @IntentViewState private var work: Task<Void, Never>?
    @IntentViewState private var selection: CareIntentRoute?
    @IntentViewState private var notice: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Например, где мои документы?", text: $phrase, axis: .vertical)
                        .lineLimit(1...4)
                        .onChange(of: phrase) { _, _ in clearResult() }
                    Button("Подобрать на устройстве") { interpret() }
                        .disabled(work != nil || phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if work != nil { ProgressView("Подбираем раздел…") }
                    if let notice { Text(notice).font(.callout) }
                } footer: {
                    Text("При нажатии системная модель Apple получает только эту фразу на совместимом устройстве. Можно сразу выбрать раздел ниже.")
                }

                if let selection {
                    Section("Выбранный раздел") {
                        Text(selection.title).font(.headline)
                        Button("Открыть раздел") { onChoose(selection) }
                    }
                }

                Section("Выбрать вручную") {
                    ForEach(CareIntentRoute.allCases) { route in
                        Button(route.title) {
                            clearResult()
                            selection = route
                        }
                    }
                }
            }
            .navigationTitle("Подобрать раздел")
            .toolbar { Button("Закрыть") { dismiss() } }
            .onDisappear { work?.cancel() }
        }
    }

    private func clearResult() {
        work?.cancel()
        work = nil
        selection = nil
        notice = nil
    }

    private func interpret() {
        clearResult()
        let input = phrase
        work = Task { @MainActor in
            let result = await CareIntentInterpreter.interpret(input)
            guard !Task.isCancelled else { return }
            work = nil
            switch result {
            case .suggested(let route):
                selection = route
                notice = "Модель предложила раздел. Открой его, если подходит."
            case .manual(let message):
                notice = message
            }
        }
    }
}
