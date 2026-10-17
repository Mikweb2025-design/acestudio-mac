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
        if args.contains("--play-first"), let t = store.tracks.first { store.toggle(t) }
        if let shot = value("--window-shot") {
            let delay = Double(value("--delay") ?? "") ?? 3
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let win = NSApp.windows.filter { $0.contentView != nil }
                    .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
                guard let view = win?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: shot))
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
