import Foundation

/// Lyricist on IONOS AI Model Hub (gpt-oss-120b, ~3 s per pass). The ACE-Step 1.7B LM ignored
/// the request (asked "energetic rap, social critique", wrote a latin-trap love song) and
/// its prose caption steered the music to melodic pop; this writer follows genre, theme, hook
/// and voice, and writes a short genre-first style for the DiT. A second pass fixes wording
/// and repeated rhymes. Falls back to the ACE LM when there is no key or the call fails.
enum IonosWriter {
    static let model = "openai/gpt-oss-120b"
    static let endpoint = URL(string: "https://openai.inference.de-txl.ionos.com/v1/chat/completions")!

    struct Song: Decodable {
        var title: String?
        var style: String?
        var lyrics: String?
        var bpm: Int?
        var key: String?
    }

    static var isEnabled: Bool {
        IonosKey.load() != nil && (UserDefaults.standard.string(forKey: "lyricsEngine") ?? "ionos") == "ionos"
    }

    static func languageName(_ code: String) -> String {
        ["it": "Italian", "en": "English", "es": "Spanish", "fr": "French", "de": "German",
         "pt": "Portuguese", "ja": "Japanese", "zh": "Chinese"][code] ?? "English"
    }

    static func voiceRule(_ v: Voice, instrumental: Bool) -> String {
        if instrumental { return "instrumental track: no vocals, lyrics = \"[Instrumental]\"" }
        switch v {
        case .auto: return "pick the voice that best fits the genre and write it into the style"
        case .female: return "female vocals (in the style: female vocals, or female rap vocals if it's rap)"
        case .male: return "male vocals (in the style: male vocals, or male rap vocals if it's rap)"
        case .duet: return "male/female duet alternating verses and singing the chorus together (in the style: male and female duet)"
        }
    }

    static func systemPrompt(_ d: SongDraft) -> String {
        let lines = max(12, Int(d.duration / 3))
        let rapLines = max(16, Int(d.duration / 2.4))
        return """
        You are a professional songwriter writing for an AI music generator (ACE-Step).
        Hard rules:
        1. Follow the request TO THE LETTER: genre, energy, theme, message, voice. The requested GENRE is binding: if it asks for rap, it's rap (not melodic pop); if it asks for energetic, it's energetic. If the request contains a line for the chorus, the chorus MUST include it verbatim.
        2. Language of the verses: \(languageName(d.language)). Natural, spoken language, no invented words.
        3. No empty clichés (beating heart, stars, dreams, magic night) unless the theme needs them. Concrete, specific imagery.
        4. Meter and rhyme consistent with the genre. Rap/trap/drill: LONG, dense bars of 10-14 words each, every pair of bars rhymes (never the same word), internal rhymes, concrete punchlines; 8-bar verses. Pop: short, singable lines, a 4-line chorus that's easy to remember. Ballad/singer-songwriter: storytelling and imagery. Rock/punk: direct, powerful lines.
        5. COMPLETE structure with tags in English on their own line: [Intro], [Verse 1], [Pre-Chorus], [Chorus], [Verse 2], [Pre-Chorus], [Chorus], \(d.duration >= 75 ? "[Verse 3], " : "")[Bridge], [Chorus], [Outro]. Every verse has at least 8 lines. The [Chorus] repeats identically 3 times.
        6. Length: about \(lines) sung lines in total for \(Int(d.duration)) seconds; for rap about \(rapLines) bars (rap packs many more words per second).
        6b. The chorus has 4 DISTINCT, full lines (not the same phrase repeated): the requested key phrase opens or closes the lines.
        7. Voice: \(voiceRule(d.voice, instrumental: d.instrumental)).
        8. "style": tags IN ENGLISH for the music generator, comma-separated, in this order: GENRE and subgenre first, energy/mood, BPM, main instruments, voice type and delivery (for rap: rap vocals, fast flow, aggressive delivery). Max 25 words. 100% consistent with the request: no unrequested genres or moods.
        Do not write numbers, counts or bracketed notes at the end of a line: only the text to be sung.
        Reply ONLY with JSON: {"title": "...", "style": "...", "lyrics": "...", "bpm": 120, "key": "A minor"}
        """
    }

    static func request(_ d: SongDraft) -> String {
        var r = "Request: \(d.description.isEmpty ? "(free)" : d.description)"
        if !d.title.trimmingCharacters(in: .whitespaces).isEmpty { r += "\nRequested title: \(d.title)" }
        if !d.style.trimmingCharacters(in: .whitespaces).isEmpty { r += "\nRequested music style (binding): \(d.style)" }
        if !d.lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            r += "\nExisting lyrics to improve while keeping the ideas and the chorus:\n\(d.lyrics)"
        }
        return r
    }

    static let reviewPrompt = """
    You are a song lyric editor. You receive a JSON with a song. Fix ONLY:
    non-existent words or language errors, rhymes that repeat the same word, meaningless lines.
    Keep identical: theme, genre, structure and the square-bracket tags, the chorus (key phrase included), the style, the title, bpm and key.
    Reply ONLY with the same corrected JSON.
    """

    static func write(_ d: SongDraft) async throws -> Song {
        guard let key = IonosKey.load() else { throw EngineError.message("IONOS key missing") }
        let first = try await chat(key: key, system: systemPrompt(d), user: request(d), temperature: 0.8)
        var song = try decode(first)
        // Review pass: keep the first draft if it fails or loses the lyrics.
        if let reviewed = try? decode(await chat(key: key, system: reviewPrompt, user: first, temperature: 0.2)),
           let l = reviewed.lyrics, l.count > (song.lyrics?.count ?? 0) / 2 {
            song.lyrics = l
            if let t = reviewed.title, !t.isEmpty { song.title = t }
        }
        guard let lyrics = song.lyrics, !lyrics.isEmpty else { throw EngineError.message("Empty lyrics from IONOS") }
        song.lyrics = lyrics.replacingOccurrences(of: "\\n", with: "\n")
            // drop stray word counts like "(12)" the model sometimes appends to a bar
            .replacingOccurrences(of: "\\s*\\(\\d+\\)\\s*,?\\s*$", with: "", options: .regularExpression)
            .components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\\s*\\(\\d+\\)[,.]?\\s*$", with: "", options: .regularExpression) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let b = song.bpm, !(40...220).contains(b) { song.bpm = nil }
        return song
    }

    private static func chat(key: String, system: String, user: String, temperature: Double) async throws -> String {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "temperature": temperature,
            "max_tokens": 4000,
            "reasoning_effort": "low",
            "response_format": ["type": "json_object"],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = ((json["choices"] as? [[String: Any]])?.first?["message"]) as? [String: Any],
              let content = msg["content"] as? String, !content.isEmpty else {
            throw EngineError.message(code == 401 ? "Invalid IONOS key" : "IONOS \(code): \(String(decoding: data.prefix(160), as: UTF8.self))")
        }
        return content
    }

    private static func decode(_ text: String) throws -> Song {
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}") else {
            throw EngineError.message("IONOS response is not JSON")
        }
        return try JSONDecoder().decode(Song.self, from: Data(text[a...b].utf8))
    }
}

enum Genre {
    /// Rap-family styles get rap delivery in every verse tag and no sung harmonies.
    static func isRap(_ style: String) -> Bool {
        let s = style.lowercased()
        return ["rap", "hip hop", "hip-hop", "trap", "drill", "grime"].contains { s.contains($0) }
    }
}
