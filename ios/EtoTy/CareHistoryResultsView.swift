import SwiftUI

private typealias HistoryState<Value> = State<Value>

struct CareHistoryResultsView: View {
    let query: CareHistoryQuery
    let documents: [CareDocument]
    let onOpen: (CareDocument) -> Void
    @HistoryState private var expanded = false

    var body: some View {
        let matches = query.matches(in: documents)
        VStack(alignment: .leading, spacing: 12) {
            Label("Из твоего архива", systemImage: "doc.text.magnifyingglass").font(.headline)
            if matches.isEmpty {
                Text(documents.isEmpty ? "Сохранённых документов пока нет." :
                        "Совпадений в названиях, метках, датах исследования и подтверждённых фрагментах пока нет.")
                    .font(.callout)
            } else {
                if matches.count > 1 {
                    Text("По дате добавления, сначала новые").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(matches.prefix(expanded ? matches.count : 3)) { document in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(document.name).font(.subheadline.bold())
                        Text(document.evidence?.studyDate.map { "Дата исследования · " + $0 } ?? "Дата исследования не указана")
                        Text("Добавлено · " + document.imported.formatted(.dateTime.locale(Locale(identifier: "ru_RU")).day().month(.wide).year()))
                            .foregroundStyle(.secondary)
                        if let quote = document.evidence?.quote, !quote.isEmpty {
                            Text("Подтверждённый фрагмент" + (document.evidence?.page.map { " · стр. " + String($0) } ?? ""))
                            Text("«" + quote + "»").lineLimit(4)
                        }
                        Button("Открыть оригинал") { onOpen(document) }
                            .accessibilityLabel("Открыть оригинал: " + document.name)
                            .accessibilityIdentifier("care.history.original")
                    }.font(.caption)
                }
                if matches.count > 3 {
                    Button(expanded ? "Свернуть" : "Показать все (\(matches.count))") { expanded.toggle() }
                        .font(.callout)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        .onChange(of: query) { _, _ in expanded = false }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("care.history.results")
    }
}
