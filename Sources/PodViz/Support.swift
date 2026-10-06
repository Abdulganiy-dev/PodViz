import AppKit
import PodVizCore
import ServiceManagement
import UserNotifications

/// Files PodViz shares with the `podviz` terminal command, under ~/.podviz.
enum PodVizPaths {
    static let home = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".podviz")
    static var runsDir: URL { home.appendingPathComponent("runs") }
    static var syncScript: URL { home.appendingPathComponent("sync.rb") }
    static var cliScript: URL { home.appendingPathComponent("bin/podviz") }
    static var cliLink: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin/podviz") }

    static func bootstrap() {
        let fm = FileManager.default
        try? fm.createDirectory(at: runsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: cliScript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? syncRuby.write(to: syncScript, atomically: true, encoding: .utf8)
        try? cliSource.write(to: cliScript, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cliScript.path)
    }

    static var isCLIInstalled: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: cliLink.path)) == cliScript.path
    }

    static func installCLI() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: cliLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? fm.attributesOfItem(atPath: cliLink.path)) != nil {
            guard (try? fm.destinationOfSymbolicLink(atPath: cliLink.path)) != nil else {
                throw NSError(domain: "PodViz", code: 1, userInfo: [NSLocalizedDescriptionKey: "~/.local/bin/podviz already exists"])
            }
            try fm.removeItem(at: cliLink)
        }
        try fm.createSymbolicLink(at: cliLink, withDestinationURL: cliScript)
    }

    /// Loaded through RUBYOPT so CocoaPods flushes every line instead of buffering when piped.
    static let syncRuby = """
    # Loaded by PodViz via RUBYOPT so CocoaPods output streams line by line.
    $stdout.sync = true
    $stderr.sync = true

    """

    static let cliSource = #"""
    #!/bin/zsh
    # podviz: run CocoaPods and stream live progress to the PodViz menu bar app.
    #   podviz                      -> pod install
    #   podviz install --repo-update
    #   podviz update Alamofire
    emulate -L zsh

    PODVIZ_HOME="$HOME/.podviz"
    mkdir -p "$PODVIZ_HOME/runs"
    (( $# == 0 )) && set -- install

    log="$PODVIZ_HOME/runs/$(date +%Y%m%d-%H%M%S)-$$.log"
    {
      print -r -- "#PODVIZ cwd=$PWD"
      print -r -- "#PODVIZ cmd=pod $*"
      print -r -- "#PODVIZ pid=$$"
    } >| "$log"

    # Start the menu bar app in the background if it isn't running.
    pgrep -qx PodViz || open -g -b dev.podviz.PodViz 2>/dev/null

    pod_cmd=(pod)
    for gemfile in Gemfile ../Gemfile; do
      if [[ -f $gemfile && -f $gemfile.lock ]] && grep -q cocoapods $gemfile && (( $+commands[bundle] )); then
        pod_cmd=(bundle exec pod)
        break
      fi
    done

    [[ "${LANG:-}" == *UTF-8* ]] || export LANG=en_US.UTF-8
    export RUBYOPT="-r$PODVIZ_HOME/sync.rb${RUBYOPT:+ $RUBYOPT}"

    finish() { print -r -- "#PODVIZ exit=$1" >> "$log"; }
    trap 'finish 130; exit 130' INT TERM

    # The full verbose log goes to PodViz; the terminal skips the noisy CDN lines.
    "${pod_cmd[@]}" "$@" --verbose --no-ansi 2>&1 | tee -a "$log" | grep --line-buffered -v '^ *CDN: '
    code=${pipestatus[1]}
    finish $code
    exit $code

    """#
}

/// Login-shell environment, so `pod` resolves the same way it does in Terminal (Homebrew, rbenv, asdf, …).
actor ShellEnvironment {
    static let shared = ShellEnvironment()
    private var cached: [String: String]?

    func resolved() -> [String: String] {
        if let cached { return cached }
        var env = ProcessInfo.processInfo.environment
        var path = Self.loginShellPATH() ?? env["PATH"] ?? "/usr/bin:/bin"
        let home = NSHomeDirectory()
        let extras = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                      home + "/.rbenv/shims", home + "/.asdf/shims", home + "/.local/share/mise/shims", home + "/.rvm/bin"]
        let existing = Set(path.split(separator: ":").map(String.init))
        for dir in extras where !existing.contains(dir) { path += ":" + dir }
        env["PATH"] = path
        cached = env
        return env
    }

    nonisolated static func which(_ tool: String, path: String) -> String? {
        for dir in path.split(separator: ":") {
            let full = (String(dir) as NSString).expandingTildeInPath + "/" + tool
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
        return nil
    }

    /// React Native style projects pin CocoaPods in a Gemfile next to (or above) the Podfile.
    nonisolated static func usesBundler(project: String, path: String) -> Bool {
        guard which("bundle", path: path) != nil else { return false }
        for dir in [project, (project as NSString).deletingLastPathComponent] {
            let gemfile = dir + "/Gemfile"
            if FileManager.default.fileExists(atPath: gemfile + ".lock"),
               let text = try? String(contentsOfFile: gemfile, encoding: .utf8), text.contains("cocoapods") {
                return true
            }
        }
        return false
    }

    private nonisolated static func loginShellPATH() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let marker = "__PODVIZ_PATH__"
        let script = shell.hasSuffix("fish")
            ? "echo \(marker)(string join : $PATH)\(marker)"
            : "echo \"\(marker)$PATH\(marker)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", script]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        // Read until the marker shows up rather than to EOF: shell daemons (gitstatusd, …) can hold the pipe open.
        let box = Box<String?>(nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var data = Data()
            while true {
                let chunk = out.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                data.append(chunk)
                let text = String(decoding: data, as: UTF8.self)
                if let start = text.range(of: marker),
                   let end = text.range(of: marker, range: start.upperBound..<text.endIndex) {
                    box.value = String(text[start.upperBound..<end.lowerBound])
                    break
                }
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 8)
        if process.isRunning { process.terminate() }
        return box.value.flatMap { $0.isEmpty ? nil : $0 }
    }
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Streams a child's combined output to the main thread as whole lines, then reports the exit code.
enum LineReader {
    static func pump(_ handle: FileHandle, process: Process,
                     onLines: @escaping @MainActor ([String]) -> Void,
                     onExit: @escaping @MainActor (Int32) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                var lines: [String] = []
                var start = buffer.startIndex
                while let newline = buffer[start...].firstIndex(of: 0x0A) {
                    lines.append(String(decoding: buffer[start..<newline], as: UTF8.self))
                    start = buffer.index(after: newline)
                }
                buffer = Data(buffer[start...])
                if !lines.isEmpty {
                    DispatchQueue.main.async { MainActor.assumeIsolated { onLines(lines) } }
                }
            }
            if !buffer.isEmpty {
                let tail = String(decoding: buffer, as: UTF8.self)
                DispatchQueue.main.async { MainActor.assumeIsolated { onLines([tail]) } }
            }
            process.waitUntilExit()
            let status = process.terminationStatus
            let code = process.terminationReason == .uncaughtSignal ? 128 + status : status
            DispatchQueue.main.async { MainActor.assumeIsolated { onExit(code) } }
        }
    }
}

enum ProcessTree {
    /// SIGTERM a process and everything it spawned (git, curl, …).
    static func terminate(_ pid: pid_t) {
        var all: [pid_t] = []
        func collect(_ p: pid_t) {
            for child in children(of: p) { collect(child) }
            all.append(p)
        }
        collect(pid)
        for p in all { kill(p, SIGTERM) }
    }

    private static func children(of pid: pid_t) -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(pid)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
    }
}

enum Notifier {
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @MainActor
    static func post(for session: PodSession) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        let project = AppStore.displayName(session.projectPath)
        if session.phase == .done {
            content.title = "Pods installed · \(project)"
            content.body = session.summary
        } else {
            content.title = "\(session.command) failed · \(project)"
            content.body = session.errorMessage ?? "See the log in PodViz."
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: session.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: "enabled"
        case .requiresApproval: "requires approval in System Settings › General › Login Items"
        case .notRegistered: "not registered"
        case .notFound: "not found (run the copy in /Applications)"
        @unknown default: "unknown"
        }
    }

    /// `PodViz --login-item on|off|status`: change or print the login item, then quit.
    static func runCommandLineIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--login-item") else { return false }
        let action = flag + 1 < args.count ? args[flag + 1] : "status"
        if action == "on" || action == "off" { set(action == "on") }
        print("PodViz login item: \(statusText)")
        return true
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("PodViz: login item change failed: \(error)")
        }
    }
}

/// Follows ~/.podviz/runs, where the `podviz` terminal command tees `pod --verbose` output.
@MainActor
final class TerminalWatcher {
    var shouldAttach: (PodSession) -> Bool = { _ in true }
    var onFinish: (PodSession) -> Void = { _ in }

    private final class Tail {
        let url: URL
        let session: PodSession
        var offset: UInt64 = 0
        var partial = Data()
        var pid: pid_t?
        var lastAliveCheck = Date()
        init(url: URL, session: PodSession) {
            self.url = url
            self.session = session
        }
    }

    private var timer: Timer?
    private var seen: Set<String> = []
    private var tail: Tail?

    func start() {
        let files = Self.logFiles()
        for file in files { seen.insert(file.url.lastPathComponent) }
        // Pick up a run that started before the app launched (the podviz script opens the app).
        if let newest = files.first, Date().timeIntervalSince(newest.modified) < 120, !Self.hasExit(newest.url) {
            begin(newest.url, startedAt: newest.created)
        }
        for stale in files.dropFirst(20) { try? FileManager.default.removeItem(at: stale.url) }

        let t = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        if let tail { read(tail) }
        for file in Self.logFiles().reversed() where !seen.contains(file.url.lastPathComponent) {
            seen.insert(file.url.lastPathComponent)
            begin(file.url, startedAt: file.created)
        }
    }

    private func begin(_ url: URL, startedAt: Date) {
        let session = PodSession(origin: .terminal, projectPath: NSHomeDirectory(), command: "pod install", startedAt: startedAt)
        guard shouldAttach(session) else { return }
        let t = Tail(url: url, session: session)
        tail = t
        read(t)
    }

    private func read(_ t: Tail) {
        guard let handle = try? FileHandle(forReadingFrom: t.url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: t.offset)
        let data = (try? handle.readToEnd()) ?? Data()
        if !data.isEmpty {
            t.offset += UInt64(data.count)
            t.partial.append(data)
            var lines: [String] = []
            var start = t.partial.startIndex
            while let newline = t.partial[start...].firstIndex(of: 0x0A) {
                lines.append(String(decoding: t.partial[start..<newline], as: UTF8.self))
                start = t.partial.index(after: newline)
            }
            t.partial = Data(t.partial[start...])
            for line in lines where line.hasPrefix("#PODVIZ pid=") {
                t.pid = pid_t(line.dropFirst("#PODVIZ pid=".count))
            }
            t.session.ingest(lines)
        } else if t.session.isRunning, Date().timeIntervalSince(t.lastAliveCheck) > 2 {
            t.lastAliveCheck = Date()
            // The terminal was closed without the script recording an exit code.
            if let pid = t.pid, kill(pid, 0) != 0, errno == ESRCH { t.session.finish(exitCode: 130) }
        }
        if !t.session.isRunning {
            tail = nil
            onFinish(t.session)
        }
    }

    private struct LogFile {
        let url: URL
        let modified: Date
        let created: Date
    }

    /// Newest first.
    private static func logFiles() -> [LogFile] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: PodVizPaths.runsDir, includingPropertiesForKeys: keys)) ?? []
        return urls.filter { $0.pathExtension == "log" }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return LogFile(url: url, modified: values?.contentModificationDate ?? .distantPast,
                           created: values?.creationDate ?? .distantPast)
        }
        .sorted { $0.modified > $1.modified }
    }

    private static func hasExit(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 512 ? size - 512 : 0)
        let tail = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        return tail.contains("#PODVIZ exit=")
    }
}
