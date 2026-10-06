import PodVizCore
import SwiftUI

/// The selected project when nothing is running: what Podfile.lock lists, what is on this Mac, and the space it takes.
struct ProjectOverviewView: View {
    let inventory: ProjectInventory

    var body: some View {
        let installed = inventory.pods.filter { $0.state == .installed }
        let items = installed.map { SizeItem(name: $0.name, bytes: $0.bytes ?? 0) }
        let colors = Theme.sizeColors(items)
        VStack(spacing: 10) {
            ProjectSummaryCard(inventory: inventory)
            if inventory.isLoaded && inventory.pods.isEmpty {
                NoPodsCard(inventory: inventory)
                Spacer()
            } else {
                InventoryStats(inventory: inventory)
                if items.contains(where: { $0.bytes > 0 }) {
                    SizeBreakdownView(items: items, colors: colors,
                                      trailing: inventory.podsFolderBytes.map { "Pods folder \(Fmt.bytes($0))" } ?? "")
                }
                InventoryList(inventory: inventory, colors: colors)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }
}

struct ProjectSummaryCard: View {
    @Environment(AppStore.self) private var store
    let inventory: ProjectInventory

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: inventory.hasPodfile ? "doc.text.fill" : "questionmark.folder.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(inventory.hasPodfile ? Theme.orange : Theme.yellow)
                    .frame(width: 22)
                HStack(spacing: 6) {
                        Text(AppStore.displayName(inventory.podfileDir))
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if store.podfileCandidates.count > 1 {
                            Menu {
                                ForEach(store.podfileCandidates, id: \.self) { path in
                                    Button(relative(path)) { store.choosePodfile(path) }
                                }
                            } label: {
                                Text("\(store.podfileCandidates.count) Podfiles")
                                    .font(.system(size: 10.5, weight: .medium))
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                }
                Spacer(minLength: 4)
                SyncBadge(sync: inventory.sync, hasPodfile: inventory.hasPodfile)
                Button { inventory.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Rescan")
                .disabled(inventory.isMeasuring)
            }
            Text(subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 32)
            if inventory.podfileChangedSinceInstall {
                Label("Podfile changed since the last install. Press Install to apply it.", systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.orange)
            }
        }
        .card(padding: 11)
        .help(inventory.podfileDir)
    }

    private var subtitle: String {
        guard inventory.hasPodfile else { return "No Podfile in this folder" }
        guard inventory.sync != .noLockfile else { return "Podfile found · never installed (no Podfile.lock)" }
        var parts: [String] = []
        if let version = inventory.cocoapodsVersion { parts.append("CocoaPods \(version)") }
        parts.append("\(inventory.dependencyCount) dependencies")
        if let date = inventory.lockModified {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            parts.append("installed \(formatter.localizedString(for: date, relativeTo: Date()))")
        }
        return parts.joined(separator: " · ")
    }

    private func relative(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

struct SyncBadge: View {
    let sync: SyncState
    let hasPodfile: Bool

    var body: some View {
        let (text, icon, color): (String, String, Color) = switch sync {
        case .inSync: ("In sync", "checkmark.circle.fill", Theme.green)
        case .outOfSync: ("Out of sync", "arrow.triangle.2.circlepath", Theme.orange)
        case .notInstalled: ("Not installed", "arrow.down.circle", Theme.orange)
        case .noLockfile: (hasPodfile ? "New" : "No Podfile", "circle.dashed", .secondary)
        }
        Label(text, systemImage: icon)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.13), in: Capsule())
            .help(help)
    }

    private var help: String {
        switch sync {
        case .inSync: "Pods/ matches Podfile.lock"
        case .outOfSync: "Pods/ was installed from a different Podfile.lock. Run pod install."
        case .notInstalled: "Podfile.lock exists but Pods/ doesn't. Run pod install."
        case .noLockfile: "No Podfile.lock yet"
        }
    }
}

struct InventoryStats: View {
    let inventory: ProjectInventory

    var body: some View {
        HStack(spacing: 8) {
            StatTile(icon: "shippingbox.fill", tint: Theme.orange,
                     value: inventory.isLoaded ? "\(inventory.pods.count)" : "–", label: "Pods")
            StatTile(icon: "checkmark.circle.fill", tint: Theme.green,
                     value: inventory.isLoaded ? "\(inventory.installedCount)/\(inventory.pods.count)" : "–", label: "Installed")
            StatTile(icon: "internaldrive.fill", tint: Theme.purple,
                     value: measured(inventory.podsFolderBytes), label: "On disk")
            StatTile(icon: "archivebox.fill", tint: Theme.blue,
                     value: inventory.isMeasuring ? "…" : Fmt.bytes(inventory.cacheBytes), label: "In cache")
        }
    }

    private func measured(_ bytes: Int64?) -> String {
        if let bytes { return Fmt.bytes(bytes) }
        return inventory.isMeasuring ? "…" : "–"
    }
}

struct NoPodsCard: View {
    let inventory: ProjectInventory

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: inventory.hasPodfile ? "shippingbox" : "questionmark.folder")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text(inventory.hasPodfile ? "No pods installed yet" : "No Podfile found here")
                .font(.system(size: 13, weight: .semibold))
            Text(inventory.hasPodfile
                 ? "Press Install to run pod install. Podfile.lock and the pod list will show up here."
                 : "Choose the folder that contains your Podfile, or a project folder with an ios/ folder.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .card(padding: 16)
    }
}

struct InventoryList: View {
    let inventory: ProjectInventory
    let colors: [String: Color]

