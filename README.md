# PodViz

A macOS menu bar app that shows a CocoaPods install as it happens: what is installing, how many pods are
planned, the size of each pod and the total, and every network request CocoaPods makes.

## Build and run

```bash
./build.sh --open       # build build/PodViz.app and launch it
./build.sh --install    # copy to /Applications and launch from there
```

Requires macOS 14+ and the Xcode command line tools. The app lives in the menu bar (no Dock icon).

## Two ways to use it

**From the menu bar.** Pick a folder with a Podfile (or drop one on the popover), then press
**Install** or **Update**. Flutter and React Native projects are detected through their `ios/` folder, and
`bundle exec pod` is used when a Gemfile pins CocoaPods.

**From Terminal.** Choose *Install "podviz" Terminal Command* in the ⋯ menu (it links
`~/.local/bin/podviz`), then run it wherever you'd run `pod`:

```bash
podviz install
podviz update Alamofire
podviz install --repo-update
```

`podviz` runs `pod` with `--verbose --no-ansi`, tees the output to `~/.podviz/runs/`, and the app picks it up
live. Exit codes pass through unchanged, and the terminal hides the noisy CDN debug lines.

## Project overview

When nothing is running, PodViz shows the selected project. You can pick any folder: it finds the Podfile up to
four levels down, skipping `Pods`, `node_modules` and build folders. If there are several, such as `ios/` and
`macos/`, you can switch between them. The overview shows:

- the CocoaPods version, the dependency count and when the project was last installed
- whether `Pods/` is in sync with `Podfile.lock`, and a warning if the Podfile changed since that install
- every pod in `Podfile.lock` and its state: installed in `Pods/`, local (Flutter plugins and `:path` pods),
  in the CocoaPods download cache only (installs without downloading), or still to be downloaded
- disk space: each pod, the whole `Pods/` folder, and the download cache those pods use

After a run you can switch between **Project** and **Last run**.

## What it shows during a run

| | Source |
|---|---|
| Pods to install / up to date / removed | The `A`/`M`/`-`/`R` lines under *Comparing resolved specification to the sandbox manifest* |
| Per-pod progress | `-> Installing X`, `> Git download`, `> Copying X from cache`, `-> Using X` |
| Fetched bytes, live speed | Size of the in-flight `git clone` pack or `curl` archive, sampled every 0.5s |
| Size of each pod | `Pods/<Name>` on disk after it installs; the total and the whole `Pods/` folder at the end |
| Network requests | CDN spec fetches (200 / 302 redirect / 304 / 404, with sizes), `git clone`/`fetch`/`ls-remote`, `curl` downloads |

Very fast clones can finish between samples; their fetched size falls back to the cached copy's size.

## Login item and agent skill

- `PodViz.app/Contents/MacOS/PodViz --login-item on|off|status` registers it with `SMAppService` (also in the ⋯ menu).
- `Skill/podviz` is an agent skill for Claude Code and Codex. It ships inside the app at
  `Contents/Resources/Agent-Skill/podviz`, and `~/.claude/skills/podviz` and `~/.codex/skills/podviz` are symlinks
  to it, so reinstalling the app updates the skill. Its `scripts/podviz_summary.py` summarizes any run log for agents
  that can't see the menu bar.

## Layout

- `Sources/PodVizCore`: line parser (`LineParser`) and live session model (`PodSession`), with no UI.
- `Sources/PodViz`: SwiftUI `MenuBarExtra` app, process runner, and the Terminal-run watcher.
- `Sources/pvreplay`: `swift run pvreplay <log> --cwd <project>` replays a saved verbose log through the
  parser and prints what it found.

Debug helper: `PodViz --snapshot out.png --log <verbose.log> --cwd <project> [--tab network] [--dark]` renders
the popover for a log to a PNG.
