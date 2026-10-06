import AppKit
import PodVizCore
import SwiftUI

// MARK: - Pods

struct PodsTab: View {
    let session: PodSession
    let colors: [String: Color]

    var body: some View {
        let planned = session.pods.filter { $0.isPlanned || $0.change == .unknown }
        let upToDate = session.pods.filter { $0.change == .unchanged }
        let removed = session.pods.filter { $0.change == .removed }
        let maxBytes = session.pods.map(\.displayBytes).max() ?? 0

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if session.pods.isEmpty {
                        ResolvingPlaceholder(session: session)
                    }
                    if !planned.isEmpty {
                        SectionTitle(title: "To install", count: planned.count,
                                     trailing: session.isRunning ? "\(session.installedCount) done" : nil)
                        rows(planned, maxBytes: maxBytes)
                    }
                    if !upToDate.isEmpty {
                        SectionTitle(title: "Already up to date", count: upToDate.count, trailing: nil)
                        rows(upToDate, maxBytes: maxBytes)
                    }
                    if !removed.isEmpty {
                        SectionTitle(title: "Removed", count: removed.count, trailing: nil)
                        rows(removed, maxBytes: maxBytes)
                    }
                }
                .padding(.bottom, 8)
            }
            .onChange(of: session.currentPod) { _, name in
                guard let name else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(name, anchor: .center) }
            }
        }
    }

    private func rows(_ pods: [PodItem], maxBytes: Int64) -> some View {
        ForEach(pods) { pod in
            PodRow(pod: pod, maxBytes: maxBytes, color: colors[pod.name] ?? Color.secondary.opacity(0.5),
                   isCurrent: pod.name == session.currentPod)
                .id(pod.name)
        }
    }
}

struct SectionTitle: View {
    let title: String
    let count: Int
    let trailing: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 3)
    }
}

struct ResolvingPlaceholder: View {
    let session: PodSession

    var body: some View {
        HStack(spacing: 10) {
            if session.isRunning {
                Spinner(color: Theme.blue).frame(width: 14, height: 14)
            } else {
                Image(systemName: "shippingbox").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.isRunning ? "Working out what to install…" : "No pods were processed")
                    .font(.system(size: 12, weight: .medium))
                Text(session.requests.isEmpty ? session.activity : "\(Fmt.count(session.requests.count)) spec requests so far")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }
}

struct PodRow: View {
    let pod: PodItem
    let maxBytes: Int64
    let color: Color
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 10) {
            PodStatusIcon(pod: pod)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(pod.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    versionText
                    changeBadge
                    Spacer(minLength: 4)
                    Text(pod.displayBytes > 0 ? Fmt.bytes(pod.displayBytes) : "—")
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(pod.displayBytes > 0 ? .primary : .tertiary)
                        .contentTransition(.numericText())
                }
                HStack(spacing: 8) {
                    sizeMeter
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isCurrent ? Theme.orange.opacity(0.1) : .clear)
        )
        .opacity(pod.status == .removed ? 0.6 : 1)
        .help(pod.remoteURL ?? pod.name)
    }

    @ViewBuilder private var versionText: some View {
        if let version = pod.version {
            if let previous = pod.previousVersion {
                Text("\(previous) → \(version)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(version)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder private var changeBadge: some View {
        switch pod.change {
        case .added: Badge(text: "NEW", color: Theme.green)
        case .changed: Badge(text: "UPDATE", color: Theme.orange)
        default: EmptyView()
        }
    }

    private var sizeMeter: some View {
        let fraction = maxBytes > 0 ? CGFloat(pod.displayBytes) / CGFloat(maxBytes) : 0
        return ZStack(alignment: .leading) {
            Capsule().fill(Theme.track)
            if fraction > 0 {
                Capsule().fill(color).frame(width: max(3, 56 * fraction))
            }
        }
        .frame(width: 56, height: 4)
        .animation(.easeOut(duration: 0.4), value: fraction)
    }

    private var detail: String {
        switch pod.status {
        case .queued:
            return "Waiting"
        case .downloading:
            let via = pod.source == .unknown ? "" : " via \(pod.source.label)"
            return pod.downloadBytes > 0 ? "Downloading\(via) · \(Fmt.bytes(pod.downloadBytes))" : "Downloading\(via)…"
        case .installing:
            return pod.source == .cache ? "Copying from cache…" : "Installing…"
        case .done:
            var parts: [String]
            switch pod.source {
            case .git, .http, .other: parts = ["Downloaded via \(pod.source.label)"]
            case .local: parts = ["Local pod"]
            default: parts = ["Installed"]
            }
            if pod.source.isRemote && pod.downloadBytes > 0 { parts.append("\(Fmt.bytes(pod.downloadBytes)) fetched") }
            if let d = pod.duration, d >= 0.05 { parts.append(Fmt.duration(d)) }
            return parts.joined(separator: " · ")
        case .cached:
            return ["From download cache", pod.duration.flatMap { $0 >= 0.05 ? Fmt.duration($0) : nil }].compactMap { $0 }.joined(separator: " · ")
        case .upToDate:
            return "Already installed"
        case .removed:
            return "Removed from project"
        case .failed:
            return "Failed"
        }
    }
}

struct PodStatusIcon: View {
    let pod: PodItem

    var body: some View {
        switch pod.status {
        case .queued:
            Image(systemName: "circle.dashed")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
        case .downloading:
            ZStack {
                Circle().stroke(Theme.orange.opacity(0.2), lineWidth: 2)
                Spinner(color: Theme.orange)
                Image(systemName: "arrow.down")
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(Theme.orange)
            }
        case .installing:
            ZStack {
                Circle().stroke(Theme.purple.opacity(0.2), lineWidth: 2)
                Spinner(color: Theme.purple)
            }
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Theme.green)
        case .cached:
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Theme.blue)
        case .upToDate:
            Image(systemName: "checkmark.circle")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        case .removed:
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Theme.red.opacity(0.8))
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Theme.red)
        }
    }
}

