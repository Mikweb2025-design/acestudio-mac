import Foundation

/// AI lyricist = ACE-Step's built-in 5Hz LM (1.7B, MLX), run by `ace_writer.py`
/// in a one-shot process: loads (~16 s), writes (~20 s), exits and frees its RAM
/// before the music model runs. No external services.
enum Writer {
    struct Song: Decodable {
        var ok: Bool
        var error: String?
        var style: String?
        var lyrics: String?
        var bpm: Int?
        var duration: Int?
        var key: String?
    }

    static var script: URL {
        Bundle.main.url(forResource: "ace_writer", withExtension: "py")
            ?? Paths.home.appendingPathComponent("ACEStudio/Resources/ace_writer.py")
    }

    static func languageName(_ code: String) -> String {
        ["it": "Italian", "en": "English", "es": "Spanish", "fr": "French", "de": "German",
         "pt": "Portuguese", "ja": "Japanese", "zh": "Chinese"][code] ?? "Italian"
    }

    /// Turns the user's request into the query the LM understands best (it was trained on English captions).
    static func query(description: String, style: String, title: String, voice: Voice, language: String, instrumental: Bool) -> String {
        var parts: [String] = []
        if !style.isEmpty { parts.append(style) }
        if !description.isEmpty { parts.append(description) }
        if !title.isEmpty { parts.append("song title: \"\(title)\"") }
        if let v = voice.styleTag, !instrumental { parts.append(v) }
        parts.append(instrumental ? "instrumental, no vocals" : "lyrics in \(languageName(language))")
        return parts.joined(separator: ", ")
    }

    static func write(query: String, language: String, instrumental: Bool) async throws -> Song {
        let data = try await run(["query": query, "language": language, "instrumental": instrumental,
                                  "temperature": 0.7, "top_p": 0.9, "repetition_penalty": 1.05])
        let song = try JSONDecoder().decode(Song.self, from: data)
        if !song.ok { throw EngineError.message(song.error ?? "Lyric writing failed") }
        return song
    }

    /// "Thinking" plan: the LM writes 5Hz audio codes (melody, phrasing, structure) that the
    /// DiT follows. Same quality path as ACE-Step's thinking mode, but the LM runs and exits
    /// before the DiT, so RAM never holds both (~45 s for a 3-minute song).
    static func audioCodes(for d: SongDraft) async throws -> String {
        var input: [String: Any] = ["mode": "codes", "duration": d.duration, "style": d.effectiveStyle,
                                    "lyrics": d.instrumental ? "[Instrumental]" : d.lyrics,
                                    "language": d.instrumental ? "unknown" : d.language]
        if d.bpm > 0 { input["bpm"] = d.bpm }
        if !d.key.isEmpty { input["key"] = d.key }
        let data = try await run(input)
        struct Codes: Decodable { var ok: Bool; var error: String?; var codes: String? }
        let r = try JSONDecoder().decode(Codes.self, from: data)
        guard r.ok, let c = r.codes, !c.isEmpty else { throw EngineError.message(r.error ?? "AI planning failed") }
        return c
    }

    /// Runs ace_writer.py once with ACE-Step's own Python and returns its JSON result.
    private static func run(_ input: [String: Any]) async throws -> Data {
        let python = Paths.aceDir.appendingPathComponent(".venv/bin/python").path
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw EngineError.message("ACE-Step Python environment not found")
        }
        let data = try JSONSerialization.data(withJSONObject: input)
        let script = self.script.path
        return try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: python)
            p.arguments = [script]
            p.currentDirectoryURL = Paths.aceDir
            var env = ProcessInfo.processInfo.environment
            env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
            env["TOKENIZERS_PARALLELISM"] = "false"
            env["HF_HOME"] = Paths.home.appendingPathComponent(".cache/huggingface").path
            p.environment = env
            let stdin = Pipe(), stdout = Pipe()
            p.standardInput = stdin
            p.standardOutput = stdout
            p.standardError = FileHandle.nullDevice
            try p.run()
            stdin.fileHandleForWriting.write(data)
            try? stdin.fileHandleForWriting.close()
            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: out, as: UTF8.self)
            guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix("@@RESULT@@") }) else {
                throw EngineError.message("ACE's LLM did not respond")
            }
            return Data(line.dropFirst("@@RESULT@@".count).utf8)
        }.value
    }
}

