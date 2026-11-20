import SwiftUI

struct CloudChatSettings: View {
    @ObservedObject var session: CareSession
    @Environment(\.dismiss) private var dismiss

    #if os(iOS)
    @AppStorage(RecordedVoiceConsent.dictation) private var recordedDictationAllowed = false
    @AppStorage(RecordedVoiceConsent.conversation) private var recordedConversationAllowed = false
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
                    Section("Голос") {
                        if recordedDictationAllowed {
                            Button("Сбросить разрешение для диктовки") { recordedDictationAllowed = false }
                        }
                        if recordedConversationAllowed {
                            Button("Сбросить разрешение для голосового разговора") { recordedConversationAllowed = false }
                        }
                        Text("С твоего разрешения записи отправляются в OpenAI для расшифровки. В диктовке результат попадает в черновик, в голосовом разговоре отправляется сразу.")
                            .font(.footnote).foregroundStyle(.secondary)
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
