// Baa: a tiny ram for your RAM. menu bar monitor that finds leftovers (ghost processes, junk AI agents
// leave running, idle hogs), frees them in one click, and warns before you hit red.
import SwiftUI
import AppKit
import UserNotifications
import Darwin

// MARK: - readings

enum Mem {
    static func int32(_ name: String) -> Int {
        var v: Int32 = 0; var s = MemoryLayout<Int32>.size
        sysctlbyname(name, &v, &s, nil, 0); return Int(v)
    }
    static var freePct: Int { int32("kern.memorystatus_level") }          // what memory_pressure calls "free percentage"
    static var level: Int { int32("kern.memorystatus_vm_pressure_level") } // 1 normal, 2 warn, 4 critical
    static var swapGB: Double {
        var x = xsw_usage(); var s = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &x, &s, nil, 0); return Double(x.xsu_used) / 1_073_741_824
    }
}

@discardableResult
func run(_ path: String, _ args: [String]) -> (out: String, status: Int32) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return ("", -1) }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (String(decoding: d, as: UTF8.self), p.terminationStatus)
}

func dur(_ s: Double) -> String {
    let m = Int(s / 60); if m < 60 { return "\(m)m" }
    let h = m / 60; if h >= 48 { return "\(h / 24)d" }
    return (m % 60 == 0 || h >= 10) ? "\(h)h" : "\(h)h \(m % 60)m"
}
func size(_ b: Double) -> String {
    b >= 1_073_741_824 ? String(format: "%.1f GB", b / 1_073_741_824) : "\(Int(b / 1_048_576)) MB"
}

// MARK: - processes

struct Proc {
    let pid: Int, ppid: Int, uid: Int, rssKB: Int
    let elapsed: Double, cpu: Double
    let exe: String, cmd: String
    var label = ""
    var bytes = 0.0
    var base: String { (exe as NSString).lastPathComponent }
}

// same number activity monitor shows. unlike rss it includes memory macOS has compressed,
// which is exactly what idle leftovers turn into. only readable for your own processes
func footprint(_ pid: Int) -> Double? {
    var info = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(Int32(pid), RUSAGE_INFO_V4, $0) }
    }
    return ok == 0 ? Double(info.ri_phys_footprint) : nil
}

// "[dd-][hh:]mm:ss[.cc]" -> seconds (works for both etime and cputime)
func secs(_ s: Substring) -> Double {
    var days = 0.0, rest = s
    if let d = s.firstIndex(of: "-") { days = Double(s[..<d]) ?? 0; rest = s[s.index(after: d)...] }
    return days * 86400 + rest.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
}

// BAA_FAST=1 turns every "N minutes" threshold into N seconds (for testing)
let fast = ProcessInfo.processInfo.environment["BAA_FAST"] != nil
func mins(_ m: Double) -> Double { fast ? m : m * 60 }

let agentLabels: Set<String> = ["Claude Code", "Codex"]
let runtimeLabels: Set<String> = ["Node", "Python", "Bun", "Deno", "Ruby", "Java", "Headless browser", "Gradle", "Kotlin daemon"]
let shells: Set<String> = ["zsh", "-zsh", "bash", "-bash", "sh", "fish", "-fish", "login", "tmux", "screen"]

func isHeadless(_ exe: String, _ cmd: String) -> Bool {
    ["ms-playwright", "puppeteer", "chrome-headless-shell", "Chrome for Testing"].contains { exe.contains($0) }
        || (cmd.contains("--headless") && (exe.contains("Chrom") || exe.contains("chrom")))
}

// outermost .app in the path, so every "Google Chrome Helper" rolls up into "Google Chrome"
func appName(_ exe: String) -> String? {
    guard let r = exe.range(of: ".app/") else { return nil }
    return exe[..<r.lowerBound].split(separator: "/").last.map(String.init)
}

func label(_ exe: String, _ cmd: String) -> String {
    let base = (exe as NSString).lastPathComponent
    if cmd.contains("GradleDaemon") { return "Gradle" }
    if cmd.contains("KotlinCompileDaemon") || cmd.contains("kotlin-daemon") { return "Kotlin daemon" }
    if base.hasPrefix("qemu-system") || base == "emulator" { return "Android emulator" }
    if exe.contains("launchd_sim") || exe.contains("/CoreSimulator/Devices/") || exe.contains("Simulator.app/Contents/MacOS/Simulator") { return "iOS Simulator" }
    if isHeadless(exe, cmd) { return "Headless browser" }
    if base.lowercased().hasPrefix("python") { return "Python" }
    if base == "claude" || exe.contains("/claude/versions/") { return "Claude Code" }
    if base == "codex" { return "Codex" }
    if let a = appName(exe) { return a }
    switch base {
    case "node": return "Node"
    case "bun": return "Bun"
    case "deno": return "Deno"
    case "ruby": return "Ruby"
    case "java": return "Java"
    case "ollama": return "Ollama"
    default: return base
    }
}

func readProcs() -> [Int: Proc] {
    var exe: [Int: String] = [:]
    for line in run("/bin/ps", ["-axww", "-o", "pid=,comm="]).out.split(separator: "\n") {
        let t = line.drop(while: { $0 == " " })
        guard let sp = t.firstIndex(of: " "), let pid = Int(t[..<sp]) else { continue }
        exe[pid] = String(t[sp...].drop(while: { $0 == " " }))
    }
    var out: [Int: Proc] = [:]
    for line in run("/bin/ps", ["-axww", "-o", "pid=,ppid=,uid=,rss=,etime=,time=,command="]).out.split(separator: "\n") {
        let f = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true)
        guard f.count == 7, let pid = Int(f[0]), let ppid = Int(f[1]), let uid = Int(f[2]), let rss = Int(f[3]) else { continue }
        let e = exe[pid] ?? String(f[6])
        var p = Proc(pid: pid, ppid: ppid, uid: uid, rssKB: rss, elapsed: secs(f[4]), cpu: secs(f[5]), exe: e, cmd: String(f[6]))
        p.label = label(e, p.cmd)
        p.bytes = footprint(pid) ?? Double(rss) * 1024
        out[pid] = p
    }
    return out
}

