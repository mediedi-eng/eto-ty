import Foundation
import Security

enum CloudChatError: LocalizedError {
    case key, keychain, limit, unavailable, connection

    var errorDescription: String? {
        switch self {
        case .key: return "OpenRouter отклонил ключ. Проверь его в настройках диалога."
        case .keychain: return "Не удалось открыть ключ. Разблокируй телефон и попробуй снова."
        case .limit: return "Лимит бесплатного API исчерпан. Попробуй позже."
        case .unavailable: return "Бесплатная модель сейчас недоступна с выбранными настройками приватности."
        case .connection: return "Нет ответа от OpenRouter. Проверь подключение и попробуй позже."
        }
    }
}

enum CloudChatKey {
    private static var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "eng.mediedi.etoty.personal-chat",
         kSecAttrAccount as String: "openrouter"]
    }

    static func store(_ key: String) throws {
        var entry = item
        let value = [kSecValueData as String: Data(key.utf8),
                     kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as [String: Any]
        entry.merge(value) { _, new in new }
        var status = SecItemAdd(entry as CFDictionary, nil)
        if status == errSecDuplicateItem { status = SecItemUpdate(item as CFDictionary, value as CFDictionary) }
        guard status == errSecSuccess else { throw CloudChatError.keychain }
    }

    static func read() throws -> String {
        var query = item
        query[kSecReturnData as String] = true
        var output: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &output) == errSecSuccess,
              let data = output as? Data, let key = String(data: data, encoding: .utf8) else { throw CloudChatError.keychain }
        return key
    }

    static func remove() throws {
        let status = SecItemDelete(item as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudChatError.keychain }
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
    private struct Reply: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    private static let client: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 35
        configuration.timeoutIntervalForResource = 50
        return URLSession(configuration: configuration, delegate: NoChatRedirects(), delegateQueue: nil)
    }()

    static func answer(to text: String, previous: [Turn], key: String,
                       transport: ((URLRequest) async throws -> (Data, URLResponse))? = nil) async throws -> String {
        let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let instruction = """
            Ты собеседник в русскоязычном приложении «Это ты». Ответь на последнюю реплику живо и конкретно,
            учитывая предыдущие реплики этой беседы. При необходимости задай один вопрос. Ответ до трёх предложений.
            Помогай человеку сформулировать наблюдение или подготовиться к визиту. Ты видишь только эту беседу.
            Не ставь диагнозы, не оценивай состояние здоровья, не назначай анализы, препараты и лечение.
            Не утверждай, что видел документы, поставил напоминание, сохранил факт или связался с врачом.
            При непосредственной угрозе жизни предложи обратиться в местную экстренную службу.
            """
        let turns = [Turn(role: "system", content: instruction)] + Array(previous.suffix(6)) + [Turn(role: "user", content: text)]
        let body: [String: Any] = ["model": "openrouter/free", "messages": turns.map { ["role": $0.role, "content": $0.content] },
                                   "max_tokens": 500, "provider": ["data_collection": "deny", "max_price": ["prompt": 0, "completion": 0]]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response): (Data, URLResponse)
        if let transport { (data, response) = try await transport(request) }
        else { (data, response) = try await client.data(for: request) }
        guard let http = response as? HTTPURLResponse else { throw CloudChatError.connection }
        switch http.statusCode {
        case 200: break
        case 401: throw CloudChatError.key
        case 429: throw CloudChatError.limit
        case 402, 403, 404, 503: throw CloudChatError.unavailable
        default: throw CloudChatError.connection
        }
        guard let decoded = try? JSONDecoder().decode(Reply.self, from: data),
              let content = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else { throw CloudChatError.unavailable }
        return String(content.prefix(4000))
    }
}
