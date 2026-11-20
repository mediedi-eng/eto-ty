import Foundation

enum VoiceTranscriptionError: LocalizedError, Equatable {
    case empty, tooLarge, invalidClip, tooMuchText, limit, unavailable, timeout

    var errorDescription: String? {
        switch self {
        case .empty: return "Не удалось разобрать речь. Запиши фразу ещё раз."
        case .tooLarge: return "Запись слишком большая или длинная. Попробуй более короткую реплику."
        case .invalidClip: return "Не удалось прочитать аудиозапись. Запиши реплику ещё раз."
        case .tooMuchText: return "Реплика слишком длинная для одного сообщения. Раздели её на части."
        case .limit: return "Лимит распознавания сервиса исчерпан. Можно написать сообщение."
        case .unavailable: return "Не удалось расшифровать запись. Проверь интернет или попробуй позже."
        case .timeout: return "Время ожидания расшифровки истекло. Можно записать реплику ещё раз."
        }
    }
}

enum VoiceTranscription {
    static let maximumBytes = 2 * 1024 * 1024
    private static let endpoint = URL(string: CloudConversation.origin + "/v1/transcribe")!
    private static let client = CloudConversation.makeClient(requestTimeout: 60, resourceTimeout: 65)

    private struct Transcript: Decodable { let text: String }
    private struct Failure: Decodable { let error: String }

    /// Unlink before network I/O. Cancellation can remove this same unique path safely.
    static func consumeClip(_ url: URL) async throws -> Data {
        defer { try? FileManager.default.removeItem(at: url) }
        try Task.checkCancellation()
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            throw VoiceTranscriptionError.empty
        }
        guard size <= maximumBytes else { throw VoiceTranscriptionError.tooLarge }
        return try Data(contentsOf: url)
    }

    static func transcribe(_ audio: Data,
                           transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async throws -> String {
        guard !audio.isEmpty else { throw VoiceTranscriptionError.empty }
        guard audio.count <= maximumBytes else { throw VoiceTranscriptionError.tooLarge }
        try Task.checkCancellation()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(CloudConversation.origin, forHTTPHeaderField: "Origin")
        request.setValue("EtoTy-iOS/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = audio
        let data: Data
        let response: URLResponse
        do {
            if let transport { (data, response) = try await transport(request) }
            else { (data, response) = try await client.data(for: request) }
        } catch let error as URLError where error.code == .timedOut {
            throw VoiceTranscriptionError.timeout
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw VoiceTranscriptionError.unavailable }
        switch http.statusCode {
        case 200: break
        case 400, 415: throw VoiceTranscriptionError.invalidClip
        case 413: throw VoiceTranscriptionError.tooLarge
        case 422:
            if (try? JSONDecoder().decode(Failure.self, from: data))?.error == "transcript_too_long" {
                throw VoiceTranscriptionError.tooMuchText
            }
            throw VoiceTranscriptionError.empty
        case 429: throw VoiceTranscriptionError.limit
        default: throw VoiceTranscriptionError.unavailable
        }
        guard let payload = try? JSONDecoder().decode(Transcript.self, from: data) else {
            throw VoiceTranscriptionError.unavailable
        }
        let result = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw VoiceTranscriptionError.empty }
        guard result.utf16.count <= 4000 else { throw VoiceTranscriptionError.tooMuchText }
        return result
    }
}
