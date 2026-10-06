import PodVizCore
import SwiftUI

enum DetailTab: String, CaseIterable {
    case pods, network, log

    var title: String {
        switch self {
        case .pods: "Pods"
        case .network: "Network"
        case .log: "Log"
        }
    }
}

struct ContentView: View {
    static let width: CGFloat = 400
    /// Snapshots can render taller to check long lists.
    nonisolated(unsafe) static var height: CGFloat = 640

    @Environment(AppStore.self) private var store
    @State private var tab: DetailTab

    init(initialTab: DetailTab = .pods) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            Divider().opacity(0.5)
            if store.session?.isRunning == false && store.inventory != nil {
                ModeSwitcher()
            }
            Group {
                if store.showingSession, let session = store.session {
                    SessionView(session: session, tab: $tab)
                } else if let inventory = store.inventory {
                    ProjectOverviewView(inventory: inventory)
                } else {
                    EmptyStateView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.5)
            FooterView()
        }
        .frame(width: Self.width, height: Self.height)
        .dropDestination(for: URL.self) { urls, _ in
            store.selectProject(urls.first)
            return urls.first != nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            store.hasUnseenResult = false
        }
    }
}

// MARK: - Header

struct HeaderView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 10) {
            AppGlyph(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("PodViz")
                    .font(.system(size: 13.5, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if store.showingSession, let session = store.session {
                VStack(alignment: .trailing, spacing: 4) {
                    StatusPill(session: session)
                    ElapsedLabel(session: session)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var subtitle: String {
        if store.showingSession, let session = store.session {
            let origin = session.origin == .terminal ? " · Terminal" : ""
            return "\(AppStore.displayName(session.projectPath)) · \(session.command)\(origin)"
        }
        return store.selectedProject.map(AppStore.displayName) ?? "CocoaPods install monitor"
    }
}

struct StatusPill: View {
    let session: PodSession

    var body: some View {
        let color = Theme.color(for: session.phase)
        HStack(spacing: 5) {
            PulseDot(color: color, pulsing: session.isRunning)
            Text(session.phase == .failed && session.activity == "Stopped" ? "Stopped" : session.phase.title)
                .font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.13), in: Capsule())
    }
}

struct ElapsedLabel: View {
    let session: PodSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Label(Fmt.clock(session.elapsed(at: context.date)), systemImage: "clock")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Session

struct SessionView: View {
    let session: PodSession
    @Binding var tab: DetailTab

    var body: some View {
        let items = session.pods.map { SizeItem(name: $0.name, bytes: $0.displayBytes) }
        let colors = Theme.sizeColors(items)
        VStack(spacing: 10) {
            ProgressCard(session: session)
            StatsRow(session: session)
            if session.phase == .failed, let error = session.errorMessage, session.activity != "Stopped" {
                ErrorBanner(message: error)
            } else if session.hasSizes {
                let total = items.reduce(Int64(0)) { $0 + $1.bytes }
                SizeBreakdownView(items: items, colors: colors, trailing: session.podsFolderBytes.flatMap {
                    $0 > 0 ? "Pods folder \(Fmt.bytes($0))" : nil
                } ?? "\(Fmt.bytes(total)) total")
            }
            DetailTabs(session: session, tab: $tab, colors: colors)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }
}

struct ModeSwitcher: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Picker("Show", selection: $store.mainView) {
            Text("Project").tag(MainView.project)
            Text("Last run").tag(MainView.run)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }
}

struct ProgressCard: View {
    let session: PodSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.activity)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if session.bytesPerSecond > 1024 {
                    Label(Fmt.speed(session.bytesPerSecond), systemImage: "arrow.down")
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.blue)
                }
                Text("\(Int(session.progress * 100))%")
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            GradientBar(value: session.progress, failed: session.phase == .failed, live: session.isRunning)
            PhaseTrack(session: session)
        }
        .card()
    }
}

struct PhaseTrack: View {
    let session: PodSession

    enum StepState { case pending, active, complete, failed }

    private let steps: [(phase: Phase, label: String)] = [
        (.analyzing, "Resolve"), (.downloading, "Download"), (.generating, "Generate"), (.integrating, "Integrate"),
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                StepNode(state: state(of: step.phase), label: step.label)
                if index < steps.count - 1 {
                    Capsule()
                        .fill(state(of: steps[index + 1].phase) == .pending ? AnyShapeStyle(Theme.track) : AnyShapeStyle(Theme.green.opacity(0.55)))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func state(of phase: Phase) -> StepState {
        switch session.phase {
        case .done:
            return .complete
        case .failed:
            let at = max(session.failedDuring ?? .analyzing, .analyzing)
            return phase < at ? .complete : (phase == at ? .failed : .pending)
        default:
            let current = max(session.phase, .analyzing)
            return phase < current ? .complete : (phase == current ? .active : .pending)
        }
    }
}

struct StepNode: View {
    let state: PhaseTrack.StepState
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Group {
                switch state {
                case .complete:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                case .failed:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.red)
                case .active:
                    ZStack {
                        Circle().strokeBorder(Theme.orange.opacity(0.35), lineWidth: 1.5)
                        Spinner(color: Theme.orange, lineWidth: 1.5)
                    }
                case .pending:
                    Circle().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1.5)
                }
            }
            .font(.system(size: 12))
            .frame(width: 12, height: 12)
            Text(label)
                .font(.system(size: 10.5, weight: state == .active ? .semibold : .medium))
                .foregroundStyle(state == .pending ? .tertiary : (state == .active ? .primary : .secondary))
        }
        .fixedSize()
    }
}

