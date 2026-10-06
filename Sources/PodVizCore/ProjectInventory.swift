import Foundation
import Observation

/// Where a pod from Podfile.lock stands on this Mac.
public enum PodInstallState: Sendable {
    /// In the project's Pods/ folder.
    case installed
    /// A development pod (`:path`), e.g. a Flutter plugin. It lives in its own folder, not in Pods/.
    case local
    /// Not in Pods/, but the locked version is in the CocoaPods download cache, so no download is needed.
    case cachedOnly
    /// Not on this Mac; `pod install` will download it.
    case missing
}

public enum SyncState: Sendable {
    /// Pods/Manifest.lock matches Podfile.lock.
    case inSync
    /// Pods/ was installed from a different Podfile.lock; run `pod install`.
    case outOfSync
    /// Podfile.lock exists but Pods/ doesn't.
    case notInstalled
    /// No Podfile.lock: CocoaPods has never been run here.
    case noLockfile
}

public struct InventoryPod: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let version: String
    /// Resolved folder of a `:path` pod.
    public let localPath: String?
    /// The `:path` value as written in Podfile.lock.
    public let localPathLabel: String?
    public let gitURL: String?
    public var state: PodInstallState
    /// Size of Pods/<Name>, or of the local folder for development pods.
    public var bytes: Int64?
    /// Size of the locked version in the CocoaPods download cache.
    public var cacheBytes: Int64?
    /// Versions of this pod in the download cache.
    public var cachedVersions: [String]
}

/// What Podfile.lock says is installed for one Podfile, and what is actually on disk.
@MainActor
@Observable
public final class ProjectInventory {
    public let podfileDir: String
    public private(set) var hasPodfile = false
    public private(set) var pods: [InventoryPod] = []
    public private(set) var dependencyCount = 0
    public private(set) var cocoapodsVersion: String?
    public private(set) var lockModified: Date?
    public private(set) var podfileChangedSinceInstall = false
    public private(set) var sync: SyncState = .noLockfile
    public private(set) var podsFolderBytes: Int64?
    public private(set) var isLoaded = false
    public private(set) var isMeasuring = false

    @ObservationIgnored private var generation = 0

    public init(podfileDir: String) {
        self.podfileDir = podfileDir
    }

    public var installedCount: Int { pods.reduce(0) { $0 + ($1.state == .installed || $1.state == .local ? 1 : 0) } }
    public var missingCount: Int { pods.reduce(0) { $0 + ($1.state == .missing ? 1 : 0) } }
    public var cachedOnlyCount: Int { pods.reduce(0) { $0 + ($1.state == .cachedOnly ? 1 : 0) } }
    public var cacheBytes: Int64 { pods.reduce(Int64(0)) { $0 + ($1.cacheBytes ?? 0) } }
    public var installedBytes: Int64 { pods.reduce(Int64(0)) { $0 + ($1.state == .installed ? ($1.bytes ?? 0) : 0) } }

    /// Re-reads Podfile.lock (fast) and then measures sizes in the background.
    public func refresh() {
        generation += 1
        let token = generation
        let dir = podfileDir
        isMeasuring = true
        Task.detached(priority: .userInitiated) {
            let snapshot = Self.scan(dir)
            await MainActor.run {
                guard token == self.generation else { return }
                self.apply(snapshot)
                self.isLoaded = true
            }
            let sizes = Self.measure(dir, pods: snapshot.pods)
            await MainActor.run {
                guard token == self.generation else { return }
                self.podsFolderBytes = sizes.podsFolder
                for i in self.pods.indices {
                    let name = self.pods[i].name
                    self.pods[i].bytes = sizes.pods[name]
                    self.pods[i].cacheBytes = sizes.cache[name]
                }
                self.isMeasuring = false
            }
        }
    }

    private func apply(_ s: Snapshot) {
        hasPodfile = s.hasPodfile
        pods = s.pods
        dependencyCount = s.dependencyCount
        cocoapodsVersion = s.cocoapodsVersion
        lockModified = s.lockModified
        podfileChangedSinceInstall = s.podfileChangedSinceInstall
        sync = s.sync
    }

