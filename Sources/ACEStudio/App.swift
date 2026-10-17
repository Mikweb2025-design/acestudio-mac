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
