import Foundation
import Security

/// Extra LLMs the user can add as lyrics writer: Anthropic (native Messages API) and any
/// OpenAI-compatible service (xAI Grok, OpenRouter incl. its free models, Groq, Google Gemini,
/// Mistral, DeepSeek, OpenAI, or a custom/local endpoint such as LM Studio).
enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case anthropic, xai, openrouter, groq, gemini, mistral, deepseek, openai, custom
    var id: String { rawValue }

    var label: String {
        switch self {
        case .anthropic: "Anthropic Claude"
        case .xai: "xAI Grok"
        case .openrouter: "OpenRouter (many free models)"
        case .groq: "Groq"
        case .gemini: "Google Gemini"
        case .mistral: "Mistral"
        case .deepseek: "DeepSeek"
        case .openai: "OpenAI"
        case .custom: "Custom (OpenAI-compatible)"
        }
    }

    var baseURL: String {
        switch self {
        case .anthropic: "https://api.anthropic.com/v1"
        case .xai: "https://api.x.ai/v1"
        case .openrouter: "https://openrouter.ai/api/v1"
        case .groq: "https://api.groq.com/openai/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .mistral: "https://api.mistral.ai/v1"
        case .deepseek: "https://api.deepseek.com/v1"
        case .openai: "https://api.openai.com/v1"
        case .custom: "http://localhost:1234/v1"
        }
    }

    /// Where to create an API key.
    var keyURL: URL? {
        switch self {
        case .anthropic: URL(string: "https://console.anthropic.com/")
        case .xai: URL(string: "https://console.x.ai/")
        case .openrouter: URL(string: "https://openrouter.ai/keys")
        case .groq: URL(string: "https://console.groq.com/keys")
        case .gemini: URL(string: "https://aistudio.google.com/apikey")
        case .mistral: URL(string: "https://console.mistral.ai/api-keys")
        case .deepseek: URL(string: "https://platform.deepseek.com/api_keys")
        case .openai: URL(string: "https://platform.openai.com/api-keys")
        case .custom: nil
        }
    }

    /// Anthropic models offered as presets; the others are loaded from the service's /models.
    var presetModels: [String] {
        self == .anthropic ? ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"] : []
    }

    var note: String {
        switch self {
        case .anthropic: "Opus 5.5 writes the best lyrics; Sonnet 5.5 and Haiku 5.5 are faster and cheaper."
        case .openrouter: "Models whose name ends in \":free\" cost nothing (with rate limits)."
        case .groq: "Free tier with rate limits; very fast."
        case .gemini: "Free tier with a Google AI Studio key."
        case .custom: "Any OpenAI-compatible server, e.g. LM Studio or a self-hosted endpoint."
        default: "Load the models to pick one."
        }
    }

    var needsKey: Bool { self != .custom }
}

struct LLMProvider: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var kind: ProviderKind
    var baseURL: String
    var model: String

    var label: String { "\(kind == .custom ? baseURL : kind.label.components(separatedBy: " (").first!) · \(model)" }
    var keyAccount: String { "provider-\(id.uuidString)" }
}

enum ProviderStore {
    private static let defaultsKey = "llmProviders"

    static func load() -> [LLMProvider] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([LLMProvider].self, from: data)) ?? []
    }

    static func save(_ list: [LLMProvider]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: defaultsKey)
    }
}

/// API keys of the extra providers, in the Keychain next to the IONOS key.
enum SecretStore {
    private static let service = "ACEStudio"

    static func load(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    static func save(_ account: String, _ value: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(v.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// One text completion against a provider: the Anthropic Messages API, or OpenAI-style chat/completions.
enum LLMClient {
    static func complete(_ p: LLMProvider, key: String?, system: String, user: String) async throws -> String {
        p.kind == .anthropic
            ? try await anthropic(p, key: key ?? "", system: system, user: user)
            : try await openAICompatible(p, key: key, system: system, user: user)
    }

    /// Model ids the service offers (free OpenRouter models first).
    static func listModels(_ p: LLMProvider, key: String?) async throws -> [String] {
        var req = URLRequest(url: try url(p.baseURL, "models"))
        req.timeoutInterval = 30
        authorize(&req, p, key: key)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let ids = ((json?["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        let free = ids.filter { $0.hasSuffix(":free") }.sorted()
        return free + ids.filter { !$0.hasSuffix(":free") }.sorted()
    }

    private static func anthropic(_ p: LLMProvider, key: String, system: String, user: String) async throws -> String {
        var req = URLRequest(url: try url(p.baseURL, "messages"))
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        authorize(&req, p, key: key)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": p.model,
            "max_tokens": 16000,
            "system": system,
            "messages": [["role": "user", "content": user]],
            "output_config": ["effort": "medium"],
        ]
        // Server-side fallback on the current Opus/Sonnet: a declined request is retried on another model.
        if p.model == "claude-opus-5-5" || p.model == "claude-sonnet-5-5" {
            body["fallbacks"] = "default"
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EngineError.message("Anthropic: unreadable response")
        }
        if (json["stop_reason"] as? String) == "refusal" { throw EngineError.message("Anthropic declined the request") }
        let text = ((json["content"] as? [[String: Any]]) ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw EngineError.message("Anthropic returned no text") }
        return text
    }

    private static func openAICompatible(_ p: LLMProvider, key: String?, system: String, user: String) async throws -> String {
        var req = URLRequest(url: try url(p.baseURL, "chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        authorize(&req, p, key: key)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": p.model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "temperature": 0.7,
            "max_tokens": 12000,   // reasoning models think before the JSON
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = ((json["choices"] as? [[String: Any]])?.first?["message"]) as? [String: Any],
              let content = msg["content"] as? String, !content.isEmpty else {
            throw EngineError.message("\(p.kind.label): no text in the response")
        }
        return content
    }

    private static func authorize(_ req: inout URLRequest, _ p: LLMProvider, key: String?) {
        if p.kind == .anthropic {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if let key, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if p.kind == .openrouter { req.setValue("ACE Studio", forHTTPHeaderField: "X-Title") }
    }

    private static func url(_ base: String, _ path: String) throws -> URL {
        let b = base.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let u = URL(string: "\(b)/\(path)"), u.scheme?.hasPrefix("http") == true else {
            throw EngineError.message("Invalid base URL: \(base)")
        }
        return u
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let detail = String(decoding: data.prefix(200), as: UTF8.self)
            throw EngineError.message(code == 401 || code == 403 ? "Invalid API key (\(code))" : "HTTP \(code): \(detail)")
        }
    }
}
