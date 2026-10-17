import Foundation
import AVFoundation
import Observation
import AppKit

enum Mode: String, Codable { case simple, custom }

struct SongDraft: Codable, Equatable {
    var description = ""     // simple mode: what you want
    var title = ""
    var style = ""
    var lyrics = ""
    var instrumental = false
    var voice: Voice = .auto
    var duration: Double = 120
    var language = "en"
    var bpm = 0              // 0 = auto
    var key = ""             // "" = auto
    var seed = ""            // "" = random
    var steps = 12           // turbo: 8 is the floor, 12 is cleaner (max 20)
    var planning = true      // LM audio-code plan before the DiT (better vocals)

    init() {}

    /// Tolerant decoding: entries saved by older versions miss newer fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        style = try c.decodeIfPresent(String.self, forKey: .style) ?? ""
        lyrics = try c.decodeIfPresent(String.self, forKey: .lyrics) ?? ""
        instrumental = try c.decodeIfPresent(Bool.self, forKey: .instrumental) ?? false
        voice = try c.decodeIfPresent(Voice.self, forKey: .voice) ?? .auto
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 120
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en"
        bpm = try c.decodeIfPresent(Int.self, forKey: .bpm) ?? 0
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        seed = try c.decodeIfPresent(String.self, forKey: .seed) ?? ""
        steps = try c.decodeIfPresent(Int.self, forKey: .steps) ?? 12
        planning = try c.decodeIfPresent(Bool.self, forKey: .planning) ?? true
    }

    /// Style sent to the DiT: the voice choice is enforced on top of what the LM wrote.
    var effectiveStyle: String {
        var s = style.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = description }
        if let v = voice.styleTag, !instrumental, !s.localizedCaseInsensitiveContains(v) { s += ", \(v)" }
        return s.isEmpty ? "pop" : s
    }
}

struct Track: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var style: String
    var lyrics: String
    var duration: Double
    var seed: String
    var created = Date()
    var fileName: String
    var song: SongDraft?
    var liked: Bool?
    var coverFile: String?

    var url: URL { Paths.library.appendingPathComponent(fileName) }
    var coverURL: URL? {
        guard let c = coverFile else { return nil }
        let u = Paths.library.appendingPathComponent(c)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    var isLiked: Bool { liked ?? false }
}

@Observable
final class Job: Identifiable {
    let id = UUID()
    var draft: SongDraft
    var title: String
    let needsWriting: Bool
    var phase = "Queued"
    var fraction: Double? = nil
    var started: Date? = nil
    var error: String? = nil

    init(draft: SongDraft, title: String, needsWriting: Bool) {
        self.draft = draft; self.title = title; self.needsWriting = needsWriting
    }

    /// Measured on this 16 GB Mac: 180 s song ≈ 6 min; LM lyrics ≈ 40 s.
    var estimatedSeconds: Double { Store.estimate(draft, writing: needsWriting) }
}

enum EngineState: Equatable {
    case stopped, starting, ready
    case error(String)
}

@MainActor
@Observable
final class Store {
    static let maxSongSeconds: Double = 180

    /// Measured on this 16 GB Mac: 180 s song ≈ 6 min, LM lyrics ≈ 40 s, LM plan ≈ 16 s + 0.25 s/s.
    nonisolated static func estimate(_ d: SongDraft, writing: Bool) -> Double {
        40 + d.duration * 1.9 * (0.5 + 0.5 * Double(d.steps) / 8) + (writing ? 10 : 0) + (d.planning ? 20 + d.duration * 0.25 : 0)
    }

    let engine = Engine()
    var engineState: EngineState = .stopped
    var stoppedServices: [String] = []
    var memory = MemoryInfo.current()

    var mode: Mode = .simple
    var draft = SongDraft()
    var jobs: [Job] = []
    var failed: [Job] = []
    var tracks: [Track] = []
    var section: Section = .create
    var selected: Track.ID?
    var writing = false          // "Write lyrics with AI" in custom mode
    var writeError: String?

    // Player
    var nowPlaying: Track?
    var isPlaying = false
    var position: Double = 0
    var length: Double = 0
    var volume: Float = 0.9 { didSet { player?.volume = volume } }
    private var player: AVAudioPlayer?

    private var heavyBusy = false   // one heavy model (LM or DiT) at a time
    private var workerRunning = false
    private var timer: Timer?

    enum Section: Hashable { case create, library, liked }

