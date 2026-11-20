import SwiftUI

struct CloudChatSettings: View {
    @ObservedObject var session: CareSession
    @Environment(\.dismiss) private var dismiss

    #if os(iOS)
    @AppStorage(SpeechPrivacyChoice.key) private var speechPrivacy = SpeechPrivacyChoice.ask
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section("Где отвечать") {
                    modeButton("Сервис «Это ты»", online: true)
                    modeButton("Только на iPhone", online: false)
                }
                #if os(iOS)
                if session.cloudEnabled {
                    Section {
                        Picker("Распознавание речи", selection: $speechPrivacy) {
                            Text("Спросить при включении").tag(SpeechPrivacyChoice.ask)
                            Text("На iPhone").tag(SpeechPrivacyChoice.device)
                            Text("Разрешить сервис Apple").tag(SpeechPrivacyChoice.appleIfNeeded)
                        }
                    } footer: {
                        Text("С разрешением сервиса Apple звук может обрабатываться на серверах Apple, если локальное распознавание недоступно.")
                    }
                }
                #endif
                Section {
                    Text("В режиме сервиса «Это ты» передаёт в OpenAI твоё новое сообщение и до трёх предыдущих пар реплик этого онлайн-диалога. После перезапуска или смены режима контекст очищается.")
                    Text("В режиме «Только на iPhone» ответы готовятся на устройстве. Архив документов, сводка и напоминания в обоих режимах хранятся на iPhone.")
                }
            }
            .navigationTitle("Приватность диалога")
            .toolbar { Button("Закрыть") { dismiss() } }
        }
    }

    private func modeButton(_ title: String, online: Bool) -> some View {
        Button {
            session.setCloudEnabled(online)
            dismiss()
        } label: {
            HStack {
                Text(title)
                Spacer()
                if session.cloudEnabled == online { Image(systemName: "checkmark") }
            }
        }
        .accessibilityAddTraits(session.cloudEnabled == online ? .isSelected : [])
    }
}
