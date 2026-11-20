import Foundation
import Security

enum CloudChatError: LocalizedError {
    case tooLong, limit, unavailable, connection

    var errorDescription: String? {
        switch self {
        case .tooLong: return "Сократи сообщение до 4000 символов и отправь снова."
        case .limit: return "Лимит сообщений сервиса исчерпан. Попробуй позже."
        case .unavailable: return "Сервис «Это ты» временно недоступен. Попробуй позже."
        case .connection: return "Не удалось связаться с сервисом «Это ты». Проверь подключение."
        }
    }
}

enum LegacyChatCredential {
    static func remove() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "eng.mediedi.etoty.personal-chat",
            kSecAttrAccount as String: "openrouter"
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private final class NoChatRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum CloudConversation {
    struct Turn: Codable, Equatable {
        let role: String
        let content: String
    }
    private struct Request: Encodable {
        let message: String
        let history: [Turn]
    }
    private struct Reply: Decodable { let reply: String }

    static let origin = "https://eto-ty-pilot-chat.sacredarbor.chatgpt.site"
    static let endpoint = URL(string: origin + "/v1/chat")!
    private static let client: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 35
        configuration.timeoutIntervalForResource = 50
        return URLSession(configuration: configuration, delegate: NoChatRedirects(), delegateQueue: nil)
    }()

    static func answer(to text: String, previous: [Turn],
                       transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async throws -> String {
        guard text.utf16.count <= 4000 else { throw CloudChatError.tooLong }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("EtoTy-iOS/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(Request(message: text, history: Array(previous.suffix(6))))
        let (data, response): (Data, URLResponse)
        if let transport { (data, response) = try await transport(request) }
        else { (data, response) = try await client.data(for: request) }
        guard let http = response as? HTTPURLResponse else { throw CloudChatError.connection }
        switch http.statusCode {
        case 200: break
        case 413: throw CloudChatError.tooLong
        case 429: throw CloudChatError.limit
        default: throw CloudChatError.unavailable
        }
        guard let decoded = try? JSONDecoder().decode(Reply.self, from: data) else { throw CloudChatError.unavailable }
        let content = decoded.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw CloudChatError.unavailable }
        return String(content.prefix(4000))
    }
}
