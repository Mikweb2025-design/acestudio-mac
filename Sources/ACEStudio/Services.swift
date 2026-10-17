import Foundation
import Darwin

/// Paths and constants for the local ACE-Step install.
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let aceDir = home.appendingPathComponent("ACE-Step-1.5")
    /// `--library <folder>` points the app at another library (used for demo screenshots).
    static let library: URL = {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--library"), i + 1 < args.count { return URL(fileURLWithPath: args[i + 1]) }
        return home.appendingPathComponent("Music/ACE Studio")
    }()
    static let logs = home.appendingPathComponent("Library/Logs/ACEStudio")
    static let serverLog = logs.appendingPathComponent("acestep-server.log")
    static let uvCandidates = [home.appendingPathComponent(".local/bin/uv").path, "/opt/homebrew/bin/uv"]
}

/// Background services that compete for RAM with ACE-Step (Qwen TTS, Jarvis).
/// They are launchd agents with KeepAlive, so a plain kill would respawn them:
/// we `bootout` them and `bootstrap` them back when the app quits.
enum HeavyServices {
    static let labels = ["com.qwen3tts.8091", "com.qwen3tts.8092", "info.mikweb.jarvis"]
    static let leftoverPatterns = ["qwen3-tts", "voice_clone_server.py", "start_qwen3tts_", "jarvis_server_fastapi.py"]

    static var domain: String { "gui/\(getuid())" }

    static func isLoaded(_ label: String) -> Bool {
        Shell.run("/bin/launchctl", ["print", "\(domain)/\(label)"]).status == 0
    }

    /// Stops the services that are running; returns the labels that were stopped.
    static func stopAll() -> [String] {
        var stopped: [String] = []
        for label in labels where isLoaded(label) {
            _ = Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
            stopped.append(label)
        }
        for pattern in leftoverPatterns {
            _ = Shell.run("/usr/bin/pkill", ["-f", pattern])
        }
        return stopped
    }

    static func restore(_ stopped: [String]) {
        for label in stopped where !isLoaded(label) {
            let plist = Paths.home.appendingPathComponent("Library/LaunchAgents/\(label).plist").path
            _ = Shell.run("/bin/launchctl", ["bootstrap", domain, plist])
        }
    }
}

/// Detached shell process that outlives the app: when ACE Studio exits for any reason
/// (quit, crash, force-quit) it stops the engine and brings Qwen TTS / Jarvis back.
enum Watchdog {
    static func start(restore labels: [String], stopEngine: Bool) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let domain = HeavyServices.domain
        var script = "while kill -0 \(pid) 2>/dev/null; do sleep 2; done\n"
        if stopEngine { script += "pkill -f 'acestep-api --host 127.0.0.1 --port \(Engine.port)'\n" }
        for label in labels {
            let plist = Paths.home.appendingPathComponent("Library/LaunchAgents/\(label).plist").path
            script += "launchctl print \(domain)/\(label) >/dev/null 2>&1 || launchctl bootstrap \(domain) '\(plist)'\n"
        }
        let file = Paths.logs.appendingPathComponent("watchdog.sh")
        try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        try? script.write(to: file, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [file.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            try? "watchdog failed: \(error)".write(to: Paths.logs.appendingPathComponent("watchdog.err"), atomically: true, encoding: .utf8)
        }
    }
}

enum Shell {
    @discardableResult
    static func run(_ exe: String, _ args: [String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// System memory snapshot (unified memory on Apple Silicon).
struct MemoryInfo {
    var totalGB: Double
    var availableGB: Double   // free + inactive + purgeable + speculative
    var swapUsedGB: Double

    static func current() -> MemoryInfo {
        let total = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var avail = 0.0
        if kr == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            let pages = Double(stats.free_count) + Double(stats.inactive_count)
                + Double(stats.purgeable_count) + Double(stats.speculative_count)
            avail = pages * page / 1_073_741_824
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        return MemoryInfo(totalGB: total, availableGB: avail, swapUsedGB: Double(swap.xsu_used) / 1_073_741_824)
    }
}