    // MARK: - Scanning (off the main actor)

    struct Snapshot: Sendable {
        var hasPodfile = false
        var pods: [InventoryPod] = []
        var dependencyCount = 0
        var cocoapodsVersion: String?
        var lockModified: Date?
        var podfileChangedSinceInstall = false
        var sync: SyncState = .noLockfile
    }

    nonisolated static func scan(_ dir: String) -> Snapshot {
        let fm = FileManager.default
        var s = Snapshot()
        s.hasPodfile = fm.fileExists(atPath: dir + "/Podfile")
        let lockPath = dir + "/Podfile.lock"
        guard let lockText = try? String(contentsOfFile: lockPath, encoding: .utf8) else { return s }
        let lock = Lockfile(lockText)
        s.dependencyCount = lock.dependencyCount
        s.cocoapodsVersion = lock.cocoapodsVersion
        s.lockModified = modified(lockPath)
        if let podfile = modified(dir + "/Podfile"), let locked = s.lockModified {
            s.podfileChangedSinceInstall = podfile > locked.addingTimeInterval(1)
        }
        if let manifest = try? String(contentsOfFile: dir + "/Pods/Manifest.lock", encoding: .utf8) {
            s.sync = manifest == lockText ? .inSync : .outOfSync
        } else {
            s.sync = .notInstalled
        }

        let cache = cacheRoot + "/Pods"
        s.pods = lock.pods.map { name, version in
            let source = lock.external[name]
            var localPath: String?
            if let path = source?.path {
                let base = path.hasPrefix("/") ? path : dir + "/" + path
                localPath = URL(fileURLWithPath: base).standardizedFileURL.resolvingSymlinksInPath().path
            }
            let cachedVersions = cachedVersions(of: name, in: cache)
            let inExternalCache = source?.git != nil && fm.fileExists(atPath: cache + "/External/" + name)
            let state: PodInstallState
            if let localPath {
                state = fm.fileExists(atPath: localPath) ? .local : .missing
            } else if fm.fileExists(atPath: dir + "/Pods/" + name) {
                state = .installed
            } else if cachedVersions.contains(version) || inExternalCache {
                state = .cachedOnly
            } else {
                state = .missing
            }
            return InventoryPod(name: name, version: version, localPath: localPath, localPathLabel: source?.path,
                                gitURL: source?.git, state: state, bytes: nil, cacheBytes: nil,
                                cachedVersions: cachedVersions)
        }
        return s
    }

    struct Sizes: Sendable {
        var podsFolder: Int64?
        var pods: [String: Int64] = [:]
        var cache: [String: Int64] = [:]
    }

    nonisolated static func measure(_ dir: String, pods: [InventoryPod]) -> Sizes {
        var sizes = Sizes()
        // One pass over Pods/, attributing every file to its top-level folder.
        if let (total, children) = sizesByChild(dir + "/Pods") {
            sizes.podsFolder = total
            for pod in pods where pod.state == .installed { sizes.pods[pod.name] = children[pod.name] ?? 0 }
        }
        for pod in pods where pod.state == .local {
            if let path = pod.localPath { sizes.pods[pod.name] = DiskSize.of(path) }
        }
        let cache = cacheRoot + "/Pods"
        for pod in pods where pod.localPath == nil {
            if let entry = cacheEntry(of: pod.name, version: pod.version, in: cache) {
                sizes.cache[pod.name] = DiskSize.of(entry)
            } else if pod.gitURL != nil {
                sizes.cache[pod.name] = DiskSize.of(cache + "/External/" + pod.name)
            }
        }
        return sizes
    }

    // MARK: - Helpers

    /// CocoaPods' download cache (`pod cache list` shows the same place).
    nonisolated public static var cacheRoot: String {
        ProcessInfo.processInfo.environment["CP_CACHE_DIR"] ?? (NSHomeDirectory() + "/Library/Caches/CocoaPods")
    }