    var body: some View {
        let pods = inventory.pods
        let notInstalled = pods.filter { $0.state == .missing || $0.state == .cachedOnly }
        let installed = pods.filter { $0.state == .installed }.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        let local = pods.filter { $0.state == .local }.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        let maxBytes = installed.compactMap(\.bytes).max() ?? 0

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if !inventory.isLoaded {
                    HStack(spacing: 8) {
                        Spinner(color: Theme.blue).frame(width: 13, height: 13)
                        Text("Reading Podfile.lock…").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    .padding(12)
                }
                if !notInstalled.isEmpty {
                    let cached = notInstalled.filter { $0.state == .cachedOnly }.count
                    SectionTitle(title: "Not installed", count: notInstalled.count,
                                 trailing: "\(cached) in cache · \(notInstalled.count - cached) to download")
                    ForEach(notInstalled) { InventoryRow(pod: $0, maxBytes: maxBytes, color: .secondary, measuring: inventory.isMeasuring) }
                }
                if !installed.isEmpty {
                    SectionTitle(title: "Installed in Pods/", count: installed.count,
                                 trailing: inventory.isMeasuring ? "measuring…" : Fmt.bytes(inventory.installedBytes))
                    ForEach(installed) { pod in
                        InventoryRow(pod: pod, maxBytes: maxBytes, color: colors[pod.name] ?? Color.secondary.opacity(0.5),
                                     measuring: inventory.isMeasuring)
                    }
                }
                if !local.isEmpty {
                    SectionTitle(title: "Local pods", count: local.count,
                                 trailing: local.contains { $0.localPathLabel?.contains(".symlinks/plugins/") == true } ? "Flutter plugins & :path pods" : ":path pods")
                    ForEach(local) { InventoryRow(pod: $0, maxBytes: maxBytes, color: Theme.teal, measuring: inventory.isMeasuring) }
                }
            }
            .padding(.bottom, 8)
        }
    }
}

struct InventoryRow: View {
    let pod: InventoryPod
    let maxBytes: Int64
    let color: Color
    let measuring: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(pod.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    Text(pod.version)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    sizeText
                }
                HStack(spacing: 8) {
                    if pod.state == .installed {
                        let fraction = maxBytes > 0 ? CGFloat(pod.bytes ?? 0) / CGFloat(maxBytes) : 0
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.track)
                            if fraction > 0 { Capsule().fill(color).frame(width: max(3, 56 * fraction)) }
                        }
                        .frame(width: 56, height: 4)
                    }
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .help(pod.localPath ?? pod.gitURL ?? "\(pod.name) \(pod.version)")
    }

    @ViewBuilder private var icon: some View {
        switch pod.state {
        case .installed:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 15)).foregroundStyle(Theme.green)
        case .local:
            Image(systemName: "folder.circle.fill").font(.system(size: 15)).foregroundStyle(Theme.teal)
        case .cachedOnly:
            Image(systemName: "bolt.circle.fill").font(.system(size: 15)).foregroundStyle(Theme.blue)
        case .missing:
            Image(systemName: "arrow.down.circle").font(.system(size: 15)).foregroundStyle(Theme.orange)
        }
    }

    @ViewBuilder private var sizeText: some View {
        let bytes = pod.state == .cachedOnly ? pod.cacheBytes : pod.bytes
        if let bytes, bytes > 0 {
            Text(Fmt.bytes(bytes))
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(pod.state == .cachedOnly ? .secondary : .primary)
        } else if measuring && pod.state != .missing {
            Text("…").font(.system(size: 11.5)).foregroundStyle(.tertiary)
        } else {
            Text("—").font(.system(size: 11.5)).foregroundStyle(.tertiary)
        }
    }

    private var detail: String {
        let cache = pod.cacheBytes.flatMap { $0 > 0 ? Fmt.bytes($0) : nil }
        switch pod.state {
        case .installed:
            var parts = [pod.gitURL != nil ? "In Pods/ · from git" : "In Pods/"]
            if let cache { parts.append("\(cache) in download cache") }
            return parts.joined(separator: " · ")
        case .local:
            if let label = pod.localPathLabel, label.contains(".symlinks/plugins/") { return "Flutter plugin · lives in the pub cache" }
            return "Local pod · " + (pod.localPathLabel ?? "")
        case .cachedOnly:
            return "Not in Pods/ · in download cache, installs without downloading"
        case .missing:
            if pod.localPath != nil { return "Local folder missing. Run flutter pub get (or check the :path)." }
            let others = pod.cachedVersions.filter { $0 != pod.version }
            if !others.isEmpty { return "Needs download · cache only has \(others.prefix(3).joined(separator: ", "))" }
            return "Not on this Mac · will be downloaded"
        }
    }
}
