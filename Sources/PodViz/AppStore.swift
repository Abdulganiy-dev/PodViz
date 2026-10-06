import AppKit
import Observation
import PodVizCore

enum PodCommand {
    case install, update
}

@MainActor
@Observable
final class AppStore {
    static let shared = AppStore()

    var session: PodSession?
    var recentProjects: [String] = []
    var selectedProject: String?
    var repoUpdate = false { didSet { defaults.set(repoUpdate, forKey: "repoUpdate") } }
    var hasUnseenResult = false
    var notice: String?
    var cliInstalled = false

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var watcher: TerminalWatcher?
    @ObservationIgnored private var userStopped = false
    @ObservationIgnored private let defaults = UserDefaults.standard

    private init() {
        recentProjects = defaults.stringArray(forKey: "recentProjects") ?? []
        selectedProject = defaults.string(forKey: "selectedProject") ?? recentProjects.first
        repoUpdate = defaults.bool(forKey: "repoUpdate")
    }

    func boot() {
        PodVizPaths.bootstrap()
        cliInstalled = PodVizPaths.isCLIInstalled
        let watcher = TerminalWatcher()
        watcher.shouldAttach = { [weak self] session in self?.attach(session) ?? false }
        watcher.onFinish = { [weak self] session in self?.didFinish(session) }
        watcher.start()
        self.watcher = watcher
        Notifier.requestAuthorization()
        Task.detached { _ = await ShellEnvironment.shared.resolved() }
    }

    var isRunning: Bool { session?.isRunning == true }
    var canRun: Bool { !isRunning && selectedProject.map(Self.hasPodfile) == true }

    // MARK: - Projects

    func selectProject(_ url: URL?) {
        guard let url else { return }
        var path = url.standardizedFileURL.path
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        if !isDir.boolValue { path = (path as NSString).deletingLastPathComponent }
        // Flutter / React Native keep the Podfile in ios/.
        if !Self.hasPodfile(path), Self.hasPodfile(path + "/ios") { path += "/ios" }
        selectedProject = path
        recentProjects.removeAll { $0 == path }
        recentProjects.insert(path, at: 0)
        recentProjects = Array(recentProjects.prefix(8))
        defaults.set(recentProjects, forKey: "recentProjects")
        defaults.set(path, forKey: "selectedProject")
        notice = Self.hasPodfile(path) ? nil : "No Podfile in \(Self.displayName(path))"
    }

    func chooseFolder() {
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "Choose"
            panel.message = "Choose a project folder that contains a Podfile"
            if let current = self.selectedProject { panel.directoryURL = URL(fileURLWithPath: current) }
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK { self.selectProject(panel.url) }
        }
    }

    // MARK: - Running pod

    func run(_ command: PodCommand) {
        guard !isRunning, let project = selectedProject else { return }
        guard Self.hasPodfile(project) else {
            notice = "No Podfile in \(Self.displayName(project))"
            return
        }
        var args = command == .install ? ["install"] : ["update"]
        if repoUpdate && command == .install { args.append("--repo-update") }
        notice = nil
        userStopped = false
        hasUnseenResult = false
        let session = PodSession(origin: .app, projectPath: project, command: "pod " + args.joined(separator: " "))
        self.session = session
        startTicker()
        Task {
            let env = await ShellEnvironment.shared.resolved()
            guard self.session === session else { return }
            self.launch(session, args: args, env: env)
        }
    }

    private func launch(_ session: PodSession, args: [String], env: [String: String]) {
        let path = env["PATH"] ?? ""
        let project = session.projectPath
        let bundler = ShellEnvironment.usesBundler(project: project, path: path)
        guard bundler || ShellEnvironment.which("pod", path: path) != nil else {
            session.fail("Couldn't find `pod` on your PATH. Install CocoaPods (`brew install cocoapods`) and try again.")
            didFinish(session)
            return
        }
        var environment = env
        if !(environment["LANG"] ?? "").contains("UTF-8") { environment["LANG"] = "en_US.UTF-8" }
        environment["RUBYOPT"] = ["-r" + PodVizPaths.syncScript.path, environment["RUBYOPT"]]
            .compactMap { $0 }.joined(separator: " ")
        environment["TERM"] = "dumb"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = (bundler ? ["bundle", "exec", "pod"] : ["pod"]) + args + ["--verbose", "--no-ansi"]
        process.currentDirectoryURL = URL(fileURLWithPath: project)
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            session.fail("Couldn't start pod: \(error.localizedDescription)")
            didFinish(session)
            return
        }
        self.process = process
        LineReader.pump(pipe.fileHandleForReading, process: process,
                        onLines: { [weak session] lines in session?.ingest(lines) },
                        onExit: { [weak self, weak session] code in
                            guard let self, let session else { return }
                            session.finish(exitCode: code)
                            self.didFinish(session)
                        })
    }

    func stop() {
        guard let process, process.isRunning else { return }
        userStopped = true
        ProcessTree.terminate(process.processIdentifier)
    }

    func clearSession() {
        guard !isRunning else { return }
        session = nil
        hasUnseenResult = false
    }

    /// A `podviz` run started in Terminal. App-launched runs take priority.
    private func attach(_ terminalSession: PodSession) -> Bool {
        if let session, session.isRunning, session.origin == .app { return false }
        session = terminalSession
        hasUnseenResult = false
        startTicker()
        return true
    }

    private func didFinish(_ finished: PodSession) {
        guard session === finished else { return }
        process = nil
        hasUnseenResult = true
        if finished.origin == .terminal, Self.hasPodfile(finished.projectPath), finished.projectPath != selectedProject {
            selectProject(URL(fileURLWithPath: finished.projectPath))
        }
        if !userStopped { Notifier.post(for: finished) }
        userStopped = false
    }

    private func startTicker() {
        ticker?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let session = self.session, session.isRunning {
                    session.tick()
                } else {
                    self.ticker?.invalidate()
                    self.ticker = nil
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    // MARK: - Utilities

    func installCLI() {
        do {
            try PodVizPaths.installCLI()
            cliInstalled = true
            notice = "Installed. Run `podviz install` in any project."
        } catch {
            notice = error.localizedDescription
        }
    }

    func copyLog() {
        guard let session else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.log.joined(separator: "\n"), forType: .string)
    }

    func revealPods() {
        guard let path = session?.projectPath ?? selectedProject else { return }
        let pods = URL(fileURLWithPath: path).appendingPathComponent("Pods")
        let target = FileManager.default.fileExists(atPath: pods.path) ? pods : URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    static func hasPodfile(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path + "/Podfile")
    }

    /// "MyApp/ios" for Flutter / RN layouts, otherwise the folder name.
    static func displayName(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        if name == "ios" || name == "iOS" { return url.deletingLastPathComponent().lastPathComponent + "/" + name }
        return name
    }

    /// Distinct root pods recorded in Podfile.lock.
    static func lockedPodCount(_ path: String) -> Int? {
        guard let text = try? String(contentsOfFile: path + "/Podfile.lock", encoding: .utf8) else { return nil }
        var names = Set<String>()
        var inPods = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "PODS:" { inPods = true; continue }
            guard inPods else { continue }
            if line.hasPrefix("  - ") {
                let entry = line.dropFirst(4).split(separator: " ").first ?? ""
                names.insert(String(entry.split(separator: "/").first ?? entry).trimmingCharacters(in: CharacterSet(charactersIn: "\":")))
            } else if !line.hasPrefix("    ") {
                break
            }
        }
        return names.count
    }
}
