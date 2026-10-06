import Foundation

public enum Phase: Int, Comparable, Sendable {
    case preparing, analyzing, downloading, generating, integrating, done, failed

    public static func < (lhs: Phase, rhs: Phase) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .preparing: "Preparing"
        case .analyzing: "Resolving"
        case .downloading: "Downloading"
        case .generating: "Generating"
        case .integrating: "Integrating"
        case .done: "Complete"
        case .failed: "Failed"
        }
    }
}

/// How a pod differs from what is already in `Pods/` (CocoaPods' A / M / - / R manifest lines).
public enum PodChange: String, Sendable {
    case added, changed, unchanged, removed, unknown
}

public enum PodStatus: Sendable {
    case queued, downloading, installing, done, cached, upToDate, removed, failed

    public var isActive: Bool { self == .downloading || self == .installing }
}

public enum SourceKind: String, Sendable {
    case unknown, git, http, cache, local, other

    init(downloaderName: String) {
        switch downloaderName.lowercased() {
        case "git": self = .git
        case "http": self = .http
        default: self = .other
        }
    }

    public var label: String {
        switch self {
        case .unknown: "unknown"
        case .git: "git"
        case .http: "HTTP"
        case .cache: "cache"
        case .local: "local"
        case .other: "download"
        }
    }

    /// The pod's files came over the network during this run.
    public var isRemote: Bool { self == .git || self == .http || self == .other }
}

public struct PodItem: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public var version: String?
    public var previousVersion: String?
    public var change: PodChange = .unknown
    public var status: PodStatus = .queued
    public var source: SourceKind = .unknown
    public var remoteURL: String?
    public var downloadPath: String?
    public var cachePath: String?
    /// Bytes pulled over the network (git pack / downloaded archive).
    public var downloadBytes: Int64 = 0
    /// Size of `Pods/<Name>` once installed.
    public var diskBytes: Int64?
    public var startedAt: Date?
    public var finishedAt: Date?

    init(name: String) { self.name = name }

    public var isPlanned: Bool { change == .added || change == .changed }

    /// Size on disk once installed; in-flight transfers are reported separately via `downloadBytes`.
    public var displayBytes: Int64 { diskBytes ?? 0 }

    public var duration: TimeInterval? {
        guard let startedAt, let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }
}

public enum RequestKind: String, Sendable, CaseIterable {
    case cdn, git, http, other

    public var label: String {
        switch self {
        case .cdn: "CDN"
        case .git: "Git"
        case .http: "HTTP"
        case .other: "Other"
        }
    }
}

public enum RequestState: Sendable {
    case running, ok, redirect, notModified, failed
}

public struct NetRequest: Identifiable, Sendable {
    public let id: Int
    public let kind: RequestKind
    public let verb: String
    public let url: String
    public let host: String
    public let title: String
    public let detail: String
    public var status: Int?
    public var state: RequestState
    public var bytes: Int64?
    public var localPath: String?
    public var pod: String?
    public let startedAt: Date
    public var finishedAt: Date?

    init(id: Int, kind: RequestKind, verb: String, url: String, note: String?, status: Int?, state: RequestState,
         bytes: Int64?, localPath: String?, pod: String?, startedAt: Date) {
        self.id = id
        self.kind = kind
        self.verb = verb
        self.url = url
        self.status = status
        self.state = state
        self.bytes = bytes
        self.localPath = localPath
        self.pod = pod
        self.startedAt = startedAt
        self.finishedAt = state == .running ? nil : startedAt

        let host = Self.host(of: url)
        let parts = Self.pathComponents(of: url)
        let last = parts.last ?? url
        self.host = host
        switch kind {
        case .cdn:
            if last.hasSuffix(".podspec.json"), parts.count >= 3 {
                title = "\(parts[parts.count - 3]) \(parts[parts.count - 2])"
                detail = Self.join("podspec", host)
            } else if last.hasPrefix("all_pods_versions") {
                title = last
                detail = Self.join("version index", host)
            } else {
                title = last
                detail = Self.join("spec metadata", host)
            }
        case .git:
            title = parts.suffix(2).joined(separator: "/").replacingOccurrences(of: ".git", with: "")
            detail = Self.join("git \(verb)", host, note.map { "ref \($0)" })
        case .http:
            title = last
            detail = Self.join("download", host)
        case .other:
            title = last
            detail = Self.join(verb, host)
        }
    }

    private static func join(_ parts: String?...) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func host(of url: String) -> String {
        if let host = URL(string: url)?.host { return host }
        // scp-style remotes: git@github.com:owner/repo.git
        if let at = url.firstIndex(of: "@"), let colon = url[at...].firstIndex(of: ":") {
            return String(url[url.index(after: at)..<colon])
        }
        return ""
    }

    static func pathComponents(of url: String) -> [String] {
        if let u = URL(string: url), u.host != nil {
            return u.path.split(separator: "/").map(String.init)
        }
        if url.contains("@"), let colon = url.lastIndex(of: ":") {
            return url[url.index(after: colon)...].split(separator: "/").map(String.init)
        }
        return url.split(separator: "/").map(String.init)
    }
}

public enum DiskSize {
    public static func ofFile(_ path: String) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return (attrs[.size] as? NSNumber)?.int64Value
    }

    /// Logical size of a file or directory tree (symlinks are not followed).
    public static func of(_ path: String) -> Int64? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        guard isDir.boolValue else { return ofFile(path) }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
        ) else { return nil }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