// short name for what a node/python process is actually running
func hint(_ p: Proc) -> String? {
    let toks = p.cmd.split(separator: " ").map(String.init)
    for w in ["vite", "next", "webpack", "jupyter", "uvicorn", "streamlit", "gunicorn", "flask", "expo", "metro"]
    where toks.contains(where: { ($0 as NSString).lastPathComponent == w || ($0 as NSString).lastPathComponent.hasPrefix(w + "-") }) { return w }
    if let i = toks.firstIndex(of: "-m"), i + 1 < toks.count { return toks[i + 1] }
    if let s = toks.dropFirst().first(where: { t in [".py", ".js", ".mjs", ".cjs", ".ts"].contains { t.hasSuffix($0) } }) {
        return (s as NSString).lastPathComponent
    }
    return nil
}

// MARK: - findings

enum Kind { case ghost, agent, idle }
enum Fix { case kill([Int]), quit(String), run(String, [String]) }

struct Finding: Identifiable {
    let id: String, kind: Kind, title: String, detail: String, bytes: Double, fix: Fix
    var freeLabel: String { "Free \(size(bytes))" }
}

struct Scan {
    var apps: [(name: String, gb: Double)] = []
    var findings: [Finding] = []
    var freeable: Double { findings.reduce(0) { $0 + $1.bytes } }
}

final class Engine {
    // per-pid cpu history, so "idle" means "hasn't used CPU lately", not just "low right now"
    private var seen: [Int: (cpu: Double, at: Date, active: Date, born: Date)] = [:]
    private let me = Int(getuid())

    private func idle(_ p: Proc, _ now: Date) -> Double {
        let born = now.addingTimeInterval(-p.elapsed)
        if var s = seen[p.pid], abs(s.born.timeIntervalSince(born)) < 90 {
            let dt = now.timeIntervalSince(s.at)
            if dt > 0, (p.cpu - s.cpu) / dt >= 0.01 { s.active = now }
            s.cpu = p.cpu; s.at = now; seen[p.pid] = s
            return now.timeIntervalSince(s.active)
        }
        // first sighting: if it's barely touched the CPU in its whole life, call it idle since birth
        let quiet = p.elapsed > 0 && p.cpu / p.elapsed < 0.01
        let active = quiet ? born : now
        seen[p.pid] = (p.cpu, now, active, born)
        return now.timeIntervalSince(active)
    }

    private func launchdPIDs() -> Set<Int> {
        Set(run("/bin/launchctl", ["list"]).out.split(separator: "\n").compactMap { Int($0.split(separator: "\t").first ?? "") })
    }

