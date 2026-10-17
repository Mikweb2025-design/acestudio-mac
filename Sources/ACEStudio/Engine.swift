import Foundation

/// Owns the ACE-Step API server process and talks to its HTTP API.
/// The server is started with the 16 GB OOM-safe profile (MLX DiT+VAE fp16,
/// LLM off, batch 1, no MPS watermark) that was verified for 180 s songs.
final class Engine: @unchecked Sendable {
    static let port = 8001
    let base = URL(string: "http://127.0.0.1:\(Engine.port)")!
    private var process: Process?

    static let oomSafeEnv: [String: String] = [
        "ACESTEP_USE_MLX_DIT": "1",
        "ACESTEP_MLX_DIT_FP16": "1",
        "ACESTEP_USE_MLX_VAE": "1",
        "ACESTEP_MLX_VAE_FP16": "1",
        "ACESTEP_MLX_VAE_CHUNK": "256",
        "ACESTEP_INIT_LLM": "false",
        "ACESTEP_SAVE_MEMORY": "1",
        "ACESTEP_VAE_ON_CPU": "1",
        "ACESTEP_DTYPE": "float16",
        "ACESTEP_OFFLOAD_TO_CPU": "false",
        "ACESTEP_OFFLOAD_DIT_TO_CPU": "false",
        "ACESTEP_BATCH_SIZE": "1",
        "PYTORCH_MPS_HIGH_WATERMARK_RATIO": "0.0",
        "PYTORCH_MPS_LOW_WATERMARK_RATIO": "0.0",
        "PYTORCH_ENABLE_MPS_FALLBACK": "1",
        "TOKENIZERS_PARALLELISM": "false",
        "MALLOC_ARENA_MAX": "2",
        "OMP_NUM_THREADS": "8",
        "PYTHONUNBUFFERED": "1",
    ]

    // MARK: Server lifecycle

    func isHealthy() async -> Bool {
        guard let json = try? await getJSON("/health"),
              let data = json["data"] as? [String: Any] else { return false }
        return (data["models_initialized"] as? Bool) ?? false
    }

    func start() throws {
        guard let uv = Paths.uvCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw EngineError.message("uv not found (~/.local/bin/uv)")
        }
        try FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Paths.serverLog.path, contents: nil)
        let log = try FileHandle(forWritingTo: Paths.serverLog)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: uv)
        p.arguments = ["run", "acestep-api", "--host", "127.0.0.1", "--port", "\(Engine.port)"]
        p.currentDirectoryURL = Paths.aceDir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(Paths.home.path)/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HF_HOME"] = Paths.home.appendingPathComponent(".cache/huggingface").path
        for (k, v) in Engine.oomSafeEnv { env[k] = v }
        p.environment = env
        p.standardOutput = log
        p.standardError = log
        try p.run()
        process = p
    }

    var processAlive: Bool { process?.isRunning ?? false }

    /// Stops the server (the one we started, plus any orphan on our port) to free RAM.
    func stop() {
        process?.terminate()
        process = nil
        Shell.run("/usr/bin/pkill", ["-f", "acestep-api --host 127.0.0.1 --port \(Engine.port)"])
    }

    // MARK: Generation API

    func submit(_ body: [String: Any]) async throws -> String {
        let json = try await postJSON("/release_task", body)
        if let err = json["error"] as? String, !err.isEmpty { throw EngineError.message(err) }
        guard let data = json["data"] as? [String: Any], let id = data["task_id"] as? String else {
            throw EngineError.message("Unexpected response from the engine")
        }
        return id
    }

    enum TaskState { case running, done([String: Any]), failed(String) }

    func query(_ taskId: String) async throws -> TaskState {
        let json = try await postJSON("/query_result", ["task_id_list": [taskId]])
        guard let item = (json["data"] as? [[String: Any]])?.first else { return .running }
        let status = item["status"] as? Int ?? 0
        if status == 0 { return .running }
        var result: Any? = item["result"]
        if let s = result as? String, let d = s.data(using: .utf8) { result = try? JSONSerialization.jsonObject(with: d) }
        let first = (result as? [[String: Any]])?.first ?? (result as? [String: Any]) ?? [:]
        if status == 1 { return .done(first) }
        let msg = (first["error"] as? String) ?? (item["result"] as? String) ?? "Generation failed"
        return .failed(String(msg.prefix(300)))
    }

    /// Copies the generated file into `dest`. The API returns `/v1/audio?path=<local path>`.
    func fetchAudio(fileRef: String, to dest: URL) async throws {
        if let comps = URLComponents(string: fileRef),
           let local = comps.queryItems?.first(where: { $0.name == "path" })?.value,
           FileManager.default.fileExists(atPath: local) {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: local), to: dest)
            return
        }
        let url = URL(string: fileRef, relativeTo: base)!
        let (tmp, _) = try await URLSession.shared.download(from: url)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    // MARK: Progress from the server log

    struct Progress { var phase: String; var fraction: Double? }

    /// Reads the tail of the server log to tell which stage the current job is in.
    func readProgress() -> Progress? {
        guard let h = try? FileHandle(forReadingFrom: Paths.serverLog) else { return nil }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: end > 6000 ? end - 6000 : 0)
        let tail = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        let markers: [(String, String)] = [
            ("Saved audio", "Saving"),
            ("VAE decode completed", "Saving"),
            ("Decoding latents", "Decoding audio"),
            ("DiT diffusion", "Composing"),
            ("Loading model to", "Loading model"),
            ("preprocess_batch", "Analyzing text & style"),
        ]
        var best: (Int, String)? = nil
        for (needle, label) in markers {
            if let r = tail.range(of: needle, options: .backwards) {
                let pos = tail.distance(from: tail.startIndex, to: r.lowerBound)
                if best == nil || pos > best!.0 { best = (pos, label) }
            }
        }
        guard let phase = best?.1 else { return nil }
        var fraction: Double? = nil
        if phase == "Composing", let r = tail.range(of: "diffusion:", options: .backwards) {
            let seg = tail[r.upperBound...]
            if let m = seg.firstMatch(of: #/\|\s*(\d+)/(\d+)\s*\[/#),
               let a = Double(m.1), let b = Double(m.2), b > 0 {
                fraction = a / b
            }
        }
        return Progress(phase: phase, fraction: fraction)
    }

    // MARK: HTTP helpers

    private func getJSON(_ path: String) async throws -> [String: Any] {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.timeoutInterval = 5
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func postJSON(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

enum EngineError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}