enum LyricsFit {
    /// The small LM often writes far more than fits: keep whole sections, in order,
    /// within ~1 sung line every 3.5 s, and always keep the first chorus.
    static func trim(_ lyrics: String, duration: Double, style: String = "") -> String {
        // Rap packs many more words: one long bar every ~2.6 s instead of a sung line every 3.5 s.
        let budget = max(12, Int(duration / (Genre.isRap(style) ? 2.4 : 3.0)))
        var sections: [(header: String, lines: [String])] = []
        for raw in lyrics.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { sections.append((line, [])) }
            else if !line.isEmpty {
                if sections.isEmpty { sections.append(("[Verse 1]", [])) }
                sections[sections.count - 1].lines.append(line)
            }
        }
        let total = sections.reduce(0) { $0 + $1.lines.count }
        guard total > budget else { return lyrics }
        var out: [String] = []
        var used = 0
        var hasChorus = false
        for s in sections {
            let isChorus = s.header.lowercased().contains("chorus")
            let n = s.lines.count
            if n == 0 { if used < budget { out.append(s.header) }; continue }
            if used + n <= budget || (isChorus && !hasChorus) {
                out.append(s.header)
                out.append(contentsOf: s.lines.prefix(isChorus ? n : budget - used))
                used += n
                if isChorus { hasChorus = true }
            }
            if used >= budget && hasChorus { break }
        }
        if !(out.last(where: { $0.hasPrefix("[") })?.lowercased().contains("outro") ?? false) { out.append("[Outro]") }
        return out.joined(separator: "\n").replacingOccurrences(of: "\n[", with: "\n\n[")
    }

    /// First sung lines of the first chorus (for the cover prompt).
    static func chorusLines(_ lyrics: String, max: Int) -> String {
        var inChorus = false
        var out: [String] = []
        for raw in lyrics.components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("[") {
                if inChorus && !out.isEmpty { break }
                inChorus = l.lowercased().contains("chorus") && !l.lowercased().contains("pre-chorus"); continue
            }
            if inChorus && !l.isEmpty { out.append(l) }
            if out.count >= max { break }
        }
        return out.joined(separator: " / ")
    }

    /// Suno-style title: the first line of the first chorus (max 6 words), else the first sung line.
    static func title(from lyrics: String) -> String? {
        let lines = lyrics.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var inChorus = false
        var firstSung: String?
        for l in lines {
            if l.hasPrefix("[") { inChorus = l.lowercased().contains("chorus") && !l.lowercased().contains("pre-chorus"); continue }
            guard !l.isEmpty else { continue }
            if firstSung == nil { firstSung = l }
            if inChorus { return shorten(l) }
        }
        return firstSung.map(shorten)
    }

    private static func shorten(_ l: String) -> String {
        let w = l.split(separator: " ").prefix(6).joined(separator: " ")
        let t = w.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?…'\" "))
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    /// Per-section singer tags (ACE-Step reads descriptors like "[Chorus - Female Vocal]").
    /// For a duet, verses alternate male/female and choruses/bridge/outro are sung together.
    static func tagVoices(_ lyrics: String, voice: Voice, style: String = "") -> String {
        let rap = Genre.isRap(style)
        guard voice != .auto || rap else { return lyrics }
        var verseIndex = 0
        return lyrics.components(separatedBy: "\n").map { raw -> String in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), line.hasSuffix("]") else { return raw }
            let inner = String(line.dropFirst().dropLast())
            // "[Verse 1: Male Vocal]" and "[Verse 1 - Male Vocal]" both reduce to "Verse 1".
            let base = (inner.components(separatedBy: " - ").first ?? inner)
                .components(separatedBy: ":").first!.trimmingCharacters(in: .whitespaces)
            let lower = base.lowercased()
            if lower.contains("instrumental") || lower.contains("solo") || lower.contains("break") { return "[\(base)]" }
            let isVerse = lower.contains("verse") || lower.contains("bridge")
            let vocal = rap && isVerse ? "Rap" : "Vocal"
            var singer: String
            switch voice {
            case .female: singer = "Female \(vocal)"
            case .male: singer = "Male \(vocal)"
            case .duet:
                if lower.contains("verse") || lower.contains("pre-chorus") || lower.contains("intro") {
                    singer = (verseIndex % 2 == 0 ? "Male " : "Female ") + vocal
                    if lower.contains("verse") { verseIndex += 1 }
                } else {
                    singer = "Male and Female Duet"
                }
            case .auto: singer = vocal == "Rap" ? "Rap" : ""
            }
            if rap && !isVerse && voice != .duet { singer += singer.isEmpty ? "Energetic" : ", Energetic" }
            return singer.isEmpty ? "[\(base)]" : "[\(base) - \(singer)]"
        }.joined(separator: "\n")
    }

    /// Makes the LM's prose caption agree with the voice the user picked.
    static func applyVoice(_ style: String, voice: Voice) -> String {
        func swap(_ s: String, _ from: String, _ to: String) -> String {
            s.replacingOccurrences(of: "\\b\(from)\\b", with: to, options: [.regularExpression, .caseInsensitive])
        }
        switch voice {
        case .female: return swap(style, "male", "female")
        case .male: return swap(style, "female", "male")
        default: return style   // duet: the tag added by effectiveStyle is enough
        }
    }
}

enum Voice: String, Codable, CaseIterable, Identifiable {
    case auto, female, male, duet
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Auto"
        case .female: "Female"
        case .male: "Male"
        case .duet: "Duet"
        }
    }
    var styleTag: String? {
        switch self {
        case .auto: nil
        case .female: "female vocals"
        case .male: "male vocals"
        case .duet: "male and female duet, alternating male and female vocals"
        }
    }
}
