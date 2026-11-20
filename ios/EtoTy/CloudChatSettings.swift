import SwiftUI

struct CloudChatSettings: View {
    @ObservedObject var session: CareSession
    @Environment(\.dismiss) private var dismiss
    @SwiftUI.State private var key = ""
    @SwiftUI.State private var issue: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Бесплатный ИИ для теста") {
                    Text("Новые реплики из диалога получат OpenRouter и выбранный им поставщик модели. Для теста используй вымышленные примеры.")
                    Text("С каждым запросом отправляются до трёх последних пар реплик этой облачной беседы. При отключении или перезапуске её контекст очищается. Архив, сводка и прежняя переписка остаются на iPhone.")
                    Text("У бесплатных моделей есть лимит. Если API недоступен, в диалоге останется встроенный ответ.")
                }
                Section("Личный ключ OpenRouter") {
                    Link("Создать ключ OpenRouter", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                    SecureField("Вставь ключ", text: $key)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Text("Ключ хранится в связке ключей этого устройства.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(session.cloudEnabled ? "Заменить ключ" : "Подключить и отправлять новые реплики") {
                        do {
                            try session.connectCloud(key: key)
                            key = ""
                            dismiss()
                        } catch { issue = error.localizedDescription }
                    }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if session.cloudEnabled || issue != nil {
                        Button("Отключить и удалить ключ", role: .destructive) {
                            do {
                                try session.disconnectCloud()
                                dismiss()
                            } catch { issue = error.localizedDescription }
                        }
                    }
                    if let issue { Text(issue).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Облачный диалог")
            .toolbar { Button("Закрыть") { dismiss() } }
        }
    }
}