    private func listeningPorts() -> [Int: [Int]] {
        var out: [Int: [Int]] = [:], cur = 0
        for l in run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-u", "\(me)", "-Fpn"]).out.split(separator: "\n") {
            if l.hasPrefix("p") { cur = Int(l.dropFirst()) ?? 0 }
            else if l.hasPrefix("n"), let c = l.lastIndex(of: ":"), let port = Int(l[l.index(after: c)...]),
                    !(out[cur]?.contains(port) ?? false) { out[cur, default: []].append(port) }
        }
        return out
    }

    private func cwds(_ pids: [Int]) -> [Int: String] {
        guard !pids.isEmpty else { return [:] }
        var out: [Int: String] = [:], cur = 0
        let args = ["-a", "-d", "cwd", "-p", pids.map(String.init).joined(separator: ","), "-Fpn"]
        for l in run("/usr/sbin/lsof", args).out.split(separator: "\n") {
            if l.hasPrefix("p") { cur = Int(l.dropFirst()) ?? 0 }
            else if l.hasPrefix("n") { out[cur] = (String(l.dropFirst()) as NSString).lastPathComponent }
        }
        return out
    }

    private func systemish(_ p: Proc) -> Bool {
        if runtimeLabels.contains(p.label) || agentLabels.contains(p.label) { return false }
        if !p.exe.hasPrefix("/") { return true } // bare names are almost always macOS agents
        let sys = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/", "/Library/Developer/",
                   "/Library/PrivilegedHelperTools/", "/Library/Application Support/", "/private/"]
        return sys.contains { p.exe.hasPrefix($0) } || [".app/", ".xpc/", ".framework/"].contains { p.exe.contains($0) }
    }

    func scan() -> Scan {
        let now = Date()
        let procs = readProcs()
        seen = seen.filter { procs[$0.key] != nil }

        var kids: [Int: [Int]] = [:]
        for p in procs.values where p.pid != p.ppid { kids[p.ppid, default: []].append(p.pid) }
        func tree(_ pid: Int) -> [Int] {
            var out = [pid], i = 0
            while i < out.count { out += kids[out[i]] ?? []; i += 1 }
            return out
        }
        let mine = procs.values.filter { $0.uid == me }.sorted { $0.pid < $1.pid }
        var idleOf: [Int: Double] = [:]
        for p in mine { idleOf[p.pid] = idle(p, now) }
        func treeIdle(_ pids: [Int]) -> Double { pids.compactMap { idleOf[$0] }.min() ?? 0 }
        func treeBytes(_ pids: [Int]) -> Double { pids.compactMap { procs[$0]?.bytes }.reduce(0, +) }

        // never suggest killing whatever launched us (eg the terminal running `baa`)
        var claimed = Set<Int>([Int(getpid())])
        var a = Int(getppid())
        while let p = procs[a], a > 1 { claimed.insert(a); a = p.ppid }

        var found: [Finding] = []
        func add(_ id: String, _ kind: Kind, _ title: String, _ detail: String, _ pids: [Int], fix: Fix? = nil) {
            let pids = pids.filter { !claimed.contains($0) && procs[$0]?.uid == me }
            guard !pids.isEmpty, treeBytes(pids) >= 50 * 1_048_576 else { return }
            claimed.formUnion(pids)
            found.append(Finding(id: id, kind: kind, title: title, detail: detail, bytes: treeBytes(pids), fix: fix ?? .kill(pids)))
        }

        let labels = Set(mine.map(\.label))
        let ideOpen = mine.contains {
            $0.label != "Gradle" && $0.label != "Kotlin daemon" &&
            ($0.exe.contains("Android Studio.app/Contents/MacOS/") || ($0.exe.contains("IntelliJ IDEA") && $0.exe.contains("/Contents/MacOS/")))
        }
        let simAppOpen = mine.contains { $0.exe.contains("Simulator.app/Contents/MacOS/Simulator") }

        // Gradle / Kotlin daemons outlive Android Studio by design
        let daemons = mine.filter { $0.label == "Gradle" || $0.label == "Kotlin daemon" }
        if !daemons.isEmpty {
            let pids = daemons.flatMap { tree($0.pid) }, i = treeIdle(pids)
            if !ideOpen && i >= mins(2) {
                add("gradle", .ghost, "Gradle + Kotlin daemons", "Android Studio is closed but these are still holding memory", pids)
            } else if i >= mins(20) {
                add("gradle", .idle, "Gradle + Kotlin daemons", "idle \(dur(i)) · they restart on your next build", pids)
            }
        }

        // simulators keep running after you close the Simulator window
        let sims = mine.filter { $0.exe.contains("launchd_sim") }
        if !sims.isEmpty && !simAppOpen {
            add("simulator", .ghost, "iOS Simulator (background)", "still booted, but the Simulator app is closed",
                sims.flatMap { tree($0.pid) }, fix: .run("/usr/bin/xcrun", ["simctl", "shutdown", "all"]))
        }

        // Android emulator
        let emu = mine.filter { $0.label == "Android emulator" && procs[$0.ppid]?.label != "Android emulator" }
        for e in emu {
            let pids = tree(e.pid), i = treeIdle(pids)
            if !ideOpen && i >= mins(10) { add("emulator", .ghost, "Android emulator", "Android Studio is closed · idle \(dur(i))", pids) }
            else if i >= mins(20) { add("emulator", .idle, "Android emulator", "no activity for \(dur(i))", pids) }
        }

        // Docker VM with nothing in it
        if let vm = mine.first(where: { ["com.docker.virtualization", "com.docker.hyperkit", "com.docker.krun"].contains(where: $0.cmd.contains) }) {
            let cli = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]
                .first { FileManager.default.isExecutableFile(atPath: $0) }
            if let cli {
                let r = run(cli, ["ps", "-q"])
                if r.status == 0 && r.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    add("docker", .idle, "Docker", "VM is running with no containers", tree(vm.pid), fix: .quit("Docker"))
                }
            }
        }

        // Ollama keeps the last model in RAM
        for p in mine where p.label == "Ollama" && p.cmd.contains(" runner") {
            let pids = tree(p.pid), i = treeIdle(pids)
            if i >= mins(10) { add("ollama-\(p.pid)", .idle, "Ollama model", "still loaded, idle \(dur(i)) · reloads next time you use it", pids) }
        }

        // AI agents: what they leave running, then the sessions themselves
        let sessions = mine.filter { agentLabels.contains($0.label) && procs[$0.ppid]?.label != $0.label &&
                                     !$0.cmd.contains("--chrome-native-host") && !$0.cmd.contains(" mcp") }
        let cwd = cwds(sessions.map(\.pid))
        func agentRoot(_ p: Proc) -> Proc? {
            var a = p.ppid
            while let q = procs[a], a > 1 {
                if agentLabels.contains(q.label) || q.label == "Cursor" { return procs[a] }
                a = q.ppid
            }
            return nil
        }
        func who(_ r: Proc) -> String { r.label + (cwd[r.pid].map { " (\($0))" } ?? "") }
        let ports = listeningPorts()
        for p in mine where !claimed.contains(p.pid) {
            let headless = p.label == "Headless browser"
            guard headless || (["Node", "Python", "Bun", "Deno", "Ruby"].contains(p.label) && ports[p.pid] != nil) else { continue }
            if procs[p.ppid]?.label == p.label { continue } // only the top of a browser/server tree
            let root = agentRoot(p)
            guard root != nil || p.ppid == 1 else { continue }
            let pids = tree(p.pid), i = treeIdle(pids)
            guard i >= mins(15), p.elapsed >= mins(15) else { continue }
            let title = headless
                ? "Headless browser" + (p.exe.contains("playwright") ? " (Playwright)" : p.exe.contains("puppeteer") ? " (Puppeteer)" : "")
                : "Dev server" + (ports[p.pid]?.min().map { " :\($0)" } ?? "") + " · " + (hint(p) ?? p.label.lowercased())
            let by = root.map { "started by \(who($0))" } ?? "whatever started it is gone"
            add("agent-\(p.pid)", .agent, title, "\(by) · idle \(dur(i))", pids)
        }
        for s in sessions {
            let pids = tree(s.pid), i = treeIdle(pids)
            guard i >= mins(60) else { continue }
            let resume = s.label == "Codex" ? "codex resume" : "claude --resume"
            add("session-\(s.pid)", .idle, "\(s.label) session" + (cwd[s.pid].map { " · \($0)" } ?? ""),
                "idle \(dur(i)) · pick it back up later with \(resume)", pids)
        }

        // orphans: reparented to launchd because the terminal / agent that started them closed
        let launchd = launchdPIDs()
        for p in mine where p.ppid == 1 && !claimed.contains(p.pid) && !launchd.contains(p.pid) && !systemish(p) {
            if p.base.hasPrefix("tmux") || p.base.hasPrefix("screen") { continue }
            let pids = tree(p.pid).filter { !claimed.contains($0) }
            let b = treeBytes(pids), i = treeIdle(pids)
            guard b >= 150 * 1_048_576, i >= mins(10), p.elapsed >= mins(10),
                  let big = pids.compactMap({ procs[$0] }).max(by: { $0.bytes < $1.bytes }) else { continue }
            add("orphan-\(p.pid)", .ghost, big.label + (hint(big).map { " · \($0)" } ?? ""),
                "its terminal or agent closed · idle \(dur(i)), running \(dur(p.elapsed))", pids)
        }

        // anything else big that's been sitting idle
        for p in mine where !claimed.contains(p.pid) && !shells.contains(p.base) && !agentLabels.contains(p.label) && !systemish(p) {
            if let par = procs[p.ppid], par.label == p.label { continue }
            let pids = tree(p.pid).filter { !claimed.contains($0) }
            let b = treeBytes(pids), i = treeIdle(pids)
            guard b >= 500 * 1_048_576, i >= mins(30) else { continue }
            add("idle-\(p.pid)", .idle, p.label + (hint(p).map { " · \($0)" } ?? ""), "using \(size(b)), no activity for \(dur(i))", pids)
        }

        var g: [String: Double] = [:]
        for p in procs.values { g[p.label, default: 0] += p.bytes }
        let apps = g.map { (name: $0.key, gb: $0.value / 1_073_741_824) }.filter { $0.gb >= 0.2 }.sorted { $0.gb > $1.gb }
        _ = labels
        return Scan(apps: Array(apps.prefix(6)), findings: found.sorted { $0.bytes > $1.bytes })
    }
}

