import CryptoKit
import Foundation

/// Where a pod's files come from, as written in its podspec.
struct PodspecSource: Sendable, Equatable {
    var git: String?
    /// Tag, branch or commit.
    var ref: String?
    var http: String?

    /// Whether a `git clone` / `curl` of `url` (checking out `ref`) is this pod's download.
    func matches(url: String, ref: String?) -> Bool {
        let key = Self.normalize(url)
        if let git, Self.normalize(git) == key { return ref == nil || self.ref == nil || ref == self.ref }
        if let http { return http == url || Self.normalize(http) == key }
        return false
    }

    /// `https://github.com/A/B.git`, `git@github.com:A/B` and `https://github.com/A/B/` compare equal.
    static func normalize(_ url: String) -> String {
        var s = url.lowercased()
        for scheme in ["https://", "http://", "git://", "ssh://"] where s.hasPrefix(scheme) {
            s.removeFirst(scheme.count)
        }
        if s.hasPrefix("git@") {
            s.removeFirst(4)
            if let colon = s.firstIndex(of: ":") { s.replaceSubrange(colon...colon, with: "/") }
        }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        return s
    }

    /// Reads the podspec CocoaPods resolved: a local/external one in Pods/Local Podspecs, otherwise the
    /// spec repos (trunk's CDN cache shards specs by the first three hex digits of md5(name)).
    static func lookup(name: String, version: String?, projectPath: String) -> PodspecSource? {
        var candidates = [projectPath + "/Pods/Local Podspecs/\(name).podspec.json"]
        if let version {
            let reposRoot = PodSession.reposRoot
            let shard = shard(name)
            let repos = ((try? FileManager.default.contentsOfDirectory(atPath: reposRoot)) ?? [])
                .sorted { ($0 == "trunk" ? 0 : 1) < ($1 == "trunk" ? 0 : 1) }
            for repo in repos where !repo.hasPrefix(".") {
                let base = "\(reposRoot)/\(repo)"
                candidates += [
                    "\(base)/Specs/\(shard)/\(name)/\(version)/\(name).podspec.json",
                    "\(base)/\(name)/\(version)/\(name).podspec.json",
                    "\(base)/Specs/\(name)/\(version)/\(name).podspec.json",
                ]
            }
        }
        for path in candidates {
            guard let data = FileManager.default.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let source = json["source"] as? [String: Any] else { continue }
            let ref = (source["tag"] ?? source["branch"] ?? source["commit"]).map { "\($0)" }
            return PodspecSource(git: source["git"] as? String, ref: ref, http: source["http"] as? String)
        }
        return nil
    }

    static func shard(_ name: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(name.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return hex.prefix(3).map(String.init).joined(separator: "/")
    }
}
