import Foundation

public enum PodAction: Sendable, Equatable {
    case installing, downloading, using
}

public enum CDNEvent: Sendable, Equatable {
    case downloaded(path: String)
    case redirect(from: String, to: String)
    case notModified(path: String)
    case notFound(path: String, code: Int)
    case failed(url: String, reason: String)
    case localHit
}

public enum LogEvent: Sendable, Equatable {
    case section(Phase?, activity: String)
    case comparingStart
    case manifestLine(PodChange, String)
    case podSection(action: PodAction, name: String, version: String?, previous: String?)
    case removing(String)
    case downloader(SourceKind)
    case copying(name: String, from: String)
    case command(executable: String, args: [String])
    case cdn(source: String, CDNEvent)
    case preDownload(name: String)
    case failedCommand(String)
    case bang(String)
    case complete(dependencies: Int, pods: Int)
    case meta(key: String, value: String)
    case blank
    case other
}

/// Turns one line of `pod install --verbose --no-ansi` output into a structured event.
/// Formats are taken from CocoaPods 1.15 (installer.rb, analyzer.rb, cdn_source.rb, cocoapods-downloader).
public enum LineParser {
    private static let ansi = Rx("\u{1B}\\[[0-9;?]*[ -/]*[@-~]")
    private static let meta = Rx(#"^#PODVIZ (\w+)=(.*)$"#)
    private static let cdn = Rx(#"^CDN: (\S+) (.*)$"#)
    private static let command = Rx(#"^\$ (\S+)(?: (.*))?$"#)
    private static let copying = Rx(#"^> Copying (\S+) from `([^`]+)` to "#)
    private static let downloader = Rx(#"^> (\w+) (?:HEAD )?download$"#)
    private static let complete = Rx(#"Pod installation complete! There (?:is|are) (\d+) dependenc(?:y|ies) from the Podfile and (\d+) total pods? installed"#)
    private static let podSection = Rx(#"^(Installing|Downloading|Using) ([^\s`]+) (.+)$"#)
    private static let versionParen = Rx(#"^\(([^)]+)\)$"#)
    private static let versionWas = Rx(#"^(\S+) \(was ([^\s)]+)"#)
    private static let removing = Rx(#"^Removing (\S+)$"#)
    private static let preDownload = Rx(#"^Pre-downloading: `([^`]+)`"#)
    private static let manifest = Rx(#"^([ARM-]) (\S+)$"#)

    private static let cdnDownloaded = Rx(#"^Relative path downloaded: (.+?), save ETag:"#)
    private static let cdnRedirect = Rx(#"^Redirecting from (\S+) to (\S+)$"#)
    private static let cdnNotModified = Rx(#"^Relative path not modified: (.+)$"#)
    private static let cdnNotFound = Rx(#"^Relative path couldn't be downloaded: (.+) Response: (\d+)"#)
    private static let cdnFailed = Rx(#"^URL couldn't be downloaded: (\S+) Response: (.*)$"#)
    private static let cdnLocal = Rx(#"^Relative path: (.+?) (?:exists!|modified during this run!)"#)

    private struct Section {
        let text: String
        let exact: Bool
        let phase: Phase?
        let activity: String
    }

    private static let sections: [Section] = [
        Section(text: "Preparing", exact: true, phase: .preparing, activity: "Preparing"),
        Section(text: "Updating local specs repositories", exact: true, phase: .analyzing, activity: "Updating spec repositories"),
        Section(text: "Updating spec repo", exact: false, phase: .analyzing, activity: "Updating spec repositories"),
        Section(text: "Analyzing dependencies", exact: true, phase: .analyzing, activity: "Analyzing dependencies"),
        Section(text: "Inspecting targets to integrate", exact: true, phase: nil, activity: "Inspecting targets"),
        Section(text: "Fetching external sources", exact: true, phase: nil, activity: "Fetching external sources"),
        Section(text: "Finding Podfile changes", exact: true, phase: nil, activity: "Finding Podfile changes"),
        Section(text: "Resolving dependencies of", exact: false, phase: nil, activity: "Resolving dependencies"),
        Section(text: "Downloading dependencies", exact: true, phase: .downloading, activity: "Downloading dependencies"),
        Section(text: "Generating Pods project", exact: true, phase: .generating, activity: "Generating Pods project"),
        Section(text: "Integrating client project", exact: false, phase: .integrating, activity: "Integrating client project"),
    ]

    public static func clean(_ raw: String) -> String {
        var line = raw
        if line.contains("\u{1B}") { line = ansi.replaceAll(in: line, with: "") }
        if line.hasSuffix("\r") { line.removeLast() }
        // Progress output redraws with carriage returns; keep only the final frame.
        if let cr = line.lastIndex(of: "\r") { line = String(line[line.index(after: cr)...]) }
        return line
    }

    public static func parse(_ line: String) -> LogEvent {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .blank }

        if t.hasPrefix("#PODVIZ "), let g = meta.groups(t) { return .meta(key: g[0], value: g[1]) }
        if t.hasPrefix("CDN: "), let g = cdn.groups(t) { return parseCDN(source: g[0], g[1]) }
        if t.hasPrefix("$ "), let g = command.groups(t) {
            return .command(executable: g[0], args: g[1].split(separator: " ").map(String.init))
        }
        if t.hasPrefix("> ") {
            if let g = copying.groups(t) { return .copying(name: g[0], from: g[1]) }
            if let g = downloader.groups(t) { return .downloader(SourceKind(downloaderName: g[0])) }
            return .other
        }
        if t.hasPrefix("[!] ") {
            let message = String(t.dropFirst(4))
            if message.hasPrefix("Failed: ") { return .failedCommand(String(message.dropFirst(8))) }
            return .bang(message)
        }
        if let g = complete.groups(t) {
            return .complete(dependencies: Int(g[0]) ?? 0, pods: Int(g[1]) ?? 0)
        }

        // Verbose section titles carry a "-> " prefix.
        let u = t.hasPrefix("-> ") ? String(t.dropFirst(3)) : t
        if u == "Comparing resolved specification to the sandbox manifest" { return .comparingStart }
        for s in sections where s.exact ? u == s.text : u.hasPrefix(s.text) {
            return .section(s.phase, activity: s.activity)
        }
        if let g = podSection.groups(u) {
            let action: PodAction = switch g[0] {
            case "Installing": .installing
            case "Downloading": .downloading
            default: .using
            }
            let (version, previous) = parseVersion(g[2])
            return .podSection(action: action, name: g[1], version: version, previous: previous)
        }
        if let g = removing.groups(u) { return .removing(g[0]) }
        if let g = preDownload.groups(u) { return .preDownload(name: g[0]) }
        if let g = manifest.groups(t) {
            let change: PodChange = switch g[0] {
            case "A": .added
            case "M": .changed
            case "R": .removed
            default: .unchanged
            }
            return .manifestLine(change, g[1])
        }
        return .other
    }

    /// "(5.12.2)" · "5.12.2 (was 5.11.0)" · "5.12.2 (source changed to …)"
    static func parseVersion(_ text: String) -> (String?, String?) {
        if let g = versionParen.groups(text) { return (g[0], nil) }
        if let g = versionWas.groups(text) { return (g[0], g[1]) }
        return (text.split(separator: " ").first.map(String.init), nil)
    }

    private static func parseCDN(source: String, _ rest: String) -> LogEvent {
        if let g = cdnDownloaded.groups(rest) { return .cdn(source: source, .downloaded(path: g[0])) }
        if let g = cdnRedirect.groups(rest) { return .cdn(source: source, .redirect(from: g[0], to: g[1])) }
        if let g = cdnNotModified.groups(rest) { return .cdn(source: source, .notModified(path: g[0])) }
        if let g = cdnNotFound.groups(rest) { return .cdn(source: source, .notFound(path: g[0], code: Int(g[1]) ?? 404)) }
        if let g = cdnFailed.groups(rest) { return .cdn(source: source, .failed(url: g[0], reason: g[1])) }
        if cdnLocal.groups(rest) != nil { return .cdn(source: source, .localHit) }
        return .other
    }
}

struct Rx: @unchecked Sendable {
    private let re: NSRegularExpression

    init(_ pattern: String) {
        re = try! NSRegularExpression(pattern: pattern)
    }

    /// Capture groups of the first match (empty string for groups that didn't participate).
    func groups(_ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    func replaceAll(in s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }
}
