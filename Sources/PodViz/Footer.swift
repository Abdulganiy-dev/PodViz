import AppKit
import PodVizCore
import SwiftUI

struct FooterView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 8) {
            Menu {
                if !store.recentProjects.isEmpty {
                    Section("Recent") {
                        ForEach(store.recentProjects, id: \.self) { path in
                            Button {
                                store.selectProject(URL(fileURLWithPath: path))
                            } label: {
                                if path == store.selectedProject {
                                    Label(AppStore.displayName(path), systemImage: "checkmark")
                                } else {
                                    Text(AppStore.displayName(path))
                                }
                            }
                        }
                    }
                }
                Button("Choose Folder…") { store.chooseFolder() }
            } label: {
                Label(projectTitle, systemImage: "folder")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .help(store.selectedProject ?? "Choose a project folder")

            Spacer(minLength: 6)

            if store.isRunning {
                if store.session?.origin == .app {
                    Button { store.stop() } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(SoftButtonStyle(tint: Theme.red))
                } else {
                    Label("Running in Terminal", systemImage: "terminal")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Update") { store.run(.update) }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(!store.canRun)
                    .help("pod update")
                Button { store.run(.install) } label: {
                    Label("Install", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!store.canRun)
                .keyboardShortcut(.defaultAction)
                .help(store.repoUpdate ? "pod install --repo-update" : "pod install")
            }

            Menu {
                Toggle("Update spec repos on install (--repo-update)", isOn: $store.repoUpdate)
                Divider()
                Button("Show Pods Folder in Finder") { store.revealPods() }
                    .disabled(store.selectedProject == nil && store.session == nil)
                Button("Copy Log") { store.copyLog() }
                    .disabled(store.session == nil)
                Button("Clear Results") { store.clearSession() }
                    .disabled(store.session == nil || store.isRunning)
                Divider()
                if store.cliInstalled {
                    Text("Terminal command installed: podviz")
                } else {
                    Button("Install “podviz” Terminal Command") { store.installCLI() }
                }
                Toggle("Launch at Login", isOn: Binding(get: { LoginItem.isEnabled }, set: { LoginItem.set($0) }))
                Divider()
                Button("Quit PodViz") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            if let notice = store.notice {
                Text(notice)
                    .font(.system(size: 10.5, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().strokeBorder(Theme.cardStroke))
                    .offset(y: -16)
                    .onTapGesture { store.notice = nil }
            }
        }
    }

    private var projectTitle: String {
        guard let path = store.selectedProject else { return "Choose Project" }
        let name = AppStore.displayName(path)
        return name.count > 26 ? String(name.prefix(25)) + "…" : name
    }
}

struct EmptyStateView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            AppGlyph(size: 58)
            VStack(spacing: 6) {
                Text("Watch your pods install")
                    .font(.system(size: 16, weight: .semibold))
                Text("See what's installing, how big each pod is, and every network request in real time.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 290)
            }

            if let project = store.selectedProject {
                projectCard(project)
            } else {
                Button { store.chooseFolder() } label: {
                    Label("Choose a Project Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(PrimaryButtonStyle())
            }

            terminalCard
            Spacer()
            Text("Tip: drop a project folder or Podfile here")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 10)
        }
        .padding(.horizontal, 22)
    }

    private func projectCard(_ path: String) -> some View {
        let hasPodfile = AppStore.hasPodfile(path)
        let locked = AppStore.lockedPodCount(path)
        return HStack(spacing: 10) {
            Image(systemName: hasPodfile ? "doc.text.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(hasPodfile ? Theme.orange : Theme.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppStore.displayName(path))
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(hasPodfile ? (locked.map { "Podfile · \($0) pods in Podfile.lock" } ?? "Podfile · not installed yet") : "No Podfile in this folder")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .card(padding: 11)
    }

    private var terminalCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Or from Terminal")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack {
                Text("podviz install")
                    .font(.system(size: 12, design: .monospaced))
                Spacer()
                if store.cliInstalled {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("podviz install", forType: .string)
                        store.notice = "Copied"
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy")
                } else {
                    Button("Install Command") { store.installCLI() }
                        .buttonStyle(SoftButtonStyle())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.06)))
            Text("Runs pod with your usual arguments and streams progress here.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .card(padding: 11)
    }
}
