import Foundation
import Observation

/// Live state of one `pod install` / `pod update` run, built up line by line from its verbose output.
@MainActor
@Observable
public final class PodSession: Identifiable {
    public enum Origin: String, Sendable { case app, terminal }

    public let id = UUID()
    public let origin: Origin
    public private(set) var projectPath: String
    public private(set) var command: String
    public let startedAt: Date
    public private(set) var endedAt: Date?
    public private(set) var exitCode: Int32?
    public private(set) var phase: Phase = .preparing
    public private(set) var failedDuring: Phase?
    public private(set) var activity = "Starting…"
    public private(set) var pods: [PodItem] = []
    public private(set) var requests: [NetRequest] = []
    public private(set) var requestCounts: [RequestKind: Int] = [:]
    public private(set) var cdnBytes: Int64 = 0
    public private(set) var localCacheHits = 0
    public private(set) var warnings: [String] = []
    public private(set) var errorMessage: String?
    public private(set) var log: [String] = []
    public private(set) var currentPod: String?
    public private(set) var sawManifest = false
    public private(set) var podfileDependencies: Int?
    public private(set) var podsFolderBytes: Int64?
    public private(set) var bytesPerSecond: Double = 0
    /// CocoaPods' `parallel_pod_downloads` option is on: downloads run in a thread pool before the install loop.
    public private(set) var parallelDownloads = false

    @ObservationIgnored private var podIndex: [String: Int] = [:]
    @ObservationIgnored private var running: Set<Int> = []
    @ObservationIgnored private var completeTransfers: Set<Int> = []
    /// Parallel mode: pods queued for download, in order, and those already matched to a transfer.
    @ObservationIgnored private var downloadQueue: [String] = []
    @ObservationIgnored private var claimed: Set<String> = []
    @ObservationIgnored private var specSources: [String: PodspecSource] = [:]
    @ObservationIgnored private var inManifest = false
    @ObservationIgnored private var preDownloadPod: String?
    @ObservationIgnored private var redirects: [String: String] = [:]
    @ObservationIgnored private var measuring: Set<String> = []
    @ObservationIgnored private var speedSamples: [(at: Date, bytes: Int64)] = []
    @ObservationIgnored private var lastBang: String?
    @ObservationIgnored private var frozenProgress = 0.0
    @ObservationIgnored private let maxLogLines = 5000

    public static let trunkCDN = "https://cdn.cocoapods.org/"

    nonisolated static var reposRoot: String {
        ProcessInfo.processInfo.environment["CP_REPOS_DIR"] ?? (NSHomeDirectory() + "/.cocoapods/repos")
    }

    public init(origin: Origin, projectPath: String, command: String, startedAt: Date = Date()) {
        self.origin = origin
        self.projectPath = projectPath
        self.command = command
        self.startedAt = startedAt
    }

    // MARK: - Derived values

    public var isRunning: Bool { endedAt == nil }

    public var plannedCount: Int { pods.reduce(0) { $0 + ($1.isPlanned ? 1 : 0) } }

    public var installedCount: Int {
        pods.reduce(0) { $0 + ($1.isPlanned && ($1.status == .done || $1.status == .cached) ? 1 : 0) }
    }

    public var totalPodCount: Int { pods.reduce(0) { $0 + ($1.change == .removed ? 0 : 1) } }

    /// Network bytes: spec files from the CDN plus pod sources (git packs, archives).
    public var downloadedBytes: Int64 {
        let podBytes = pods.reduce(Int64(0)) { $0 + $1.downloadBytes }
        let unowned = requests.reduce(Int64(0)) { $0 + ($1.kind != .cdn && $1.pod == nil ? ($1.bytes ?? 0) : 0) }
        return cdnBytes + podBytes + unowned
    }

    public var diskBytes: Int64 { pods.reduce(Int64(0)) { $0 + ($1.diskBytes ?? 0) } }

    public var hasSizes: Bool { pods.contains { $0.displayBytes > 0 } }