struct StatsRow: View {
    let session: PodSession

    var body: some View {
        HStack(spacing: 8) {
            podsTile
            StatTile(icon: "arrow.down.circle.fill", tint: Theme.blue,
                     value: Fmt.bytes(session.downloadedBytes), label: "Fetched")
            StatTile(icon: "internaldrive.fill", tint: Theme.purple,
                     value: Fmt.bytes(session.diskBytes), label: "On disk")
            StatTile(icon: "network", tint: Theme.teal,
                     value: Fmt.count(session.requests.count), label: "Requests")
        }
    }

    @ViewBuilder private var podsTile: some View {
        if !session.sawManifest && session.pods.isEmpty {
            StatTile(icon: "shippingbox.fill", tint: Theme.orange, value: "–", label: "Pods")
        } else if session.plannedCount == 0 {
            StatTile(icon: "checkmark.seal.fill", tint: Theme.green, value: "\(session.totalPodCount)", label: "Up to date")
        } else {
            StatTile(icon: "shippingbox.fill", tint: Theme.orange,
                     value: "\(session.installedCount)/\(session.plannedCount)", label: "Installed")
        }
    }
}

struct StatTile: View {
    let icon: String
    let tint: Color
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(tint)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 9)
    }
}

struct SizeItem: Identifiable {
    var id: String { name }
    let name: String
    let bytes: Int64
}

struct SizeBreakdownView: View {
    let items: [SizeItem]
    let colors: [String: Color]
    let trailing: String

    var body: some View {
        let ranked = items.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        let total = max(ranked.reduce(Int64(0)) { $0 + $1.bytes }, 1)
        let top = ranked.prefix(Theme.palette.count)
        let rest = ranked.dropFirst(Theme.palette.count).reduce(Int64(0)) { $0 + $1.bytes }
        let segments = top.map { (name: $0.name, bytes: $0.bytes, color: colors[$0.name] ?? .gray) }
            + (rest > 0 ? [(name: "Other", bytes: rest, color: Color.gray.opacity(0.5))] : [])

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Size by pod")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer()
                Text(trailing)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let gaps = CGFloat(max(segments.count - 1, 0)) * 2
                HStack(spacing: 2) {
                    ForEach(segments, id: \.name) { segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: max(2, (geo.size.width - gaps) * CGFloat(segment.bytes) / CGFloat(total)))
                            .help("\(segment.name) · \(Fmt.bytes(segment.bytes))")
                    }
                }
            }
            .frame(height: 9)
            .clipShape(Capsule())
            .animation(.easeOut(duration: 0.4), value: total)

            FlowLayout(spacing: 10, lineSpacing: 4) {
                ForEach(segments.prefix(5), id: \.name) { segment in
                    HStack(spacing: 4) {
                        Circle().fill(segment.color).frame(width: 6, height: 6)
                        Text(segment.name).font(.system(size: 10.5, weight: .medium))
                        Text(Fmt.bytes(segment.bytes))
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if segments.count > 5 {
                    Text("+\(ranked.count - 5) more")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .card()
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.red)
            Text(message)
                .font(.system(size: 11.5))
                .lineLimit(4)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.red.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.red.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - Tabs

struct DetailTabs: View {
    let session: PodSession
    @Binding var tab: DetailTab
    let colors: [String: Color]
    @Namespace private var selection

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(DetailTab.allCases, id: \.self) { item in
                    Button {
                        withAnimation(.spring(duration: 0.25)) { tab = item }
                    } label: {
                        HStack(spacing: 5) {
                            Text(item.title)
                                .font(.system(size: 11.5, weight: tab == item ? .semibold : .medium))
                            if let count = count(for: item) {
                                Text(count)
                                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.primary.opacity(0.07), in: Capsule())
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background {
                            if tab == item {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
                                    .shadow(color: .black.opacity(0.1), radius: 1.5, y: 0.5)
                                    .matchedGeometryEffect(id: "tab", in: selection)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2.5)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.card))

            Group {
                switch tab {
                case .pods: PodsTab(session: session, colors: colors)
                case .network: NetworkTab(session: session)
                case .log: LogTab(session: session)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func count(for tab: DetailTab) -> String? {
        switch tab {
        case .pods: session.pods.isEmpty ? nil : "\(session.totalPodCount)"
        case .network: session.requests.isEmpty ? nil : Fmt.count(session.requests.count)
        case .log: nil
        }
    }
}
