import SwiftUI
import AppKit

@main
struct ACEStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("ACE Studio", id: "main") {
            ContentView()
                .environment(delegate.store)
                .frame(minWidth: 1240, minHeight: 700)
        }
        .defaultSize(width: 1380, height: 860)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        Settings {
            SettingsView().environment(delegate.store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor lazy var store = Store()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            store.bootstrap()
            runDebugFlags()
        }
    }

    /// Debug flags:
    ///   --test-simple "<description>" <sec>   simple mode (LLM writes, then generates)
    ///   --test-song "<style>" <sec>           instrumental custom song
    ///   --section library|liked  --select-first
    ///   --window-shot <file.png> --delay <sec>  saves the app's own window
    ///   --no-engine                             UI only: skip the engine and background services
    ///   --fill-description|--fill-style|--fill-lyrics "<text>"   pre-fill the composer (for screenshots)
    ///   --library <folder>                      use another library folder (demo data)
    @MainActor private func runDebugFlags() {
        let args = CommandLine.arguments
        func value(_ flag: String, _ offset: Int = 1) -> String? {
            guard let i = args.firstIndex(of: flag), i + offset < args.count else { return nil }
            return args[i + offset]
        }
        if let f = value("--import-ionos-key") { store.importIonosKey(from: URL(fileURLWithPath: f)) }
        if args.contains("--missing-covers") { store.makeMissingCovers() }
        if let v = value("--voice"), let voice = Voice(rawValue: v) { store.draft.voice = voice }
        if let desc = value("--test-simple") {
            store.mode = .simple
            store.draft.description = desc
            store.draft.duration = Double(value("--test-simple", 2) ?? "") ?? 60
            store.create()
        }
        if let style = value("--test-song") {
            store.mode = .custom
            store.draft.style = style
            store.draft.instrumental = true
            store.draft.duration = Double(value("--test-song", 2) ?? "") ?? 30
            store.create()
            store.draft = SongDraft()
        }
        if let s = value("--section") { store.section = s == "liked" ? .liked : s == "library" ? .library : .create }
        if args.contains("--select-first") { store.selected = store.tracks.first?.id }
        if args.contains("--mode-custom") { store.mode = .custom }
        if let t = value("--fill-description") { store.draft.description = t }
        if let t = value("--fill-style") { store.draft.style = t }
        if let t = value("--fill-lyrics") { store.draft.lyrics = t.replacingOccurrences(of: "\\n", with: "\n") }
        if let t = value("--fill-title") { store.draft.title = t }
        // Automation: --make-song <request.json> renders one custom song headless, copies it, then quits.
        if let req = value("--make-song") { makeSongAndQuit(req) }
        if args.contains("--play-first"), let t = store.tracks.first { store.toggle(t) }
        if let shot = value("--window-shot") {
            let delay = Double(value("--delay") ?? "") ?? 3
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let win = NSApp.windows.filter { $0.contentView != nil }
                    .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
                guard let win else { NSLog("window-shot: no window"); return }
                var rep: NSBitmapImageRep?
                // Composited capture of our own window (scroll views and grids included);
                // CGWindowListCreateImage is obsoleted in the SDK, so resolve it at run time.
                typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
                if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
                    let create = unsafeBitCast(sym, to: Fn.self)
                    // optionIncludingWindow = 8, boundsIgnoreFraming = 1, bestResolution = 8
                    if let img = create(.null, 8, UInt32(win.windowNumber), 1 | 8)?.takeRetainedValue() {
                        rep = NSBitmapImageRep(cgImage: img)
                    }
                }
                if rep == nil, let view = win.contentView, let r = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: r)
                    rep = r
                }
                NSLog("window-shot: window %d, image %@", win.windowNumber, rep == nil ? "none" : "ok")
                do { try rep?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: shot)) }
                catch { NSLog("window-shot: write failed %@", "\(error)") }
            }
        }
    }

    /// Request JSON: {"title","style","lyrics","duration","voice":"male|female|duet|auto","language","out","status"}.
    /// Uses the normal custom-mode pipeline (voice tags, LM planning, engine), copies the mp3 to `out`,
    /// writes a status JSON to `status` (ok, out, title, style, lyrics or error) and quits.
    @MainActor private func makeSongAndQuit(_ path: String) {
        struct Req: Decodable {
            var title: String?, style: String, lyrics: String, duration: Double?
            var voice: String?, language: String?, out: String, status: String?
        }
        func finish(_ obj: [String: Any], _ statusPath: String?) {
            if let s = statusPath, let data = try? JSONSerialization.data(withJSONObject: obj) {
                try? data.write(to: URL(fileURLWithPath: s))
            }
            NSApp.terminate(nil)
        }
        guard let data = FileManager.default.contents(atPath: path),
              let req = try? JSONDecoder().decode(Req.self, from: data) else {
            NSLog("make-song: unreadable request %@", path)
            NSApp.terminate(nil)
            return
        }
        store.mode = .custom
        var d = SongDraft()
        d.title = req.title ?? ""
        d.style = req.style
        d.lyrics = req.lyrics
        d.duration = req.duration ?? 60
        d.voice = Voice(rawValue: req.voice ?? "male") ?? .male
        d.language = req.language ?? "de"
        store.draft = d
        let knownTracks = Set(store.tracks.map(\.id))
        let knownFailed = Set(store.failed.map(\.id))
        store.create()
        store.draft = SongDraft()
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(45 * 60)
            while Date() < deadline {
                try? await Task.sleep(for: .seconds(3))
                if let t = store.tracks.first(where: { !knownTracks.contains($0.id) }) {
                    let dest = URL(fileURLWithPath: req.out)
                    try? FileManager.default.removeItem(at: dest)
                    do {
                        try FileManager.default.copyItem(at: t.url, to: dest)
                        finish(["ok": true, "out": req.out, "title": t.title, "style": t.style, "lyrics": t.lyrics], req.status)
                    } catch {
                        finish(["ok": false, "error": "copy failed: \(error.localizedDescription)"], req.status)
                    }
                    return
                }
                if let j = store.failed.first(where: { !knownFailed.contains($0.id) }) {
                    finish(["ok": false, "error": j.error ?? "generation failed"], req.status)
                    return
                }
            }
            finish(["ok": false, "error": "timeout"], req.status)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let (engine, restore) = MainActor.assumeIsolated { (store.engine, store.stoppedServices) }
        let defaults = UserDefaults.standard
        let stopEngine = defaults.object(forKey: "stopEngineOnQuit") as? Bool ?? true
        let restoreServices = defaults.object(forKey: "restoreServicesOnQuit") as? Bool ?? true
        DispatchQueue.global().async {
            Store.shutdown(engine: engine, restore: restore, stopEngine: stopEngine, restoreServices: restoreServices)
            DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}