    public func elapsed(at now: Date = Date()) -> TimeInterval { (endedAt ?? now).timeIntervalSince(startedAt) }

    /// 0…1, weighted by phase so the bar keeps moving through resolution and project generation.
    public var progress: Double {
        switch phase {
        case .preparing: return 0.02
        case .analyzing: return min(0.14, 0.04 + Double(requests.count) * 0.0002)
        case .downloading:
            let total = max(totalPodCount, 1)
            var done = 0.0
            for pod in pods where pod.change != .removed {
                switch pod.status {
                case .done, .cached, .upToDate, .failed: done += 1
                case .downloading, .installing: done += 0.4
                default: break
                }
            }
            return 0.15 + 0.7 * min(done / Double(total), 1)
        case .generating: return 0.88
        case .integrating: return 0.95
        case .done: return 1
        case .failed: return frozenProgress
        }
    }

    public var menuBarText: String {
        switch phase {
        case .preparing, .analyzing: "Resolving"
        case .downloading: plannedCount > 0 ? "\(installedCount)/\(plannedCount)" : "\(Int(progress * 100))%"
        case .generating: "Generating"
        case .integrating: "Integrating"
        case .done: "Done"
        case .failed: "Failed"
        }
    }

    public var summary: String {
        let time = Self.durationText(elapsed())
        if plannedCount == 0 && sawManifest {
            return "All \(totalPodCount) pods already up to date · \(time)"
        }
        let n = plannedCount
        return "Installed \(installedCount) of \(n) \(n == 1 ? "pod" : "pods") in \(time)"
    }

    // MARK: - Input

    public func ingest(_ lines: [String]) {
        for line in lines { ingest(line) }
    }

    public func ingest(_ raw: String) {
        let line = LineParser.clean(raw)
        let event = LineParser.parse(line)
        if case .meta = event {} else { appendLog(line) }
        apply(event)
    }

    /// Call about once a second while running: samples in-flight downloads and the transfer rate.
    public func tick(now: Date = Date()) {
        guard isRunning else { return }
        for idx in running { sampleRequest(idx) }
        let total = downloadedBytes
        speedSamples.append((now, total))
        speedSamples.removeAll { now.timeIntervalSince($0.at) > 4 }
        if let first = speedSamples.first, now.timeIntervalSince(first.at) >= 0.9 {
            bytesPerSecond = max(0, Double(total - first.bytes) / now.timeIntervalSince(first.at))
        } else {
            bytesPerSecond = 0
        }
    }

    public func fail(_ message: String) {
        lastBang = message
        finish(exitCode: 127)
    }

    public func finish(exitCode code: Int32) {
        guard endedAt == nil else { return }
        if code != 0, let name = currentPod, let i = podIndex[name] {
            pods[i].status = .failed
            pods[i].finishedAt = Date()
            currentPod = nil
        }
        closeCurrentPod()
        closePreDownload()
        finishRequests(owner: nil, all: true, state: code == 0 ? .ok : .failed)
        exitCode = code
        bytesPerSecond = 0
        if code == 0 {
            phase = .done
            endedAt = Date()
            activity = summary
        } else {
            frozenProgress = progress
            failedDuring = phase
            phase = .failed
            endedAt = Date()
            for i in pods.indices where pods[i].status.isActive { pods[i].status = .failed }
            errorMessage = lastBang ?? "pod exited with status \(code)"
            activity = (code == 130 || code == 143) ? "Stopped" : "Installation failed"
        }
        let podsDir = projectPath + "/Pods"
        measure(podsDir) { [weak self] size in self?.podsFolderBytes = size }
    }

    // MARK: - Event handling

    private func appendLog(_ line: String) {
        log.append(line)
        if log.count > maxLogLines + 500 { log.removeFirst(500) }
    }

