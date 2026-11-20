#if os(iOS)
import SwiftUI

enum ChatVoiceAction: Hashable {
    case dictate, talk
}

enum RecordedVoiceConsent {
    static let dictation = "personal.voice.openai.recorded.dictation.v1"
    static let conversation = "personal.voice.openai.recorded.conversation.v1"
}

struct ChatVoiceConsent: View {
    let action: ChatVoiceAction
    let online: Bool
    let choose: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if online {
                        Text("Для расшифровки приложение передаст запись микрофона через сервис «Это ты» в OpenAI.")
                    } else {
                        Text("Речь распознаётся на этом iPhone.")
                    }
                    if action == .dictate {
                        Text("Нажми стоп, когда закончишь. Расшифровка появится в поле сообщения. Её можно исправить и отправить стрелкой.")
                    } else {
                        Text("После паузы фраза автоматически отправится в диалог. Ответ прозвучит вслух, затем микрофон включится снова.")
                        if online {
                            Text("OpenAI получит расшифрованный текст и до трёх предыдущих пар реплик онлайн-диалога для ответа.")
                        }
                    }
                }
                Section {
                    if online {
                        Button(action == .dictate ? "Разрешить и записать" : "Разрешить и начать разговор", action: choose)
                            .accessibilityIdentifier(action == .dictate ? "care.voice.consent.cloud" : "care.voice.consent.cloudCall")
                    } else {
                        Button("Распознавать на iPhone", action: choose)
                            .accessibilityIdentifier("care.voice.consent.local")
                    }
                } footer: {
                    if online {
                        Text("Каждая запись длится до двух минут. Разрешение для этого режима можно сбросить в настройках приватности диалога.")
                    }
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
                    if voice.phase == .recording, let started = voice.recordingStartedAt {
                        Image(systemName: "record.circle.fill").foregroundStyle(.red)
                            .accessibilityHidden(true)
                        Text(status).font(.subheadline.weight(.semibold))
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            let elapsed = Int(started.duration(to: ContinuousClock().now).components.seconds)
                            Text(verbatim: String(format: "%02d:%02d", elapsed / 60, elapsed % 60))
                                .font(.subheadline.monospacedDigit())
                        }
                    } else {
                        Image(systemName: voice.phase == .speaking ? "speaker.wave.2.fill" : "waveform")
                            .accessibilityHidden(true)
                        Text(status).font(.subheadline.weight(.medium))
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(voice.phase.rawValue)
                .accessibilityIdentifier("care.voice.phase")
                if voice.mode == .dictation && [.preparing, .recording, .transcribing].contains(voice.phase) {
                    Button(voice.phase == .transcribing ? "Отменить расшифровку" : "Отменить запись") { voice.stop() }
                        .font(.footnote)
                        .accessibilityIdentifier("care.voice.cancel")
                }
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
        case .preparing: return "Готовлю микрофон…"
        case .recording: return "Запись"
        case .transcribing: return "Расшифровываю…"
        case .waiting: return "Готовлю ответ"
        case .speaking: return "Отвечаю вслух"
        }
    }
}
#endif
