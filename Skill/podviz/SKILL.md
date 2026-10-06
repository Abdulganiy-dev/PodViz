---
name: podviz
description: "Run CocoaPods through PodViz so the user can watch it live in their menu bar, and summarize what a pod install/update did: pods planned vs installed, size of each pod, the whole Pods folder, and every network request. Use this whenever you are about to run `pod install` or `pod update` (native iOS, Flutter ios/, React Native ios/), when the user asks why pod install is slow, stuck or failing, what is being downloaded, how big their pods are, or mentions PodViz, podviz, or the pod install visualizer, even if they don't name the tool."
---

# PodViz

PodViz is the user's macOS menu bar app (`/Applications/PodViz.app`, starts at login) that visualizes CocoaPods runs. It shows what is installing, how many pods are planned, each pod's size and the total, and every network request (CDN spec fetches, git clones, HTTP downloads).

It can only see runs that go through it. A plain `pod install` is invisible to it, which is why you should use the `podviz` command instead.

## Running CocoaPods

Run `podviz` wherever you would run `pod`, from the folder that contains the Podfile. For Flutter and React Native that is the `ios/` folder.

```bash
podviz install                 # = pod install
podviz update Alamofire        # = pod update Alamofire
podviz install --repo-update
```

- Arguments pass straight through to `pod`, and the exit code is pod's own, so you can treat it exactly like `pod`.
- It runs `pod … --verbose --no-ansi`. It switches to `bundle exec pod` automatically when a Gemfile with a lockfile pins CocoaPods.
- It writes the full log to `~/.podviz/runs/<timestamp>-<pid>.log`, and the menu bar app follows that log live.
- The terminal output hides the noisy `CDN:` lines but is still verbose. To keep your context small, pipe it through `tail -n 30` and use the summary script below for details.
- Installs can take many minutes (big git clones such as TensorFlow or Firebase). Run long installs in the background, then check progress with the summary script instead of waiting blindly.
- Only `install` and `update` produce a useful visualization. Commands like `pod deintegrate`, `pod outdated` or `pod repo update` are fine with plain `pod`.

If `podviz` is not on PATH, use `~/.podviz/bin/podviz` directly. The user's PATH normally includes `~/.local/bin`, where the command is linked.

## Summarizing a run

You can't see the menu bar, so read the run log with the bundled script. It prints:
- the status (running, succeeded, failed or stopped)
- the install plan, i.e. new, updated, up-to-date and removed pods
- how each pod arrived (git, HTTP, download cache or local)
- each pod's size in `Pods/` and the whole `Pods/` folder size
- network request counts by type, with CDN status codes and the git/HTTP URLs
- CocoaPods' `[!]` messages

```bash
python3 <this skill's folder>/scripts/podviz_summary.py            # newest run
python3 <this skill's folder>/scripts/podviz_summary.py --list     # recent runs
python3 <this skill's folder>/scripts/podviz_summary.py <log> --json
```

This skill's folder is the directory containing this SKILL.md. It is usually `~/.claude/skills/podviz` or `~/.codex/skills/podviz`, both symlinks into `/Applications/PodViz.app/Contents/Resources/Agent-Skill/podviz`. The script also works on any `pod install --verbose --no-ansi` output. Pass `--cwd <project>` when the log has no `#PODVIZ cwd=` header.

When reporting to the user, lead with the outcome and the numbers they asked about. For example: "Installed 7 of 7 pods in 2m 10s; the biggest are FirebaseFirestore (48 MB) and gRPC-Core (31 MB); 1,204 CDN requests plus 6 git clones." Don't paste the whole table unless they want it.

## Reading a log by hand

The summary script covers most needs. These patterns help when you want to grep:

| Line | Meaning |
|---|---|
| `#PODVIZ cwd=… / cmd=… / pid=… / exit=N` | Header and footer written by `podviz` |
| `A Name` / `M Name` / `- Name` / `R Name` under *Comparing resolved specification to the sandbox manifest* | The plan: added, changed, unchanged, removed |
| `-> Installing Name (1.2.3)` or `-> Installing Name 1.2.3 (was 1.1.0)` | Pod being installed (new / updated) |
| `-> Using Name (1.2.3)` | Already installed, nothing to do |
| `> Git download` / `> Http download` | Fetched from the network |
| `> Copying Name from \`~/Library/Caches/CocoaPods/…\`` | Served from the download cache |
| `$ /…/git clone URL DEST … --branch TAG` / `$ /usr/bin/curl … -o FILE URL` | The actual network transfer |
| `CDN: trunk Relative path downloaded: …` (200), `Redirecting from …` (302), `not modified` (304), `couldn't be downloaded … Response: 404` | Spec fetches from cdn.cocoapods.org |
| `[!] …` | CocoaPods warnings and errors. On failure the last one is usually the cause |

## Troubleshooting

- **The menu bar shows nothing.** Check the app is running with `pgrep -x PodViz`, and start it with `open -a PodViz`. `podviz` also launches it. Runs started with plain `pod` never appear.
- **Install looks stuck.** Run the summary script. If the status is running with a `git clone` still `[running]`, it's a slow download, not a hang. You can also confirm with `ps -Ao etime,command | grep "git clone"`. Clones without `--depth 1` (pods pinned to a commit or branch) download the whole history, which is how TensorFlow takes 30+ minutes. Suggest the user check their network, or pin the pod to a released version so CocoaPods can make a shallow clone.
- **It failed.** Quote the last `[!]` message. Common causes:
  - `Unable to find a specification`: run `podviz install --repo-update`.
  - CDN 404s or timeouts: a network or proxy problem.
  - A UTF-8 locale error: `podviz` already sets `LANG`.
- **The "fetched" size looks low for a pod.** Very fast clones finish between samples, so the app falls back to the cached copy's size. Sizes in `Pods/` are always accurate.
- **The `podviz` command is missing.** Open the PodViz menu bar popover, choose ⋯ › *Install "podviz" Terminal Command*, or run `ln -s ~/.podviz/bin/podviz ~/.local/bin/podviz`.

## Managing the app

- Login item: `/Applications/PodViz.app/Contents/MacOS/PodViz --login-item on|off|status`. It is also in the ⋯ menu.
- Files:
  - `~/.podviz/runs/`: run logs. The app keeps the newest 20.
  - `~/.podviz/bin/podviz`: the wrapper script, rewritten on each app launch.
  - `~/.podviz/sync.rb`: makes Ruby flush output line by line.
- In the app, the user can also pick a project and press Install or Update directly. Those runs aren't written to `~/.podviz/runs`, so for anything you need to inspect, use `podviz` from the shell.