    private func apply(_ event: LogEvent) {
        switch event {
        case .blank, .other:
            break

        case let .meta(key, value):
            switch key {
            case "cwd": projectPath = value
            case "cmd": command = value
            case "exit": finish(exitCode: Int32(value) ?? 1)
            default: break
            }

        case let .section(newPhase, text):
            inManifest = false
            closePreDownload()
            if let newPhase {
                if newPhase != .downloading { closeCurrentPod() }
                if newPhase > phase { phase = newPhase }
            }
            activity = text

        case .comparingStart:
            inManifest = true
            sawManifest = true
            activity = "Comparing with installed pods"

        case let .manifestLine(change, name):
            guard inManifest else { return }
            let i = upsert(name)
            pods[i].change = change
            pods[i].status = change == .removed ? .removed : .queued

        case let .podSection(action, name, version, previous):
            guard phase == .downloading else { return }
            inManifest = false
            if action != .downloading { closeCurrentPod() }
            let i = upsert(name)
            if let version { pods[i].version = version }
            if let previous { pods[i].previousVersion = previous }
            switch action {
            case .downloading:
                // Parallel mode prints every title up front, then a thread pool works through the queue.
                // Output from those threads doesn't name the pod, so remember each pod's source to match it.
                parallelDownloads = true
                pods[i].status = .queued
                if !downloadQueue.contains(name) { downloadQueue.append(name) }
                if specSources[name] == nil,
                   let source = PodspecSource.lookup(name: name, version: pods[i].version, projectPath: projectPath) {
                    specSources[name] = source
                }
                activity = "Queued \(downloadQueue.count) pods for parallel download"
            case .installing:
                if pods[i].change == .unknown { pods[i].change = previous == nil ? .added : .changed }
                // Already downloaded and copied into Pods/ by the parallel pass.
                if pods[i].status != .done && pods[i].status != .cached { pods[i].status = .installing }
                pods[i].startedAt = pods[i].startedAt ?? Date()
                currentPod = name
                activity = "Installing \(name)"
            case .using:
                if pods[i].change == .unknown { pods[i].change = .unchanged }
                pods[i].status = .upToDate
                measureDisk(name)
            }

        case let .removing(name):
            let i = upsert(name)
            pods[i].change = .removed
            pods[i].status = .removed
            activity = "Removing \(name)"

        case let .downloader(kind):
            guard let name = currentPod ?? preDownloadPod, let i = podIndex[name] else { return }
            pods[i].source = kind
            pods[i].status = .downloading
            activity = "Downloading \(name) via \(kind.label)"

        case let .copying(name, from):
            let i = upsert(name)
            if pods[i].source == .unknown { pods[i].source = .cache }
            pods[i].cachePath = from
            if pods[i].status == .downloading { pods[i].status = .installing }
            let transfers = requests.indices.suffix(20).filter { requests[$0].pod == name && requests[$0].kind != .cdn }
            finishRequests(owner: name)
            if pods[i].source.isRemote, !transfers.contains(where: completeTransfers.contains) {
                // A fast transfer finished between samples and its temp dir is gone by now;
                // the cleaned cache copy is the best remaining estimate.
                measure(from) { [weak self] size in
                    guard let self, let size, let j = self.podIndex[name] else { return }
                    self.pods[j].downloadBytes = max(self.pods[j].downloadBytes, size)
                    if let last = transfers.last { self.requests[last].bytes = max(self.requests[last].bytes ?? 0, size) }
                }
            }
            activity = pods[i].source == .cache ? "Copying \(name) from cache" : "Installing \(name)"
            if parallelDownloads && currentPod == nil && phase == .downloading {
                claimed.insert(name)
                pods[i].status = pods[i].source == .cache ? .cached : .done
                pods[i].finishedAt = Date()
                measureDisk(name)
                activity = parallelActivity
            }

        case let .command(executable, args):
            handleCommand(executable, args)

        case let .cdn(source, cdnEvent):
            handleCDN(source, cdnEvent)

        case let .preDownload(name):
            closePreDownload()
            preDownloadPod = name
            let i = upsert(name)
            pods[i].status = .downloading
            pods[i].startedAt = Date()
            activity = "Pre-downloading \(name)"

        case let .failedCommand(command):
            if let idx = running.max() {
                requests[idx].state = .failed
                requests[idx].finishedAt = Date()
                running.remove(idx)
            }
            lastBang = "Failed: \(command)"

        case let .bang(message):
            lastBang = message
            if warnings.count < 50 { warnings.append(message) }

        case let .complete(dependencies, _):
            podfileDependencies = dependencies
            closeCurrentPod()
            phase = .done
            activity = "Pod installation complete"
        }
    }

