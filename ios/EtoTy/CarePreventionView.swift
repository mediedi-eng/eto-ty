import SwiftUI

private typealias PreventionViewState<Value> = State<Value>

struct CarePreventionView: View {
    let onChoose: ((String) -> Bool)?

    @PreventionViewState private var example = PreventionExample.first
    @PreventionViewState private var proposed: PreventionStep?
    @PreventionViewState private var issue: String?

    var body: some View {
        List {
            Section {
                Picker("История", selection: $example) {
                    ForEach(PreventionExample.allCases) { history in
                        Text(history.rawValue).tag(history)
                    }
                }
                Text(example.summary)
            } header: {
                Text("Вымышленный профиль")
            } footer: {
                Text("Сравни три истории одного возраста. Сведения примера остаются отдельно от твоей истории.")
            }

            ForEach(example.steps) { step in
                Section {
                    Text(step.reason)
                    Text(step.revisit).foregroundStyle(.secondary)
                    Link("Источник · " + step.source.label, destination: step.source.url)
                        .font(.footnote)
                    if onChoose != nil, step.goal != nil {
                        Button("Посмотреть шаг для моего плана") { proposed = step }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.title).font(.headline)
                        Text(step.status.rawValue).font(.subheadline)
                    }.textCase(nil)
                }
            }
            if let issue { Text(issue).foregroundStyle(.secondary) }
        }
        .navigationTitle("Вымышленные примеры")
        .alert(item: $proposed) { step in
            Alert(title: Text("Добавить дело в свой план?"),
                  message: Text(step.goal ?? ""),
                  primaryButton: .default(Text("Добавить")) {
                      guard let goal = step.goal, let onChoose else { return }
                      if !onChoose(goal) { issue = "Не удалось добавить дело. Проверь текущий план в диалоге." }
                  },
                  secondaryButton: .cancel(Text("Отмена")))
        }
    }
}