// MARK: - Network

struct NetworkTab: View {
    let session: PodSession
    @State private var filter: RequestKind?

    var body: some View {
        let items = filtered
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                FilterChip(title: "All", count: session.requests.count, tint: .primary, selected: filter == nil) { filter = nil }
                ForEach(RequestKind.allCases, id: \.self) { kind in
                    let count = session.requestCounts[kind] ?? 0
                    if count > 0 {
                        FilterChip(title: kind.label, count: count, tint: Theme.color(for: kind), selected: filter == kind) {
                            filter = kind
                        }
                    }
                }
                Spacer(minLength: 0)
                if session.localCacheHits > 0 {
                    Label(Fmt.count(session.localCacheHits), systemImage: "internaldrive")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .help("\(session.localCacheHits) spec files served from the local CDN cache (no request)")
                }
            }
            .padding(.horizontal, 2)

            if items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "network").font(.system(size: 20)).foregroundStyle(.tertiary)
                    Text(session.isRunning ? "Waiting for the first request…" : "No network requests")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { request in
                            NetRow(request: request)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    /// Newest first, so live activity stays at the top.
    private var filtered: [NetRequest] {
        let newestFirst = session.requests.reversed()
        guard let filter else { return Array(newestFirst) }
        return newestFirst.filter { $0.kind == filter }
    }
}

struct FilterChip: View {
    let title: String
    let count: Int
    let tint: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 10.5, weight: .semibold))
                Text(Fmt.count(count))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .opacity(0.7)
            }
            .foregroundStyle(selected ? tint : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(Capsule().fill(selected ? tint.opacity(0.14) : Color.primary.opacity(0.05)))
        }
        .buttonStyle(.plain)
    }
}

struct NetRow: View {
    let request: NetRequest

    var body: some View {
        HStack(spacing: 9) {
            Text(request.kind.label.uppercased())
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.color(for: request.kind))
                .frame(width: 34, height: 18)
                .background(Theme.color(for: request.kind).opacity(0.13), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(request.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(request.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                statusView
                Text(metric)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .help(request.url)
        .contextMenu {
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(request.url, forType: .string)
            }
        }
    }

    @ViewBuilder private var statusView: some View {
        if request.state == .running {
            HStack(spacing: 4) {
                Spinner(color: Theme.blue, lineWidth: 1.5).frame(width: 9, height: 9)
                Text("LIVE").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(Theme.blue)
            }
        } else {
            Text(statusText)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(statusColor)
        }
    }

    private var statusText: String {
        if let status = request.status { return "\(status)" }
        return request.state == .failed ? "ERR" : "OK"
    }

    private var statusColor: Color {
        switch request.state {
        case .ok: Theme.green
        case .redirect: Theme.blue
        case .notModified: .secondary
        case .failed: Theme.red
        case .running: Theme.blue
        }
    }

    private var metric: String {
        if let bytes = request.bytes, bytes > 0 { return Fmt.bytes(bytes) }
        switch request.state {
        case .redirect: return "redirect"
        case .notModified: return "not modified"
        case .failed: return "failed"
        case .running: return "…"
        case .ok:
            if let finished = request.finishedAt, request.kind != .cdn {
                return Fmt.duration(finished.timeIntervalSince(request.startedAt))
            }
            return request.verb
        }
    }
}

// MARK: - Log

struct LogTab: View {
    let session: PodSession
    private let visible = 1500

    var body: some View {
        let log = session.log
        let start = max(0, log.count - visible)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if start > 0 {
                        Text("… \(start) earlier lines (Copy Log for everything)")
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(start..<log.count, id: \.self) { i in
                        Text(log[i].isEmpty ? " " : log[i])
                            .foregroundStyle(color(for: log[i]))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .padding(9)
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.06)))
            .padding(.bottom, 8)
            .onAppear { proxy.scrollTo(log.count - 1, anchor: .bottom) }
            .onChange(of: log.count) { _, count in
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
    }

    private func color(for line: String) -> Color {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("[!]") { return Theme.orange }
        if t.hasPrefix("-> Installing") || t.hasPrefix("-> Downloading") || t.hasPrefix("-> Pod installation") { return Theme.green }
        if t.hasPrefix("$ ") { return Theme.blue }
        if t.hasPrefix("CDN:") { return .secondary }
        return .primary
    }
}