    private func handleCommand(_ executable: String, _ args: [String]) {
        let tool = (executable as NSString).lastPathComponent
        var owner = currentPod ?? preDownloadPod
        // A command on a running transfer's files (`git -C <dir>`, `unzip <archive>`) belongs to that transfer.
        let pathMatch = running.sorted().first { idx in requests[idx].localPath.map(args.contains) ?? false }
        if owner == nil, let pathMatch { owner = requests[pathMatch].pod }
        switch tool {
        case "git":
            // Any git command (even rev-parse) means the previous transfer for this pod has landed.
            for idx in running where requests[idx].pod == owner { sampleRequest(idx) }
            var i = 0
            var sub: String?
            while i < args.count {
                let a = args[i]
                if a == "-C" || a == "-c" { i += 2; continue }
                i += 1
                if a.hasPrefix("-") { continue }
                sub = a
                break
            }
            guard let sub, ["clone", "fetch", "ls-remote", "pull", "submodule"].contains(sub) else { return }
            let rest = i < args.count ? Array(args[i...]) : []
            let positional = Self.positional(rest, valueFlags: ["--depth", "--branch", "-b", "--origin", "-o", "--jobs", "-j"])
            let url = positional.first(where: Self.looksLikeRemote)
            var dest: String?
            if sub == "clone", let url, let at = positional.firstIndex(of: url), at + 1 < positional.count {
                dest = positional[at + 1]
            }
            var ref: String?
            if let b = rest.firstIndex(where: { $0 == "--branch" || $0 == "-b" }), b + 1 < rest.count { ref = rest[b + 1] }
            if owner == nil, sub == "clone", let url { owner = claimQueued(url: url, ref: ref) }
            if owner != nil || !parallelDownloads { finishRequests(owner: owner) }
            addRequest(kind: .git, verb: sub, url: url ?? "git \(sub)", note: ref, state: .running, localPath: dest, pod: owner)
            if let owner, let p = podIndex[owner], sub == "clone" || sub == "fetch" {
                pods[p].source = .git
                pods[p].status = .downloading
                if parallelDownloads && currentPod == nil { pods[p].startedAt = pods[p].startedAt ?? Date() }
                if let dest { pods[p].downloadPath = dest }
                if let url { pods[p].remoteURL = url }
                activity = parallelDownloads && currentPod == nil ? parallelActivity : "Cloning \(owner)"
            }

        case "curl":
            guard let url = args.first(where: { $0.hasPrefix("http://") || $0.hasPrefix("https://") }) else { return }
            var dest: String?
            if let o = args.firstIndex(of: "-o"), o + 1 < args.count { dest = args[o + 1] }
            if owner == nil { owner = claimQueued(url: url, ref: nil) }
            if owner != nil || !parallelDownloads { finishRequests(owner: owner) }
            addRequest(kind: .http, verb: "GET", url: url, state: .running, localPath: dest, pod: owner)
            if let owner, let p = podIndex[owner] {
                pods[p].source = .http
                pods[p].status = .downloading
                pods[p].downloadPath = dest
                pods[p].remoteURL = url
                if parallelDownloads && currentPod == nil { pods[p].startedAt = pods[p].startedAt ?? Date() }
                activity = parallelDownloads && currentPod == nil ? parallelActivity : "Downloading \(owner)"
            }

        case "unzip", "tar", "xz", "bsdtar", "ditto":
            if let pathMatch {
                finishRequest(pathMatch)
            } else if owner != nil || !parallelDownloads {
                finishRequests(owner: owner)
            }
            if let owner, !parallelDownloads || currentPod != nil { activity = "Extracting \(owner)" }

        case "hg", "svn", "bzr", "scp":
            if owner != nil || !parallelDownloads { finishRequests(owner: owner) }
            let url = args.first(where: Self.looksLikeRemote) ?? tool
            addRequest(kind: .other, verb: tool, url: url, state: .running, pod: owner)

        default:
            break
        }
    }