    init() {
        try? FileManager.default.createDirectory(at: Paths.library, withIntermediateDirectories: true)
        loadLibrary()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    var selectedTrack: Track? { tracks.first { $0.id == selected } }

    // MARK: Startup / shutdown

    func bootstrap() {
        if CommandLine.arguments.contains("--no-engine") { return }
        Task {
            _ = await Task.detached { HeavyServices.stopAll() }.value
            stoppedServices = HeavyServices.labels   // always brought back on exit
            let d = UserDefaults.standard
            Watchdog.start(restore: (d.object(forKey: "restoreServicesOnQuit") as? Bool ?? true) ? HeavyServices.labels : [],
                           stopEngine: d.object(forKey: "stopEngineOnQuit") as? Bool ?? true)
            await ensureEngine()
        }
    }

    func ensureEngine() async {
        if await engine.isHealthy() { engineState = .ready; runQueue(); return }
        engineState = .starting
        if !engine.processAlive {
            engine.stop()
            do { try engine.start() } catch {
                engineState = .error(error.localizedDescription); return
            }
        }
        for _ in 0..<360 {
            try? await Task.sleep(for: .seconds(1))
            if await engine.isHealthy() { engineState = .ready; runQueue(); return }
            if !engine.processAlive {
                engineState = .error("The ACE-Step engine exited on startup."); return
            }
        }
        engineState = .error("The engine did not respond within 6 minutes.")
    }

    nonisolated static func shutdown(engine: Engine, restore: [String], stopEngine: Bool, restoreServices: Bool) {
        if stopEngine { engine.stop() }
        if restoreServices { HeavyServices.restore(restore) }
    }

    // MARK: Create

    var canCreate: Bool {
        mode == .simple
            ? !draft.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            : !(draft.style + draft.lyrics).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func create() {
        var d = draft
        d.duration = min(max(d.duration, 30), Store.maxSongSeconds)
        let simple = mode == .simple
        if simple { d.style = ""; d.lyrics = "" }
        let title = d.title.trimmingCharacters(in: .whitespaces).isEmpty
            ? autoTitle(from: simple ? d.description : (d.instrumental ? d.style : d.lyrics))
            : d.title
        jobs.append(Job(draft: d, title: title, needsWriting: simple))
        runQueue()
    }

    func variation(of t: Track) {
        guard var d = t.song else { return }
        d.seed = ""
        jobs.append(Job(draft: d, title: t.title + " (variation)", needsWriting: false))
        section = .create
        runQueue()
    }

    func cancel(_ job: Job) {
        if job.started == nil { jobs.removeAll { $0.id == job.id } }
    }

    func dismissFailed(_ job: Job) { failed.removeAll { $0.id == job.id } }

    /// Custom mode: let ACE's LM write lyrics (and style/BPM/key if empty) into the form.
    func writeLyrics() {
        guard !writing else { return }
        writing = true
        writeError = nil
        Task {
            await acquireHeavy()
            defer { releaseHeavy(); writing = false }
            do {
                let d = draft
                let s = try await Store.writeSong(d)
                draft.lyrics = LyricsFit.trim(s.lyrics ?? draft.lyrics, duration: d.duration, style: s.style ?? d.style)
                if draft.style.trimmingCharacters(in: .whitespaces).isEmpty {
                    draft.style = LyricsFit.applyVoice(s.style ?? "", voice: d.voice)
                }
                if draft.bpm == 0, let b = s.bpm { draft.bpm = b }
                if draft.key.isEmpty, let k = s.key, CreateOptions.keys.contains(k) { draft.key = k }
            } catch {
                writeError = error.localizedDescription
            }
        }
    }

    struct WrittenSong { var title: String?; var style: String?; var lyrics: String?; var bpm: Int?; var key: String? }

    /// IONOS gpt-oss-120b when a key is set (follows genre and theme), else ACE-Step's own LM.
    static func writeSong(_ d: SongDraft) async throws -> WrittenSong {
        if IonosWriter.isEnabled, let s = try? await IonosWriter.write(d) {
            return WrittenSong(title: s.title, style: s.style, lyrics: s.lyrics, bpm: s.bpm, key: s.key)
        }
        let q = Writer.query(description: d.description, style: d.style, title: d.title,
                             voice: d.voice, language: d.language, instrumental: d.instrumental)
        let s = try await Writer.write(query: q, language: d.language, instrumental: d.instrumental)
        return WrittenSong(title: nil, style: s.style, lyrics: s.lyrics, bpm: s.bpm, key: s.key)
    }

    private func autoTitle(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("[") } ?? "Untitled"
        let words = firstLine.split(separator: " ").prefix(5).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?"))
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    // MARK: Queue

    private func acquireHeavy() async {
        while heavyBusy { try? await Task.sleep(for: .milliseconds(500)) }
        heavyBusy = true
    }

    private func releaseHeavy() { heavyBusy = false }

    private func runQueue() {
        guard !workerRunning, engineState == .ready, !jobs.isEmpty else { return }
        workerRunning = true
        Task {
            while let job = jobs.first, engineState == .ready {
                await acquireHeavy()
                await run(job)
                releaseHeavy()
                jobs.removeAll { $0.id == job.id }
                if job.error != nil { failed.insert(job, at: 0) }
            }
            workerRunning = false
        }
    }

    /// One job at a time, batch 1: the rule that keeps a 3-minute song inside 16 GB.
    private func run(_ job: Job) async {
        job.started = Date()
        do {
            if job.needsWriting {
                job.phase = "Writing lyrics & style"
                let d = job.draft
                let s = try await Store.writeSong(d)
                // The user's own words lead the style: the writer's tags follow them.
                job.draft.style = LyricsFit.applyVoice(s.style ?? d.description, voice: d.voice)
                job.draft.lyrics = LyricsFit.trim(s.lyrics ?? "", duration: d.duration, style: job.draft.style)
                if d.title.trimmingCharacters(in: .whitespaces).isEmpty,
                   let t = (s.title?.isEmpty == false ? s.title : nil) ?? LyricsFit.title(from: job.draft.lyrics) {
                    job.title = t
                }
                if job.draft.bpm == 0, let b = s.bpm { job.draft.bpm = b }
                if job.draft.key.isEmpty, let k = s.key { job.draft.key = k }
            }
            if !job.draft.instrumental {
                job.draft.lyrics = LyricsFit.tagVoices(job.draft.lyrics, voice: job.draft.voice, style: job.draft.effectiveStyle)
            }
            var codes = ""
            if job.draft.planning {
                job.phase = "Planning melody & vocals"
                job.fraction = nil
                // Not fatal: without the plan the song is still generated, just without "thinking".
                codes = (try? await Writer.audioCodes(for: job.draft)) ?? ""
            }
            await waitForMemory(job)
            job.phase = "Sending to engine"
            job.fraction = nil
            let taskId = try await engine.submit(payload(for: job.draft, codes: codes))
            var misses = 0
            while true {
                try? await Task.sleep(for: .seconds(2))
                if let p = engine.readProgress() { job.phase = p.phase; job.fraction = p.fraction }
                let state: Engine.TaskState
                do { state = try await engine.query(taskId); misses = 0 } catch {
                    misses += 1
                    if misses >= 6 {
                        throw EngineError.message("The engine stopped (likely out of memory). Try again.")
                    }
                    continue
                }
                switch state {
                case .running: continue
                case .failed(let msg): throw EngineError.message(msg)
                case .done(let result):
                    job.phase = "Saving"
                    try await save(job, result: result)
                    return
                }
            }
        } catch {
            job.error = error.localizedDescription
            if !(await engine.isHealthy()) {
                engineState = .starting
                engine.stop()
                await ensureEngine()
            }
        }
    }

    /// Waits (max 60 s) for at least 3 GB available before the DiT runs.
    private func waitForMemory(_ job: Job) async {
        for _ in 0..<30 {
            memory = MemoryInfo.current()
            if memory.availableGB >= 3 { return }
            job.phase = "Waiting for free RAM"
            _ = await Task.detached { HeavyServices.stopAll() }.value
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func payload(for s: SongDraft, codes: String) -> [String: Any] {
        var p: [String: Any] = [
            "batch_size": 1,
            "thinking": false,
            "sample_mode": false,
            "use_format": false,
            "use_cot_caption": false,
            "use_cot_language": false,
            "task_type": "text2music",
            "prompt": s.effectiveStyle,
            "lyrics": s.instrumental || s.lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "[Instrumental]" : s.lyrics,
            "audio_duration": s.duration,
            "inference_steps": s.steps,
            "vocal_language": s.instrumental ? "unknown" : s.language,
            "audio_format": "mp3",
        ]
        if s.bpm > 0 { p["bpm"] = s.bpm }
        if !s.key.isEmpty { p["key_scale"] = s.key }
        if !codes.isEmpty { p["audio_code_string"] = codes }
        if let n = Int(s.seed.trimmingCharacters(in: .whitespaces)) {
            p["use_random_seed"] = false
            p["seed"] = n
        } else {
            p["use_random_seed"] = true
        }
        return p
    }

    private func save(_ job: Job, result: [String: Any]) async throws {
        guard let file = result["file"] as? String, !file.isEmpty else {
            throw EngineError.message("No audio file in the result")
        }
        let seed = (result["seed_value"] as? String)?.split(separator: ",").first.map(String.init) ?? ""
        let name = "song-\(Int(Date().timeIntervalSince1970))-\(job.id.uuidString.prefix(4)).mp3"
        let dest = Paths.library.appendingPathComponent(name)
        try await engine.fetchAudio(fileRef: file, to: dest)
        var d = job.draft
        d.seed = seed
        let track = Track(title: job.title, style: d.effectiveStyle,
                          lyrics: d.instrumental ? "" : d.lyrics,
                          duration: d.duration, seed: seed, fileName: name, song: d)
        tracks.insert(track, at: 0)
        persistLibrary()
        if selected == nil { selected = track.id }
        makeCover(for: track)
    }

    // MARK: AI covers (IONOS FLUX.1-schnell)

    var coversInProgress: Set<Track.ID> = []
    var coverError: String?
    var hasIonosKey = IonosKey.load() != nil

    func makeCover(for t: Track) {
        guard hasIonosKey, !coversInProgress.contains(t.id) else { return }
        coversInProgress.insert(t.id)
        Task {
            defer { coversInProgress.remove(t.id) }
            do {
                let url = try await CoverArt.generate(for: t)
                if let i = tracks.firstIndex(where: { $0.id == t.id }) {
                    tracks[i].coverFile = url.lastPathComponent
                    CoverCache.shared.invalidate(url)
                    persistLibrary()
                }
                coverError = nil
            } catch {
                coverError = error.localizedDescription
            }
        }
    }

    func makeMissingCovers() {
        for t in tracks where t.coverURL == nil { makeCover(for: t) }
    }

    func setIonosKey(_ key: String) {
        IonosKey.save(key)
        hasIonosKey = IonosKey.load() != nil
    }

    func importIonosKey(from url: URL) {
        _ = IonosKey.importFile(url)
        hasIonosKey = IonosKey.load() != nil
    }

    // MARK: Library

    private var libraryFile: URL { Paths.library.appendingPathComponent("library.json") }

    private func loadLibrary() {
        guard let data = try? Data(contentsOf: libraryFile) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        tracks = ((try? dec.decode([Track].self, from: data)) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.url.path) && $0.fileName.hasSuffix(".mp3") }
    }

    private func persistLibrary() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        try? enc.encode(tracks).write(to: libraryFile, options: .atomic)
    }

    func delete(_ t: Track) {
        if nowPlaying?.id == t.id { stop() }
        if selected == t.id { selected = nil }
        try? FileManager.default.trashItem(at: t.url, resultingItemURL: nil)
        if let c = t.coverURL { try? FileManager.default.trashItem(at: c, resultingItemURL: nil) }
        tracks.removeAll { $0.id == t.id }
        persistLibrary()
    }

    func rename(_ t: Track, to title: String) {
        guard let i = tracks.firstIndex(where: { $0.id == t.id }), !title.isEmpty else { return }
        tracks[i].title = title
        if nowPlaying?.id == t.id { nowPlaying = tracks[i] }
        persistLibrary()
    }

    func toggleLike(_ t: Track) {
        guard let i = tracks.firstIndex(where: { $0.id == t.id }) else { return }
        tracks[i].liked = !tracks[i].isLiked
        persistLibrary()
    }

    func reuse(_ t: Track) {
        guard var s = t.song else { return }
        s.title = t.title
        s.seed = ""
        draft = s
        mode = .custom
        section = .create
    }

    func reveal(_ t: Track) { NSWorkspace.shared.activateFileViewerSelecting([t.url]) }

    // MARK: Player

    func toggle(_ t: Track) {
        if nowPlaying?.id == t.id, let player {
            if player.isPlaying { player.pause() } else { player.play() }
            isPlaying = player.isPlaying
            return
        }
        guard let p = try? AVAudioPlayer(contentsOf: t.url) else { return }
        player = p
        p.volume = volume
        p.play()
        nowPlaying = t
        length = p.duration
        position = 0
        isPlaying = true
    }

    func playAdjacent(_ step: Int) {
        guard let cur = nowPlaying, let i = tracks.firstIndex(where: { $0.id == cur.id }) else { return }
        let j = i + step
        guard tracks.indices.contains(j) else { return }
        toggle(tracks[j])
    }

    func seek(_ to: Double) { player?.currentTime = to; position = to }

    func stop() { player?.stop(); player = nil; nowPlaying = nil; isPlaying = false }

    private func tick() {
        if let player {
            position = player.currentTime
            if isPlaying && !player.isPlaying {
                isPlaying = false
                if position < 0.1 { position = 0; playAdjacent(1) }   // finished → next track
            }
        }
        // RAM readout: every ~2 s and only on visible change, to keep layout passes rare.
        memoryTick += 1
        if memoryTick % 4 == 0 {
            let m = MemoryInfo.current()
            if abs(m.availableGB - memory.availableGB) >= 0.1 { memory = m }
        }
    }
    @ObservationIgnored private var memoryTick = 0
}
