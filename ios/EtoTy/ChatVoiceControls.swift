#if os(iOS)
import SwiftUI

enum ChatVoiceAction: Hashable {
    case dictate, talk
}

enum SpeechPrivacyChoice: String {
    case ask, device, appleIfNeeded
    static let key = "personal.voice.recognition.v1"
}

struct ChatVoiceConsent: View {
    let action: ChatVoiceAction
    let online: Bool
    let choose: (SpeechPrivacyChoice) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if action == .dictate {
                        Text("Говори по-русски. Текст появится в поле сообщения. Его можно исправить и отправить стрелкой.")
                    } else {
                        Text("После паузы твоя фраза отправится в диалог. Ответ прозвучит вслух, затем микрофон включится снова. Кнопкой завершения можно остановить разговор в любой момент.")
                        if online {
                            Text("Текст каждой реплики и до трёх предыдущих пар реплик онлайн-диалога получит OpenAI.")
                        }
                    }
                }
                Section {
                    Button("Распознавать на iPhone") { choose(.device) }
                        .accessibilityIdentifier("care.voice.consent.local")
                    if online {
                        Button("Разрешить Apple, если нужно") { choose(.appleIfNeeded) }
                            .accessibilityIdentifier("care.voice.consent.apple")
                    }
                } footer: {
                    Text(online
                         ? "Первый вариант использует локальное распознавание русского языка. Во втором iPhone может передать звук в сервис распознавания Apple. Приложение сохраняет в переписке только отправленный текст."
                         : "В режиме «Только на iPhone» звук обрабатывается на устройстве.")
                }
            }
            .navigationTitle(action == .dictate ? "Диктовка" : "Голосовой разговор")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

struct ChatVoiceStatus: View {
    @ObservedObject var voice: VoiceConversation
    let settings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let issue = voice.issue {
                Text(issue).font(.subheadline)
                HStack {
                    Button("Настройки голоса", action: settings)
                    Spacer()
                    Button("Закрыть") { voice.clearIssue() }
                }.font(.footnote)
            } else if voice.mode != .idle {
                HStack {
                    Image(systemName: voice.phase == .speaking ? "speaker.wave.2.fill" : "waveform")
                        .accessibilityHidden(true)
                    Text(status).font(.subheadline.weight(.medium))
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(voice.phase.rawValue)
                .accessibilityIdentifier("care.voice.phase")
                if voice.mode == .conversation && voice.phase == .listening && !voice.transcript.isEmpty {
                    Text(voice.transcript).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    private var status: String {
        switch voice.phase {
        case .idle: return ""
        case .listening: return voice.mode == .dictation ? "Диктовка" : "Слушаю"
        case .waiting: return "Готовлю ответ"
        case .speaking: return "Отвечаю вслух"
        }
    }
}
#endif
