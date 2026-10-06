import AppKit
import PodVizCore
import SwiftUI
import UserNotifications

@main
struct PodVizApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let store = AppStore.shared

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environment(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    let store: AppStore

    var body: some View {
        if let session = store.session, session.isRunning {
            HStack(spacing: 3) {
                Image(systemName: "shippingbox.fill")
                Text(session.menuBarText).monospacedDigit()
            }
        } else if store.hasUnseenResult, let session = store.session {
            Image(systemName: session.phase == .failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
        } else {
            Image(systemName: "shippingbox")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if LoginItem.runCommandLineIfRequested() { exit(0) }
        if SnapshotRunner.runIfRequested() { return }
        AppStore.shared.boot()
        if Notifier.isAvailable { UNUserNotificationCenter.current().delegate = self }
        SnapshotRunner.autorunIfRequested()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

/// `PodViz --snapshot out.png [--log file] [--lines N] [--exit code] [--cwd dir] [--tab pods|network|log] [--dark]`
/// Replays a verbose log into the UI and saves a PNG of the popover, then quits. Used for UI checks.
@MainActor
enum SnapshotRunner {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--snapshot"), flag + 1 < args.count else { return false }
        let output = args[flag + 1]
        func value(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        let store = AppStore.shared
        let (cwd, candidates) = AppStore.resolveProject(URL(fileURLWithPath: value("--cwd") ?? FileManager.default.currentDirectoryPath))
        store.selectedProject = cwd
        store.podfileCandidates = candidates
        store.cliInstalled = args.contains("--cli")
        store.loadInventory()
        if let log = value("--log"), let text = try? String(contentsOfFile: log, encoding: .utf8) {
            var lines = text.components(separatedBy: "\n")
            if let n = value("--lines").flatMap(Int.init) { lines = Array(lines.prefix(n)) }
            let elapsed = value("--elapsed").flatMap(Double.init) ?? 84
            let session = PodSession(origin: .app, projectPath: cwd, command: value("--cmd") ?? "pod install",
                                     startedAt: Date().addingTimeInterval(-elapsed))
            session.ingest(lines)
            if let code = value("--exit").flatMap(Int32.init) { session.finish(exitCode: code) }
            store.session = session
            store.mainView = args.contains("--project-view") ? .project : .run
        }
        let tab = value("--tab").flatMap(DetailTab.init(rawValue:)) ?? .pods
        let dark = args.contains("--dark")
        if let height = value("--height").flatMap(Double.init) { ContentView.height = height }
        // Give background size measurements time to land (Pods/ folders can be large).
        let started = Date()
        func renderWhenReady() {
            let busy = store.inventory.map { !$0.isLoaded || $0.isMeasuring } ?? false
            if busy && Date().timeIntervalSince(started) < 60 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { renderWhenReady() }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { render(tab: tab, dark: dark, to: output) }
            }
        }
        renderWhenReady()
        return true
    }

    /// `PodViz [--autorun <project>] --shots <dir> [--every seconds] [--tab …]`
    /// Saves a snapshot every few seconds while a run (started here with --autorun, or by `podviz`
    /// in Terminal) is in progress, then quits after it finishes.
    static func autorunIfRequested() {
        let args = CommandLine.arguments
        guard let shots = args.firstIndex(of: "--shots").map({ args[$0 + 1] }) else { return }
        let every = args.firstIndex(of: "--every").flatMap { Double(args[$0 + 1]) } ?? 3
        let tab = args.firstIndex(of: "--tab").flatMap { DetailTab(rawValue: args[$0 + 1]) } ?? .pods
        let store = AppStore.shared
        if let flag = args.firstIndex(of: "--autorun"), flag + 1 < args.count {
            store.selectProject(URL(fileURLWithPath: args[flag + 1]))
            store.run(.install)
        }
        var shot = 0
        func capture() {
            guard let session = store.session else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { capture() }
                return
            }
            shot += 1
            let finished = !session.isRunning
            let path = "\(shots)/shot-\(String(format: "%02d", shot))\(finished ? "-final" : "").png"
            render(tab: tab, dark: false, to: path, then: finished ? { exit(0) } : nil)
            if !finished {
                DispatchQueue.main.asyncAfter(deadline: .now() + every) { capture() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + every) { capture() }
    }

    private static func render(tab: DetailTab, dark: Bool, to path: String, then done: (() -> Void)? = { exit(0) }) {
        let size = NSSize(width: ContentView.width, height: ContentView.height)
        let root = ContentView(initialTab: tab)
            .environment(AppStore.shared)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            window.orderOut(nil)
            done?()
        }
    }
}
