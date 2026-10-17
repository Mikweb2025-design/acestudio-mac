import Foundation

/// Lyricist on IONOS AI Model Hub (Qwen3.5-397B, gpt-oss-120b as fast fallback). The ACE-Step 1.7B LM ignored
/// the request (asked "energetic rap, social critique", wrote a latin-trap love song) and
/// its prose caption steered the music to melodic pop; this writer follows genre, theme, hook
/// and voice, and writes a short genre-first style for the DiT. A second pass fixes wording
/// and repeated rhymes. Falls back to the ACE LM when there is no key or the call fails.
enum IonosWriter {
    /// Main writer: Qwen3.5-397B writes far more natural Italian/Spanish lyrics with real rhymes.
    /// It always reasons before answering (~30-90 s), so it gets a large token budget.
    static let model = "Qwen/Qwen3.5-397B-A17B"
    /// Fallback writer (fast, ~5 s) when Qwen fails or times out.
    static let fallbackModel = "openai/gpt-oss-120b"
    static let endpoint = URL(string: "https://openai.inference.de-txl.ionos.com/v1/chat/completions")!

    struct Song: Decodable {
        var title: String?
        var style: String?
        var lyrics: String?
        var bpm: Int?
        var key: String?
        var language: String?
    }

    /// IONOS writes when it is the chosen writer, and as the fallback when an added model fails.
    static var isEnabled: Bool {
        IonosKey.load() != nil && (UserDefaults.standard.string(forKey: "lyricsEngine") ?? "ionos") != "ace"
    }

    static func languageName(_ code: String) -> String {
        if code == "auto" { return "the language the request text is written in (detect it from the request)" }
        return languageNames(code)
    }