func apply(_ f: Finding, wait: Bool) {
    switch f.fix {
    case .kill(let pids):
        let ok = pids.filter { $0 > 1 && pid_t($0) != getpid() }
        for p in ok.reversed() { kill(pid_t(p), SIGTERM) }
        let finish = { for p in ok where kill(pid_t(p), 0) == 0 { kill(pid_t(p), SIGKILL) } }
        if wait { Thread.sleep(forTimeInterval: 4); finish() }
        else { DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: finish) }
    case .quit(let app): run("/usr/bin/osascript", ["-e", "quit app \"\(app)\""])
    case .run(let path, let args): run(path, args)
    }
}

func fixText(_ apps: [(name: String, gb: Double)]) -> String {
    let names = Set(apps.map(\.name))
    if names.contains("Xcode") && names.contains("Android Studio") { return "Xcode + Android Studio are both open → quit one" }
    if names.contains("Android emulator") { return "Emulator is running → close it, test on your phone" }
    if names.contains("iOS Simulator") { return "iOS Simulator is open → quit it if you're on your phone" }
    if let top = apps.first { return "\(top.name) is the biggest → close what you're done with" }
    return "close what you're done with"
}

// MARK: - disk

// only known, rebuildable dev junk. never your files, xcode archives, or emulator images
enum JunkAction { case trash([URL]), run([(String, [String])]) }

struct Junk: Identifiable {
    let id: String, icon: String, title: String, detail: String, bytes: Double, action: JunkAction
    var blockedBy: String? = nil
    var trashes: Bool { if case .trash = action { return true }; return false }
}

enum Disk {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static func h(_ p: String) -> URL { home.appendingPathComponent(p) }

    static var free: Double {
        let v = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Double(v?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
    static var total: Double {
        let v = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey])
        return Double(v?.volumeTotalCapacity ?? 0)
    }

    static func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

    static func du(_ urls: [URL]) -> Double {
        let paths = urls.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return 0 }
        return run("/usr/bin/du", ["-sk"] + paths).out.split(separator: "\n")
            .compactMap { Double($0.split(separator: "\t").first ?? "") }.reduce(0, +) * 1024
    }

    static func modified(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    static func children(_ u: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles])) ?? []
    }

    // "2.3GB (45%)" -> bytes
    static func parseSize(_ s: Substring) -> Double {
        let t = s.split(separator: " ").first.map(String.init) ?? ""
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("B", 1)]
        for (u, m) in units where t.hasSuffix(u) { return (Double(t.dropLast(u.count)) ?? 0) * m }
        return 0
    }

    static func scan() -> [Junk] {
        var out: [Junk] = []
        let xcodeOpen = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode").isEmpty
        let quitXcode = xcodeOpen ? "quit Xcode first" : nil
        func add(_ id: String, _ icon: String, _ title: String, _ detail: String, _ urls: [URL], blocked: String? = nil) {
            let urls = urls.filter(exists)
            let b = du(urls)
            guard b >= 200 * 1_048_576 else { return }
            out.append(Junk(id: id, icon: icon, title: title, detail: detail, bytes: b, action: .trash(urls), blockedBy: blocked))
        }

        add("xcode-build", "🔨", "Xcode build files", "DerivedData · rebuilds on your next build",
            [h("Library/Developer/Xcode/DerivedData")], blocked: quitXcode)

        // device support: keep the newest version for each device model
        var old: [URL] = []
        for os in ["iOS", "watchOS", "tvOS", "visionOS"] {
            let byModel = Dictionary(grouping: children(h("Library/Developer/Xcode/\(os) DeviceSupport"))) {
                $0.lastPathComponent.split(separator: " ").first.map(String.init) ?? ""
            }
            for (_, dirs) in byModel { old += dirs.sorted { modified($0) > modified($1) }.dropFirst() }
        }
        add("device-support", "📲", "Old iOS device support", "versions your phone isn't on anymore · Xcode re-adds them if needed",
            old, blocked: quitXcode)

        // simulator runtimes: keep the newest per platform
        if let data = run("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"]).out.data(using: .utf8),
           let all = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            let rts = all.map { (id: $0.key, platform: $0.value["platformIdentifier"] as? String ?? "",
                                 version: $0.value["version"] as? String ?? "", size: ($0.value["sizeBytes"] as? NSNumber)?.doubleValue ?? 0) }
            var stale: [(id: String, platform: String, version: String, size: Double)] = []
            for (_, group) in Dictionary(grouping: rts, by: { $0.platform }) {
                stale += group.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }.dropFirst()
            }
            let bytes = stale.reduce(0) { $0 + $1.size }
            if bytes >= 200 * 1_048_576 {
                out.append(Junk(id: "sim-runtimes", icon: "📱", title: "Old simulator versions",
                                detail: stale.map { "iOS \($0.version)" }.sorted().joined(separator: ", ") + " · keeps your newest one",
                                bytes: bytes, action: .run(stale.map { ("/usr/bin/xcrun", ["simctl", "runtime", "delete", $0.id]) }),
                                blockedBy: quitXcode))
            }
        }
        add("sim-caches", "📱", "Simulator caches", "rebuild automatically", [h("Library/Developer/CoreSimulator/Caches")])

        add("gradle", "🐘", "Gradle caches", "re-download on your next Android build",
            [h(".gradle/caches"), h(".gradle/daemon"), h(".gradle/wrapper/dists")])
        add("js", "📦", "npm / yarn / bun caches", "re-download next time you install",
            [h(".npm/_cacache"), h("Library/Caches/Yarn"), h(".bun/install/cache")])
        add("python", "🐍", "pip / uv caches", "re-download next time you install", [h("Library/Caches/pip"), h(".cache/uv")])
        add("brew", "🍺", "Homebrew / CocoaPods / SwiftPM caches", "old downloads",
            [h("Library/Caches/Homebrew"), h("Library/Caches/CocoaPods"), h("Library/Caches/org.swift.swiftpm")])
        add("test-browsers", "🧪", "Test browsers (Playwright / Puppeteer)", "reinstall with npx playwright install",
            [h("Library/Caches/ms-playwright"), h(".cache/puppeteer")])
        add("hf", "🤗", "Hugging Face models", "download again if a script needs them", [h(".cache/huggingface/hub")])

        // installers sitting in Downloads for over a week
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        let installers = children(h("Downloads")).filter { ["dmg", "pkg", "iso"].contains($0.pathExtension.lowercased()) && modified($0) < weekAgo }
        add("installers", "💿", "Old installers in Downloads", "\(installers.count) .dmg / .pkg files, older than a week", installers)

        // node_modules in projects nobody has touched in a month
        let monthAgo = Date().addingTimeInterval(-30 * 86400)
        let found = run("/usr/bin/find", [home.path, "-maxdepth", "5", "(", "-path", h("Library").path, "-o", "-name", ".*", ")", "-prune",
                                         "-o", "-type", "d", "-name", "node_modules", "-print", "-prune"]).out
        let stale = found.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }.filter { nm in
            let project = nm.deletingLastPathComponent()
            let last = ([project] + children(project).filter { $0.lastPathComponent != "node_modules" }).map(modified).max() ?? .distantPast
            return last < monthAgo
        }
        add("node-modules", "📦", "Old node_modules", "\(stale.count) projects untouched for 30+ days · npm install brings them back", stale)

        // docker: whatever it says is reclaimable
        if let cli = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let r = run(cli, ["system", "df", "--format", "{{.Reclaimable}}"])
            let bytes = r.status == 0 ? r.out.split(separator: "\n").map(parseSize).reduce(0, +) : 0
            if bytes >= 200 * 1_048_576 {
                out.append(Junk(id: "docker", icon: "🐳", title: "Docker leftovers", detail: "stopped containers, unused images, build cache",
                                bytes: bytes, action: .run([(cli, ["system", "prune", "-f"])])))
            }
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    static func clean(_ j: Junk) {
        switch j.action {
        case .trash(let urls): for u in urls { try? FileManager.default.trashItem(at: u, resultingItemURL: nil) }
        case .run(let cmds): for (path, args) in cmds { run(path, args) }
        }
    }
}