    private func handleCDN(_ source: String, _ event: CDNEvent) {
        let base = source == "trunk" ? Self.trunkCDN : ""
        switch event {
        case let .downloaded(path):
            let url = redirects.removeValue(forKey: path) ?? base + path
            let size = DiskSize.ofFile(Self.reposRoot + "/" + source + "/" + path) ?? 0
            cdnBytes += size
            addRequest(kind: .cdn, verb: "GET", url: url, status: 200, state: .ok, bytes: size)
        case let .redirect(from, to):
            let relative = !base.isEmpty && from.hasPrefix(base) ? String(from.dropFirst(base.count)) : from
            redirects[relative] = to
            addRequest(kind: .cdn, verb: "GET", url: from, status: 302, state: .redirect)
        case let .notModified(path):
            let url = redirects.removeValue(forKey: path) ?? base + path
            addRequest(kind: .cdn, verb: "GET", url: url, status: 304, state: .notModified)
        case let .notFound(path, code):
            let url = redirects.removeValue(forKey: path) ?? base + path
            addRequest(kind: .cdn, verb: "GET", url: url, status: code, state: .failed)
        case let .failed(url, _):
            addRequest(kind: .cdn, verb: "GET", url: url, state: .failed)
        case .localHit:
            localCacheHits += 1
        }
    }

    // MARK: - Pods

    @discardableResult
    private func upsert(_ name: String) -> Int {
        if let i = podIndex[name] { return i }
        pods.append(PodItem(name: name))
        podIndex[name] = pods.count - 1
        return pods.count - 1
    }

    private func closeCurrentPod() {
        guard let name = currentPod else { return }
        currentPod = nil
        finishRequests(owner: name)
        guard let i = podIndex[name] else { return }
        if pods[i].status.isActive {
            if pods[i].source == .unknown { pods[i].source = .local }
            pods[i].status = pods[i].source == .cache ? .cached : .done
            pods[i].finishedAt = Date()
        } else if pods[i].finishedAt == nil {
            pods[i].finishedAt = Date()
        }
        measureDisk(name)
    }

    private func closePreDownload() {
        guard let name = preDownloadPod else { return }
        preDownloadPod = nil
        finishRequests(owner: name)
        if let i = podIndex[name], pods[i].status == .downloading { pods[i].status = .queued }
    }

    // MARK: - Requests

    private func addRequest(kind: RequestKind, verb: String, url: String, note: String? = nil, status: Int? = nil,
                            state: RequestState, bytes: Int64? = nil, localPath: String? = nil, pod: String? = nil) {
        let request = NetRequest(id: requests.count, kind: kind, verb: verb, url: url, note: note, status: status,
                                 state: state, bytes: bytes, localPath: localPath, pod: pod, startedAt: Date())
        requests.append(request)
        requestCounts[kind, default: 0] += 1
        if state == .running { running.insert(request.id) }
    }

    private func finishRequests(owner: String?, all: Bool = false, state: RequestState = .ok) {
        for idx in running.sorted() where all || requests[idx].pod == owner {
            finishRequest(idx, state: state)
        }
    }

    private func finishRequest(_ idx: Int, state: RequestState = .ok) {
        // curl has exited by now, so an archive still on disk is complete.
        if requests[idx].kind == .http, let path = requests[idx].localPath, FileManager.default.fileExists(atPath: path) {
            completeTransfers.insert(idx)
        }
        sampleRequest(idx)
        requests[idx].state = state
        requests[idx].finishedAt = Date()
        running.remove(idx)
    }