    private static func languageNames(_ code: String) -> String {
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

    /// Sections that fit the duration: short songs don't get three verses.
    static func structure(for duration: Double) -> String {
        if duration < 75 { return "[Intro], [Verse 1], [Pre-Chorus], [Chorus], [Verse 2], [Chorus], [Outro]" }
        if duration < 135 {
            return "[Intro], [Verse 1], [Pre-Chorus], [Chorus], [Verse 2], [Pre-Chorus], [Chorus], [Bridge], [Chorus], [Outro]"
        }
        return "[Intro], [Verse 1], [Pre-Chorus], [Chorus], [Verse 2], [Pre-Chorus], [Chorus], [Verse 3], [Bridge], [Chorus], [Outro]"
    }

    static func systemPrompt(_ d: SongDraft) -> String {
        let lines = max(12, Int(d.duration / 4.5))
        let bars = max(16, Int(d.duration / 2.6))
        return """
        You are a hit songwriter. You write lyrics that a singer can sing naturally; here the singer is the AI music generator ACE-Step, so short, regular lines matter even more than for a human.
        1. Follow the request TO THE LETTER: genre, energy, theme, message, voice. The requested GENRE is binding (asked for rap: it is rap, not melodic pop). If the request quotes a phrase for the chorus, the chorus contains it verbatim.
        2. Language of the lyrics: \(languageName(d.language)). Natural, idiomatic, correct grammar, no invented words. Put the ISO 639-1 code of the lyrics language in "language".
        3. Line length by genre (the melody repeats, so every line in a section stays within 2 syllables of the others):
           rap / trap / drill: 12-16 syllables per bar, verses of 8 bars, AABB couplets plus internal rhymes and punchlines.
           pop / dance / latin: 7-10 syllables, verses of 4-6 lines, ABAB or AABB, a 4-line chorus with the hook in lines 1 and 4.
           ballad / folk / singer-songwriter: 8-11 syllables, verses of 4-6 lines, ABAB, storytelling.
           rock / punk: 6-10 syllables, verses of 4 lines, AABB, a chorus you can shout.
        4. Rhymes are real rhymes in the lyrics' language (same sound from the last stressed vowel: "strada / cada", "night / light", "corazón / canción"). Never end two lines with the same word (only the chorus hook may repeat). If two lines won't rhyme naturally, rewrite both: never use a meaningless word just to rhyme.
        5. Every line makes literal sense read aloud: one clear image or idea per line, everyday words, concrete details from the request's world, no stacked abstract metaphors. Avoid clichés (beating heart, stars in the sky, dreams, magic night, fire inside, souls) unless asked.
        6. Structure for \(Int(d.duration)) seconds, about \(lines) sung lines in total (rap: about \(bars) bars): \(structure(for: d.duration)). Tags in English on their own line; an energy descriptor helps: [Chorus - anthemic], [Bridge - stripped back]. [Intro] and [Outro] hold at most two short lines. The chorus repeats identically.
        7. Voice: \(voiceRule(d.voice, instrumental: d.instrumental)).
        8. "style": ONE dense sentence in English for the music generator, at most 40 words, like a producer briefing a session band: genre and subgenre first, then tempo in BPM, main instruments and groove, mood, lead vocal (gender, timbre, delivery), production. Only what the request asks for.
        Write only the words to be sung: no line numbers, syllable counts, rhyme letters like (A) or notes. Backing vocals may go in (parentheses).
        Reply ONLY with JSON: {"title": "...", "language": "it", "style": "...", "lyrics": "...", "bpm": 120, "key": "A minor"}
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
    non-existent words or grammar errors, lines that end with the same word as a nearby line, lines that make no sense,
    lines much longer than the others in their section, rhyme letters or numbers in parentheses like (A) or (1).
    Keep identical: theme, genre, structure and the square-bracket tags, the chorus (key phrase included), the style, the title, bpm and key.
    Reply ONLY with the same corrected JSON.
    """

    static func write(_ d: SongDraft) async throws -> Song {
        guard let key = IonosKey.load() else { throw EngineError.message("IONOS key missing") }
        var song: Song
        if let s = try? decode(await chat(key: key, model: model, system: systemPrompt(d), user: request(d), temperature: 0.7)),
           !(s.lyrics ?? "").isEmpty {
            song = s
        } else {
            // Fallback: gpt-oss-120b, plus a review pass that fixes wording and repeated rhymes.
            let first = try await chat(key: key, model: fallbackModel, system: systemPrompt(d), user: request(d), temperature: 0.8)
            song = try decode(first)
            if let reviewed = try? decode(await chat(key: key, model: fallbackModel, system: reviewPrompt, user: first, temperature: 0.2)),
               let l = reviewed.lyrics, l.count > (song.lyrics?.count ?? 0) / 2 {
                song.lyrics = l
                if let t = reviewed.title, !t.isEmpty { song.title = t }
            }
        }
        return try finish(song)
    }

    /// Same prompt, on a model the user added (Anthropic, Grok, OpenRouter, ...).
    static func write(_ d: SongDraft, provider p: LLMProvider) async throws -> Song {
        let key = SecretStore.load(p.keyAccount)
        if p.kind.needsKey && key == nil { throw EngineError.message("\(p.kind.label): API key missing") }
        let text = try await LLMClient.complete(p, key: key, system: systemPrompt(d), user: request(d))
        return try finish(try decode(text))
    }

    private static func finish(_ input: Song) throws -> Song {
        var song = input
        guard let lyrics = song.lyrics, !lyrics.isEmpty else { throw EngineError.message("The writer returned no lyrics") }
        song.lyrics = clean(lyrics)
        if let b = song.bpm, !(40...220).contains(b) { song.bpm = nil }
        if let l = song.language?.lowercased().prefix(2) { song.language = String(l) }
        return song
    }

    /// Drops what must not be sung: escaped newlines, word counts "(12)", rhyme letters "(A)".
    static func clean(_ lyrics: String) -> String {
        lyrics.replacingOccurrences(of: "\\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\\s*\\((?:\\d+|[A-Z])\\)[,.]?\\s*$", with: "", options: .regularExpression) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func chat(key: String, model: String, system: String, user: String, temperature: Double) async throws -> String {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let isQwen = model.hasPrefix("Qwen/")
        req.timeoutInterval = isQwen ? 240 : 120
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "temperature": temperature,
            // Qwen reasons before every answer: the budget must cover thinking plus the song.
            "max_tokens": isQwen ? 16000 : 4000,
        ]
        if !isQwen {
            body["reasoning_effort"] = "low"
            body["response_format"] = ["type": "json_object"]
        }
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
            throw EngineError.message("The writer's response is not JSON")
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