// MARK: - health

enum Health {
    case ok, falling, tight, critical
    var word: String { ["healthy", "dropping fast", "getting tight", "critical"][index] }
    var dot: String { ["🟢", "🟠", "🟡", "🔴"][index] }
    var color: Color { [Color.green, .orange, .yellow, .red][index] }
    var ansi: String { ["\u{1B}[32m", "\u{1B}[38;5;208m", "\u{1B}[33m", "\u{1B}[31m"][index] }
    private var index: Int { switch self { case .ok: 0; case .falling: 1; case .tight: 2; case .critical: 3 } }

    static func of(free: Int, level: Int, minutesToRed: Double?) -> Health {
        if level >= 4 || free <= 8 { return .critical }
        if level >= 2 || free <= 15 { return .tight }
        if let m = minutesToRed, m <= 5 { return .falling }
        return .ok
    }
}

// MARK: - notifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var handlers: [String: () -> Void] = [:]
    private var categories: [UNNotificationCategory] = []
    private var allowed = false

    func setup() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in self.allowed = ok }
    }

    func post(_ title: String, _ subtitle: String, _ body: String, button: String? = nil, action: (() -> Void)? = nil) {
        guard allowed else {
            // no permission: plain notification, no button
            let esc = { (s: String) in s.replacingOccurrences(of: "\"", with: "'") }
            run("/usr/bin/osascript", ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\" subtitle \"\(esc(subtitle))\" sound name \"Submarine\""])
            return
        }
        let c = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title; content.subtitle = subtitle; content.body = body; content.sound = .default
        if let button, let action {
            // action titles are fixed per category, so each "Free 2.1 GB" button gets its own category
            let id = UUID().uuidString
            categories = Array((categories + [UNNotificationCategory(identifier: id, actions: [UNNotificationAction(identifier: "free", title: button)],
                                                                    intentIdentifiers: [])]).suffix(8))
            c.setNotificationCategories(Set(categories))
            content.categoryIdentifier = id
            handlers[id] = action
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            c.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        if r.actionIdentifier == "free", let h = handlers[r.notification.request.content.categoryIdentifier] { DispatchQueue.main.async(execute: h) }
        done()
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}

// MARK: - model

final class Model: ObservableObject {
    static let shared = Model()
    @Published var free = 100
    @Published var level = 1
    @Published var swap = 0.0
    @Published var scan = Scan()
    @Published var perMin = 0.0
    @Published var minutesToRed: Double?
    @Published var toast: String?
    @Published var busy: Set<String> = []
    @Published var muted = UserDefaults.standard.bool(forKey: "muted") {
        didSet { UserDefaults.standard.set(muted, forKey: "muted") }
    }
    private var bleat: NSSound?

    // the little baa when Free actually frees something
    func baa() {
        guard !muted, let url = Bundle.main.url(forResource: "baa", withExtension: "wav") else { return }
        bleat = NSSound(contentsOf: url, byReference: true)
        bleat?.play()
    }