    /// Release cache entries are named `<version>-<short checksum>`.
    nonisolated static func cachedVersions(of name: String, in cache: String) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: cache + "/Release/" + name)) ?? []
        return entries.compactMap { entry in
            guard let dash = entry.lastIndex(of: "-") else { return nil }
            return String(entry[..<dash])
        }
    }

    nonisolated static func cacheEntry(of name: String, version: String, in cache: String) -> String? {
        let root = cache + "/Release/" + name
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return entries.first { $0.hasPrefix(version + "-") }.map { root + "/" + $0 }
    }

    nonisolated static func sizesByChild(_ dir: String) -> (Int64, [String: Int64])? {
        guard FileManager.default.fileExists(atPath: dir) else { return nil }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: dir), includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
        ) else { return nil }
        let prefix = URL(fileURLWithPath: dir).standardizedFileURL.path + "/"
        var total: Int64 = 0
        var children: [String: Int64] = [:]
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            total += size
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            let child = path.dropFirst(prefix.count).split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            children[child, default: 0] += size
        }
        return (total, children)
    }

    nonisolated static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Folders under `root` that contain a Podfile, shallowest first (so `ios/` beats `example/ios/`).
    nonisolated public static func findPodfiles(in root: String, maxDepth: Int = 4) -> [String] {
        let skip: Set<String> = ["Pods", "node_modules", ".git", "build", "Build", "DerivedData", ".symlinks",
                                 ".dart_tool", "Carthage", ".build", "vendor", ".gradle", "android", ".pub-cache"]
        let fm = FileManager.default
        var found: [String] = []
        var level = [URL(fileURLWithPath: root).standardizedFileURL.path]
        for _ in 0...maxDepth {
            var next: [String] = []
            for dir in level {
                if fm.fileExists(atPath: dir + "/Podfile") { found.append(dir) }
                let children = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
                for child in children.sorted() where !skip.contains(child) && !child.hasPrefix(".") {
                    var isDir: ObjCBool = false
                    let path = dir + "/" + child
                    if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                       (try? fm.destinationOfSymbolicLink(atPath: path)) == nil {
                        next.append(path)
                    }
                }
            }
            if next.isEmpty { break }
            level = next
        }
        return found
    }
}

/// The parts of Podfile.lock PodViz needs. It's YAML, but a fixed, simple shape.
struct Lockfile {
    struct Source { var path: String?; var git: String? }

    /// Root pods in file order with their locked version.
    var pods: [(String, String)] = []
    var dependencyCount = 0
    var external: [String: Source] = [:]
    var cocoapodsVersion: String?

    init(_ text: String) {
        var section = ""
        var seen = Set<String>()
        var externalName: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if let first = line.first, first != " " {
                section = line.hasSuffix(":") ? String(line.dropLast()) : String(line.split(separator: ":").first ?? "")
                if line.hasPrefix("COCOAPODS:") {
                    cocoapodsVersion = line.dropFirst("COCOAPODS:".count).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            switch section {
            case "PODS":
                guard line.hasPrefix("  - ") else { continue }
                var entry = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                if entry.hasSuffix(":") { entry.removeLast() }
                entry = entry.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                guard let open = entry.range(of: " (", options: .backwards), entry.hasSuffix(")") else { continue }
                let fullName = String(entry[..<open.lowerBound])
                let version = String(entry[open.upperBound..<entry.index(before: entry.endIndex)])
                let root = String(fullName.split(separator: "/").first ?? Substring(fullName))
                if seen.insert(root).inserted { pods.append((root, version)) }
            case "DEPENDENCIES":
                if line.hasPrefix("  - ") { dependencyCount += 1 }
            case "EXTERNAL SOURCES":
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("    "), let name = externalName {
                    let value = { (key: String) -> String in
                        String(trimmed.dropFirst(key.count)).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                    }
                    if trimmed.hasPrefix(":path:") { external[name, default: Source()].path = value(":path:") }
                    if trimmed.hasPrefix(":git:") { external[name, default: Source()].git = value(":git:") }
                    if trimmed.hasPrefix(":podspec:") { external[name, default: Source()].path = nil }
                } else if line.hasPrefix("  "), trimmed.hasSuffix(":") {
                    externalName = String(trimmed.dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            default:
                break
            }
        }
    }
}
