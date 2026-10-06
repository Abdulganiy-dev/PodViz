import Foundation
import PodVizCore

// Usage: pvreplay <verbose-log> [--cwd <project dir>] [--exit <code>]
let args = CommandLine.arguments
guard args.count >= 2, let text = try? String(contentsOfFile: args[1], encoding: .utf8) else {
    print("usage: pvreplay <pod-install-verbose.log> [--cwd dir] [--exit code]")
    exit(2)
}

func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

MainActor.assumeIsolated {
    let cwd = value("--cwd") ?? FileManager.default.currentDirectoryPath
    let session = PodSession(origin: .terminal, projectPath: cwd, command: "pod install")
    session.ingest(text.components(separatedBy: "\n"))
    if let code = value("--exit").flatMap(Int32.init) { session.finish(exitCode: code) }
    // Let the background size measurements land.
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))

    func mb(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    print("phase      \(session.phase.title)   activity: \(session.activity)")
    print("pods       planned \(session.plannedCount), installed \(session.installedCount), total \(session.totalPodCount)")
    print("progress   \(Int(session.progress * 100))%   menu bar: \(session.menuBarText)")
    print("bytes      downloaded \(mb(session.downloadedBytes)) (cdn \(mb(session.cdnBytes))), on disk \(mb(session.diskBytes))")
    let counts = RequestKind.allCases.map { "\($0.label) \(session.requestCounts[$0] ?? 0)" }.joined(separator: ", ")
    print("requests   \(session.requests.count) total — \(counts); local cache hits \(session.localCacheHits)")
    print("")
    for pod in session.pods {
        let line = [
            pod.name.padding(toLength: 22, withPad: " ", startingAt: 0),
            (pod.version ?? "-").padding(toLength: 10, withPad: " ", startingAt: 0),
            "\(pod.change)".padding(toLength: 10, withPad: " ", startingAt: 0),
            "\(pod.status)".padding(toLength: 12, withPad: " ", startingAt: 0),
            pod.source.label.padding(toLength: 9, withPad: " ", startingAt: 0),
            "dl \(mb(pod.downloadBytes))".padding(toLength: 14, withPad: " ", startingAt: 0),
            "disk \(pod.diskBytes.map(mb) ?? "-")",
        ]
        print("  " + line.joined(separator: " "))
    }
    print("")
    print("non-CDN requests:")
    for r in session.requests where r.kind != .cdn {
        print("  [\(r.kind.label)] \(r.verb) \(r.title) — \(r.detail) — \(r.state) \(r.bytes.map(mb) ?? "")")
    }
    print("first CDN requests:")
    for r in session.requests.filter({ $0.kind == .cdn }).prefix(4) {
        print("  \(r.status.map(String.init) ?? "-") \(r.title) — \(r.detail)")
    }
    if !session.warnings.isEmpty { print("\nwarnings: \(session.warnings.prefix(5))") }
    if let e = session.errorMessage { print("error: \(e)") }
}