    var health: Health { .of(free: free, level: level, minutesToRed: minutesToRed) }
    private let engine = Engine()
    private let q = DispatchQueue(label: "baa.scan")
    private var history: [(at: Date, free: Int)] = []
    private var lastPing: (at: Date, level: Int)?
    private var trendPing: Date?
    private var ghostPings: [String: Date] = [:]
    @Published var junk: [Junk] = []
    @Published var diskFree = 0.0
    var diskTotal = 0.0
    private var lastDiskScan: Date?
    private var diskPing: Date?
    private let dq = DispatchQueue(label: "baa.disk")

    func start() {
        Notifier.shared.setup()
        DistributedNotificationCenter.default().addObserver(forName: .init("com.selvi.baa.test"), object: nil, queue: .main) { _ in self.test() }
        tick(); rescan()
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in self.tick() }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in self.rescan() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.diskScan() }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in self.diskScan() }
    }

    private func tick() {
        free = Mem.freePct; level = Mem.level; swap = Mem.swapGB
        let now = Date()
        history.append((now, free))
        history.removeAll { now.timeIntervalSince($0.at) > 180 }
        trend()
        pressurePing()
    }

    // least-squares slope over the last 3 min, in % free per minute
    private func trend() {
        guard history.count >= 8, let t0 = history.first?.at else { perMin = 0; minutesToRed = nil; return }
        let xs = history.map { $0.at.timeIntervalSince(t0) / 60 }, ys = history.map { Double($0.free) }
        let n = Double(xs.count), mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let den = zip(xs, xs).map { ($0 - mx) * ($1 - mx) }.reduce(0, +)
        perMin = den > 0 ? zip(xs, ys).map { ($0 - mx) * ($1 - my) }.reduce(0, +) / den : 0
        minutesToRed = (perMin < -1.5 && free > 15) ? Double(free - 15) / -perMin : nil
    }

    func rescan(then: (() -> Void)? = nil) {
        q.async {
            let s = self.engine.scan()
            DispatchQueue.main.async { self.scan = s; self.ghostPing(); then?() }
        }
    }

    private var subtitle: String {
        scan.apps.prefix(3).map { "\($0.name) \(String(format: "%.1f", $0.gb)) GB" }.joined(separator: "  ·  ")
    }

    private func pingWithBestFix(_ title: String) {
        if let f = scan.findings.first {
            Notifier.shared.post(title, subtitle, "\(f.title): \(f.detail)", button: f.freeLabel) { self.free(f.id) }
        } else {
            Notifier.shared.post(title, subtitle, fixText(scan.apps))
        }
    }

    private func pressurePing() {
        let now = Date(), h = health
        if h == .tight || h == .critical {
            if let l = lastPing, level <= l.level, now.timeIntervalSince(l.at) < 1800 { return }
            lastPing = (now, level)
            pingWithBestFix("\(h.dot) RAM \(h.word) · \(free)% free")
        } else {
            lastPing = nil
            if h == .falling, let m = minutesToRed, trendPing.map({ now.timeIntervalSince($0) > 600 }) ?? true {
                trendPing = now
                pingWithBestFix("🟠 RAM dropping fast · red in ~\(max(1, Int(m.rounded()))) min")
            }
        }
    }

    // big leftovers get one heads-up every 6h, even when RAM is fine
    private func ghostPing() {
        let now = Date()
        guard let f = scan.findings.first(where: { $0.kind != .idle && $0.bytes >= 1_073_741_824 &&
                                                   ghostPings[$0.id].map { now.timeIntervalSince($0) > 6 * 3600 } ?? true }) else { return }
        ghostPings[f.id] = now
        Notifier.shared.post("👻 \(f.title) is still running", f.detail, "Holding \(size(f.bytes)) you could have back", button: f.freeLabel) { self.free(f.id) }
    }

    private func test() {
        let h = health
        rescan { self.pingWithBestFix("\(h.dot) RAM \(h.word) · \(self.free)% free") }
    }

    func free(_ id: String) {
        busy.insert(id)
        q.async {
            let before = Double(Mem.freePct)
            guard let f = self.engine.scan().findings.first(where: { $0.id == id }) else {
                DispatchQueue.main.async { self.busy.remove(id); self.rescan() }
                return
            }
            apply(f, wait: true)
            _ = before
            DispatchQueue.main.async {
                self.busy.remove(id)
                self.baa()
                self.flash("Freed \(size(f.bytes)) · \(f.title)")
                self.tick(); self.rescan()
            }
        }
    }

    func freeAll() {
        let ids = scan.findings.map(\.id), total = scan.freeable
        busy.formUnion(ids)
        q.async {
            let fs = self.engine.scan().findings.filter { ids.contains($0.id) }
            fs.forEach { apply($0, wait: false) }
            Thread.sleep(forTimeInterval: 4.5)
            DispatchQueue.main.async {
                self.busy.subtract(ids)
                if !ids.isEmpty { self.baa() }
                self.flash("Freed \(size(total))")
                self.tick(); self.rescan()
            }
        }
    }

    // disk junk: scanned in the background every 6h (and when you open the menu, if stale)
    func diskScan(ifOlderThan age: TimeInterval = 0) {
        if let l = lastDiskScan, Date().timeIntervalSince(l) < age { return }
        lastDiskScan = Date()
        dq.async {
            let j = Disk.scan(), free = Disk.free, total = Disk.total
            DispatchQueue.main.async {
                self.junk = j; self.diskFree = free; self.diskTotal = total
                self.diskLowPing()
            }
        }
    }

    // under 10% or 15 GB free -> one ping every 12h, with the biggest safe cleanup on it
    private func diskLowPing() {
        let now = Date()
        guard diskTotal > 0, diskFree < max(diskTotal * 0.1, 15e9),
              diskPing.map({ now.timeIntervalSince($0) > 12 * 3600 }) ?? true else { return }
        diskPing = now
        let title = "💾 Disk almost full · \(size(diskFree)) left"
        if let j = junk.first(where: { $0.blockedBy == nil }) {
            Notifier.shared.post(title, "\(size(junk.reduce(0) { $0 + $1.bytes })) of dev junk you can clear", "\(j.title): \(j.detail)",
                                 button: "Clear \(size(j.bytes))") { self.clean(j.id) }
        } else {
            Notifier.shared.post(title, "", "open baa to see what you can clear")
        }
    }

    func clean(_ id: String) {
        busy.insert(id)
        dq.async {
            guard let j = Disk.scan().first(where: { $0.id == id }), j.blockedBy == nil else {
                DispatchQueue.main.async { self.busy.remove(id); self.diskScan() }
                return
            }
            Disk.clean(j)
            DispatchQueue.main.async {
                self.busy.remove(id)
                self.baa()
                self.flash(j.trashes ? "Moved \(size(j.bytes)) to the Trash · empty it to get the space back"
                                     : "Cleared \(size(j.bytes)) · \(j.title)")
                self.diskScan()
            }
        }
    }

    private func flash(_ s: String) {
        toast = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if self.toast == s { self.toast = nil } }
    }
}

