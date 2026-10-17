import Foundation
import Security

/// IONOS AI Model Hub key, stored only in the macOS Keychain.
enum IonosKey {
    private static let service = "ACEStudio"
    private static let account = "ionos-key"

    static func load() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !k.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(k.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Reads the key from a text file (e.g. the one downloaded from the IONOS portal).
    static func importFile(_ url: URL) -> Bool {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return save(s)
    }
}

/// Album covers with FLUX.1-schnell on IONOS AI Model Hub (~3 s per image).
enum CoverArt {
    static let endpoint = URL(string: "https://openai.inference.de-txl.ionos.com/v1/images/generations")!
    static let model = "black-forest-labs/FLUX.1-schnell"

    static func prompt(for t: Track) -> String {
        // The LM caption is long prose: its first two sentences carry genre and mood.
        let sentences = t.style.split(separator: ".").prefix(2).joined(separator: ".")
        let style = String(sentences.prefix(320))
        let chorus = LyricsFit.chorusLines(t.lyrics, max: 2)
        var p = "Professional square album cover artwork for a song titled \"\(t.title)\". Music: \(style)."
        if let d = t.song?.description, !d.isEmpty { p += " Theme: \(d)." }
        if !chorus.isEmpty { p += " Lyrics mood: \(chorus)." }
        p += " Striking artistic composition, cinematic lighting, rich colors, high detail, modern music artwork."
        p += " No text, no letters, no words, no watermark, no logo."
        return p
    }

    static func generate(for t: Track) async throws -> URL {
        guard let key = IonosKey.load() else { throw EngineError.message("IONOS key missing (Settings)") }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "prompt": prompt(for: t), "size": "1024x1024"])
        req.timeoutInterval = 120
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["data"] as? [[String: Any]])?.first else {
            let msg = String(decoding: data.prefix(200), as: UTF8.self)
            throw EngineError.message(code == 401 ? "IONOS key invalid or expired" : "IONOS \(code): \(msg)")
        }
        var image: Data?
        if let b64 = first["b64_json"] as? String { image = Data(base64Encoded: b64) }
        else if let u = first["url"] as? String, let url = URL(string: u) { image = try await URLSession.shared.data(from: url).0 }
        guard let image else { throw EngineError.message("IONOS did not return an image") }
        let dest = Paths.library.appendingPathComponent("cover-\(t.id.uuidString).png")
        try image.write(to: dest, options: .atomic)
        return dest
    }
}