    /// Parallel mode: the queued pod a `git clone` / `curl` belongs to, matched on the podspec's source.
    /// Pods sharing a repo (e.g. Firebase) are told apart by the tag; ties go to the earliest in the queue,
    /// which is the order the thread pool starts them.
    private func claimQueued(url: String, ref: String?) -> String? {
        guard parallelDownloads else { return nil }
        let open = downloadQueue.filter { !claimed.contains($0) && podIndex[$0].map { pods[$0].status == .queued } == true }
        let sameSource = open.filter { specSources[$0]?.matches(url: url, ref: nil) == true }
        let key = PodspecSource.normalize(url)
        let pick = sameSource.first { ref != nil && specSources[$0]?.ref == ref }
            ?? sameSource.first
            ?? open.first { specSources[$0] == nil && key.hasSuffix("/" + $0.lowercased()) }
        if let pick { claimed.insert(pick) }
        return pick
    }

    private var parallelActivity: String {
        let queued = downloadQueue.compactMap { podIndex[$0].map { pods[$0] } }
        let active = queued.filter { $0.status == .downloading }.count
        let finished = queued.filter { $0.status == .done || $0.status == .cached }.count
        return active > 0
            ? "Downloading \(active) at once · \(finished)/\(queued.count) done"
            : "Downloaded \(finished)/\(queued.count) pods"
    }

    /// Synchronous: the temp checkout can disappear moments later. Git transfers are measured
    /// through `.git` (the received pack), HTTP downloads through the archive file.
    private func sampleRequest(_ idx: Int) {
        guard let path = requests[idx].localPath else { return }
        var target = path
        if requests[idx].kind == .git, FileManager.default.fileExists(atPath: path + "/.git") {
            target = path + "/.git"
            // A finished .pack (not tmp_pack_*) means this sample saw the whole transfer.
            let packs = (try? FileManager.default.contentsOfDirectory(atPath: target + "/objects/pack")) ?? []
            if packs.contains(where: { $0.hasSuffix(".pack") && !$0.hasPrefix("tmp_") }) { completeTransfers.insert(idx) }
        }
        guard let size = DiskSize.of(target), size > 0 else { return }
        if size > (requests[idx].bytes ?? 0) { requests[idx].bytes = size }
        if let pod = requests[idx].pod, let i = podIndex[pod], size > pods[i].downloadBytes {
            pods[i].downloadBytes = size
        }
    }

    // MARK: - Sizes

    private func measureDisk(_ name: String) {
        let root = name.split(separator: "/").first.map(String.init) ?? name
        measure(projectPath + "/Pods/" + root) { [weak self] size in
            guard let self, let size, let i = self.podIndex[name] else { return }
            self.pods[i].diskBytes = size
        }
    }

    private func measure(_ path: String, apply: @escaping @MainActor (Int64?) -> Void) {
        guard !measuring.contains(path) else { return }
        measuring.insert(path)
        Task.detached(priority: .utility) {
            let size = DiskSize.of(path)
            await MainActor.run {
                self.measuring.remove(path)
                apply(size)
            }
        }
    }

    // MARK: - Helpers

    private static func positional(_ args: [String], valueFlags: Set<String>) -> [String] {
        var out: [String] = []
        var skipNext = false
        for a in args {
            if skipNext { skipNext = false; continue }
            if valueFlags.contains(a) { skipNext = true; continue }
            if a.hasPrefix("-") { continue }
            out.append(a)
        }
        return out
    }

    private static func looksLikeRemote(_ s: String) -> Bool {
        ["https://", "http://", "git://", "ssh://", "file://", "git@"].contains { s.hasPrefix($0) }
    }

    public nonisolated static func durationText(_ t: TimeInterval) -> String {
        if t < 60 { return String(format: "%.1fs", t) }
        let s = Int(t.rounded())
        return "\(s / 60)m \(s % 60)s"
    }
}