// MARK: - menu

struct Bar: View {
    let fraction: Double, color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color.gradient).frame(width: max(4, g.size.width * min(1, fraction)))
            }
        }
    }
}

struct Section_<Content: View>: View {
    let title: String, trailing: String?
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).kerning(0.6)
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
            }
            content
        }
    }
}

struct MenuView: View {
    @ObservedObject var m = Model.shared

    var trendText: String {
        if let t = m.minutesToRed { return String(format: "dropping %.0f%%/min · red in ~%d min", -m.perMin, max(1, Int(t.rounded()))) }
        if m.perMin < -1.5 { return String(format: "dropping %.0f%%/min", -m.perMin) }
        if m.perMin > 1.5 { return "recovering" }
        return "steady"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // header
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Circle().fill(m.health.color).frame(width: 9, height: 9)
                    Text("RAM").font(.system(size: 15, weight: .bold))
                    Text(m.health.word).font(.system(size: 15, weight: .medium)).foregroundStyle(m.health.color)
                    Spacer()
                    Text("\(m.free)% free").font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                }
                Bar(fraction: Double(100 - m.free) / 100, color: m.health.color).frame(height: 8)
                HStack {
                    Text(trendText)
                    Spacer()
                    Text(String(format: "swap %.1f GB", m.swap)).monospacedDigit()
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section_(title: "USING THE MOST", trailing: nil) {
                let top = m.scan.apps.first?.gb ?? 1
                ForEach(m.scan.apps, id: \.name) { a in
                    HStack(spacing: 10) {
                        Text(a.name).font(.system(size: 12)).lineLimit(1).frame(width: 118, alignment: .leading)
                        Bar(fraction: a.gb / top, color: m.health.color.opacity(0.75)).frame(height: 6)
                        Text(String(format: "%.1f GB", a.gb)).font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
                    }
                }
            }

            Section_(title: "LEFTOVERS", trailing: m.scan.findings.isEmpty ? nil : "\(size(m.scan.freeable)) to free") {
                if m.scan.findings.isEmpty {
                    Text("Nothing to headbutt ✨").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ForEach(m.scan.findings) { f in
                        HStack(alignment: .center, spacing: 10) {
                            Text(f.kind == .ghost ? "👻" : f.kind == .agent ? "🤖" : "💤").font(.system(size: 14))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(f.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Spacer(minLength: 6)
                            Button { m.free(f.id) } label: {
                                Text(m.busy.contains(f.id) ? "Freeing…" : f.freeLabel).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            }
                            .buttonStyle(.borderedProminent).controlSize(.small).tint(f.kind == .idle ? .gray : .accentColor)
                            .disabled(m.busy.contains(f.id))
                            .fixedSize().layoutPriority(1)
                        }
                    }
                }
            }

            Section_(title: "DISK", trailing: m.diskTotal > 0 ? "\(size(m.diskFree)) free" + (m.junk.isEmpty ? "" : " · \(size(m.junk.reduce(0) { $0 + $1.bytes })) junk") : nil) {
                if m.junk.isEmpty {
                    Text(m.diskTotal > 0 ? "No dev junk piling up ✨" : "Checking…").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ForEach(m.junk.prefix(5)) { j in
                        HStack(alignment: .center, spacing: 10) {
                            Text(j.icon).font(.system(size: 14))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(j.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(j.blockedBy ?? j.detail).font(.system(size: 11))
                                    .foregroundStyle(j.blockedBy == nil ? Color.secondary : Color.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Spacer(minLength: 6)
                            Button { m.clean(j.id) } label: {
                                Text(m.busy.contains(j.id) ? "Clearing…" : "\(j.trashes ? "Trash" : "Clear") \(size(j.bytes))")
                                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(m.busy.contains(j.id) || j.blockedBy != nil)
                            .fixedSize().layoutPriority(1)
                        }
                    }
                    if m.junk.count > 5 {
                        Text("+\(m.junk.count - 5) more · run baa disk").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }

            if let t = m.toast {
                Text("✓ \(t)").font(.system(size: 12, weight: .medium)).foregroundStyle(.green)
            }

            Divider()
            HStack {
                if m.scan.findings.count > 1 {
                    Button("Free all · \(size(m.scan.freeable))") { m.freeAll() }.buttonStyle(.bordered).controlSize(.small)
                }
                Spacer()
                Button { m.muted.toggle() } label: {
                    Image(systemName: m.muted ? "speaker.slash" : "speaker.wave.2").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(m.muted ? "baa sound off" : "baa sound on")
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { m.rescan(); m.diskScan(ifOlderThan: 15 * 60) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) { Model.shared.start() }
}

struct BaaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var m = Model.shared
    var body: some Scene {
        MenuBarExtra {
            MenuView()
        } label: {
            if m.health == .ok { Text("🐏 \(m.free)%") }
            else { Text("\(m.health.dot) \(m.free)%") }
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - terminal

enum CLI {
    static func run(_ cmd: String, _ rest: [String]) {
        switch cmd {
        case "--now", "now": now()
        case "--test", "test":
            DistributedNotificationCenter.default().postNotificationName(.init("com.selvi.baa.test"), object: nil, userInfo: nil, deliverImmediately: true)
            print("sent a test notification (Baa needs to be running in the menu bar)")
        case "--free", "free": free(rest.first ?? "")
        case "disk": disk(rest)
        case "snapshot": snapshot(rest.first { !$0.hasPrefix("--") } ?? "baa.png", dark: rest.contains("--dark"), demo: rest.contains("--demo"))
        default:
            print("baa                  RAM readout + leftovers\nbaa free <id>        free one leftover (or 'all')\nbaa disk             dev junk taking up disk\nbaa disk clean <id>  clear one (or 'all')\nbaa test             sample notification")
        }
    }

    static func now() {
        let s = Engine().scan(), free = Mem.freePct, h = Health.of(free: free, level: Mem.level, minutesToRed: nil)
        let c = h.ansi, g = "\u{1B}[90m", b = "\u{1B}[1m", r = "\u{1B}[0m"
        let used = 100 - free, fill = used / 5
        print("\n  \(b)RAM\(r)  \(h.dot) \(c)\(b)\(h.word)\(r)")
        print("  \(c)\(String(repeating: "█", count: fill))\(g)\(String(repeating: "░", count: 20 - fill))\(r)  \(b)\(used)% used\(r) \(g)· \(free)% free · swap \(String(format: "%.1f", Mem.swapGB)) GB\(r)\n")
        let top = s.apps.first?.gb ?? 1
        for a in s.apps {
            let n = max(1, Int((a.gb / top * 12).rounded()))
            let name = a.name.count > 18 ? String(a.name.prefix(17)) + "…" : a.name
            print("  \(name.padding(toLength: 19, withPad: " ", startingAt: 0))\(c)\(String(repeating: "▇", count: n))\(g)\(String(repeating: "·", count: 13 - n))\(r) \(String(format: "%5.1f", a.gb)) GB")
        }
        print("")
        if s.findings.isEmpty {
            print("  \(b)leftovers\(r)  \(g)nothing to headbutt ✨\(r)")
        } else {
            print("  \(b)leftovers\(r)  \(g)· \(size(s.freeable)) you can free\(r)")
            for f in s.findings {
                let icon = f.kind == .ghost ? "👻" : f.kind == .agent ? "🤖" : "💤"
                print("  \(icon) \(b)\(f.title)\(r)  \(c)\(size(f.bytes))\(r)")
                print("     \(g)\(f.detail)\(r)")
                print("     \(g)→ baa free \(f.id)\(r)")
            }
        }
        if h != .ok { print("\n  \(b)→\(r) \(fixText(s.apps))") }
        print("")
    }

    // draws the real menu panel (live data) to a png, for the readme
    static func snapshot(_ path: String, dark: Bool, demo: Bool = false) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let look = NSAppearance(named: dark ? .darkAqua : .aqua)
        app.appearance = look
        let m = Model.shared
        m.free = Mem.freePct; m.level = Mem.level; m.swap = Mem.swapGB
        m.scan = Engine().scan()
        m.junk = Disk.scan(); m.diskFree = Disk.free; m.diskTotal = Disk.total
        if demo {
            // sample leftovers for readme screenshots (same two baa caught for real while testing)
            m.scan.findings = [
                Finding(id: "demo-1", kind: .ghost, title: "Python · build_index.py", detail: "its terminal or agent closed · idle 12m, running 12m",
                        bytes: 404 * 1_048_576, fix: .kill([])),
                Finding(id: "demo-2", kind: .agent, title: "Dev server :3000 · python", detail: "started by Claude Code (my-app) · idle 12m",
                        bytes: 261 * 1_048_576, fix: .kill([])),
            ] + m.scan.findings
        }
        let panel = MenuView()
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            .padding(36)
        let host = NSHostingView(rootView: panel)
        host.appearance = look
        host.frame.size = host.fittingSize
        let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.appearance = look; win.backgroundColor = .clear; win.isOpaque = false
        win.contentView = host
        host.layoutSubtreeIfNeeded(); host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("couldn't render"); return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("saved \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
    }

    static func disk(_ rest: [String]) {
        let g = "\u{1B}[90m", b = "\u{1B}[1m", r = "\u{1B}[0m"
        let junk = Disk.scan()
        if rest.first == "clean" {
            let id = rest.dropFirst().first ?? ""
            let picks = id == "all" ? junk.filter { $0.blockedBy == nil } : junk.filter { $0.id == id }
            guard !picks.isEmpty else { print("nothing called '\(id)' right now. run baa disk to see ids"); return }
            for j in picks {
                if let why = j.blockedBy { print("skipped \(j.title): \(why)"); continue }
                Disk.clean(j)
                print(j.trashes ? "moved \(size(j.bytes)) to the Trash · \(j.title)" : "cleared \(size(j.bytes)) · \(j.title)")
            }
            if picks.contains(where: \.trashes) { print("\(g)empty the Trash to get the space back\(r)") }
            return
        }
        let total = Disk.total, free = Disk.free, used = total > 0 ? Int((1 - free / total) * 100) : 0
        let fill = used / 5
        print("\n  \(b)DISK\(r)  \(size(free)) free of \(size(total))")
        print("  \(String(repeating: "█", count: fill))\(g)\(String(repeating: "░", count: 20 - fill))\(r)  \(b)\(used)% used\(r)\n")
        if junk.isEmpty { print("  no dev junk piling up ✨\n"); return }
        print("  \(b)dev junk\(r)  \(g)· \(size(junk.reduce(0) { $0 + $1.bytes })) you can clear\(r)")
        for j in junk {
            print("  \(j.icon) \(b)\(j.title)\(r)  \(size(j.bytes))")
            print("     \(g)\(j.blockedBy.map { "⚠︎ " + $0 } ?? j.detail)\(r)")
            print("     \(g)→ baa disk clean \(j.id)\(r)")
        }
        print("")
    }

    static func free(_ id: String) {
        let s = Engine().scan()
        let fs = id == "all" ? s.findings : s.findings.filter { $0.id == id }
        guard !fs.isEmpty else { print("nothing called '\(id)' right now. run baa to see ids"); return }
        for f in fs { apply(f, wait: true); print("freed \(size(f.bytes)) · \(f.title)") }
    }
}

@main
struct Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if let cmd = args.first { CLI.run(cmd, Array(args.dropFirst())); return }
        BaaApp.main()
    }
}
