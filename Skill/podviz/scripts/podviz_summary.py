#!/usr/bin/env python3
"""Summarize a CocoaPods run recorded by PodViz / the `podviz` command.

Usage:
  podviz_summary.py                  newest run in ~/.podviz/runs
  podviz_summary.py <log>            a specific log (any `pod install --verbose --no-ansi` output works)
  podviz_summary.py --list           recent runs, newest first
  podviz_summary.py --json           machine-readable output
  podviz_summary.py <log> --cwd DIR  project folder, for logs without a '#PODVIZ cwd=' header

Reports run status, the install plan (new / updated / up to date / removed pods), how each pod
arrived (git, HTTP, download cache, local), its size in Pods/, and every network request.
"""
import argparse
import json
import os
import re
import sys
from collections import Counter, OrderedDict
from urllib.parse import urlparse

RUNS = os.path.expanduser("~/.podviz/runs")
TRUNK = "https://cdn.cocoapods.org/"

ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
POD_SECTION = re.compile(r"^(Installing|Downloading|Using) ([^\s`]+) (.+)$")
VERSION_PAREN = re.compile(r"^\(([^)]+)\)$")
VERSION_WAS = re.compile(r"^(\S+) \(was ([^\s)]+)")
MANIFEST = re.compile(r"^([ARM-]) (\S+)$")
COPYING = re.compile(r"^> Copying (\S+) from `([^`]+)`")
DOWNLOADER = re.compile(r"^> (\w+) (?:HEAD )?download$")
COMPLETE = re.compile(r"Pod installation complete! There (?:is|are) (\d+) dependenc(?:y|ies) "
                      r"from the Podfile and (\d+) total pods? installed")
CDN_LINE = re.compile(r"^CDN: (\S+) (.*)$")
CDN_DOWNLOADED = re.compile(r"^Relative path downloaded: (.+?), save ETag:")
CDN_REDIRECT = re.compile(r"^Redirecting from (\S+) to (\S+)$")
CDN_NOT_MODIFIED = re.compile(r"^Relative path not modified: (.+)$")
CDN_NOT_FOUND = re.compile(r"^Relative path couldn't be downloaded: (.+) Response: (\d+)")
CDN_FAILED = re.compile(r"^URL couldn't be downloaded: (\S+) Response: (.*)$")
CDN_LOCAL = re.compile(r"^Relative path: .+ (?:exists!|modified during this run!)")
PRE_DOWNLOAD = re.compile(r"^Pre-downloading: `([^`]+)`")

SECTIONS = [
    ("Updating local specs repositories", "resolving"),
    ("Analyzing dependencies", "resolving"),
    ("Downloading dependencies", "downloading"),
    ("Generating Pods project", "generating"),
    ("Integrating client project", "integrating"),
]
REMOTE = ("https://", "http://", "git://", "ssh://", "file://", "git@")


def human(n):
    if n is None:
        return "-"
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1000 or unit == "GB":
            return f"{n:.0f} {unit}" if unit in ("B", "KB") else f"{n:.1f} {unit}"
        n /= 1000.0


def tree_size(path):
    if not os.path.lexists(path):
        return None
    if os.path.isfile(path) and not os.path.islink(path):
        return os.lstat(path).st_size
    total = 0
    for root, _dirs, files in os.walk(path):
        for f in files:
            p = os.path.join(root, f)
            if not os.path.islink(p):
                try:
                    total += os.lstat(p).st_size
                except OSError:
                    pass
    return total


def host_of(url):
    if "://" in url:
        return urlparse(url).hostname or ""
    if "@" in url and ":" in url:
        return url.split("@", 1)[1].split(":", 1)[0]
    return ""


def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError):
        return False


def parse(path):
    run = {
        "log": path, "meta": {}, "phase": "preparing", "activity": None,
        "pods": OrderedDict(), "requests": [], "cdn_status": Counter(), "cdn_local_hits": 0,
        "messages": [], "complete": None,
    }
    pods = run["pods"]
    redirects = {}
    in_manifest = False
    current = None
    pre_download = None

    def pod(name):
        return pods.setdefault(name, {"name": name, "version": None, "previous": None, "change": "unknown",
                                      "status": "queued", "source": None, "url": None})

    def close_current():
        nonlocal current
        if current and current in pods:
            p = pods[current]
            if p["status"] in ("installing", "downloading"):
                p["source"] = p["source"] or "local"
                p["status"] = "cached" if p["source"] == "cache" else "installed"
        current = None

    def finish_requests(owner):
        for r in run["requests"]:
            if r["state"] == "running" and r["pod"] == owner:
                r["state"] = "ok"

    with open(path, errors="replace") as fh:
        for raw in fh:
            line = ANSI.sub("", raw.rstrip("\n").rstrip("\r"))
            if "\r" in line:
                line = line.rsplit("\r", 1)[1]
            t = line.strip()
            if not t:
                continue
            if t.startswith("#PODVIZ "):
                key, _, value = t[8:].partition("=")
                run["meta"][key] = value
                continue
            owner = current or pre_download

            m = CDN_LINE.match(t)
            if m:
                source, rest = m.groups()
                base = TRUNK if source == "trunk" else ""
                if (d := CDN_DOWNLOADED.match(rest)):
                    url = redirects.pop(d.group(1), base + d.group(1))
                    size = tree_size(os.path.expanduser(f"~/.cocoapods/repos/{source}/{d.group(1)}"))
                    run["requests"].append({"kind": "cdn", "url": url, "status": 200, "state": "ok", "bytes": size, "pod": None})
                elif (d := CDN_REDIRECT.match(rest)):
                    frm, to = d.groups()
                    redirects[frm[len(base):] if base and frm.startswith(base) else frm] = to
                    run["requests"].append({"kind": "cdn", "url": frm, "status": 302, "state": "redirect", "bytes": None, "pod": None})
                elif (d := CDN_NOT_MODIFIED.match(rest)):
                    url = redirects.pop(d.group(1), base + d.group(1))
                    run["requests"].append({"kind": "cdn", "url": url, "status": 304, "state": "not modified", "bytes": None, "pod": None})
                elif (d := CDN_NOT_FOUND.match(rest)):
                    url = redirects.pop(d.group(1), base + d.group(1))
                    run["requests"].append({"kind": "cdn", "url": url, "status": int(d.group(2)), "state": "failed", "bytes": None, "pod": None})
                elif (d := CDN_FAILED.match(rest)):
                    run["requests"].append({"kind": "cdn", "url": d.group(1), "status": None, "state": "failed", "bytes": None, "pod": None})
                elif CDN_LOCAL.match(rest):
                    run["cdn_local_hits"] += 1
                continue

            if t.startswith("$ "):
                parts = t[2:].split(" ")
                tool, args = os.path.basename(parts[0]), parts[1:]
                if tool == "git":
                    i, sub = 0, None
                    while i < len(args):
                        a = args[i]
                        if a in ("-C", "-c"):
                            i += 2
                            continue
                        i += 1
                        if not a.startswith("-"):
                            sub = a
                            break
                    if sub in ("clone", "fetch", "ls-remote", "pull", "submodule"):
                        rest = args[i:]
                        url = next((a for a in rest if a.startswith(REMOTE)), f"git {sub}")
                        ref = rest[rest.index("--branch") + 1] if "--branch" in rest and rest.index("--branch") + 1 < len(rest) else None
                        finish_requests(owner)
                        run["requests"].append({"kind": "git", "verb": sub, "url": url, "ref": ref, "status": None,
                                                "state": "running", "bytes": None, "pod": owner})
                        if owner and sub in ("clone", "fetch"):
                            pod(owner).update(source="git", status="downloading", url=url)
                elif tool == "curl":
                    url = next((a for a in args if a.startswith(("http://", "https://"))), None)
                    if url:
                        finish_requests(owner)
                        run["requests"].append({"kind": "http", "url": url, "status": None, "state": "running", "bytes": None, "pod": owner})
                        if owner:
                            pod(owner).update(source="http", status="downloading", url=url)
                elif tool in ("unzip", "tar", "xz", "bsdtar", "ditto"):
                    finish_requests(owner)
                continue

            if t.startswith("> "):
                if (m := COPYING.match(t)):
                    p = pod(m.group(1))
                    p["source"] = p["source"] or "cache"
                    finish_requests(m.group(1))
                elif (m := DOWNLOADER.match(t)) and owner:
                    kind = m.group(1).lower()
                    pod(owner).update(source=kind if kind in ("git", "http") else "download", status="downloading")
                continue

            if t.startswith("[!] "):
                msg = t[4:]
                if msg.startswith("Failed: "):
                    for r in reversed(run["requests"]):
                        if r["state"] == "running":
                            r["state"] = "failed"
                            break
                run["messages"].append(msg)
                continue

            if (m := COMPLETE.search(t)):
                close_current()
                run["complete"] = {"dependencies": int(m.group(1)), "pods": int(m.group(2))}
                run["phase"] = "complete"
                continue

            u = t[3:] if t.startswith("-> ") else t
            if u == "Comparing resolved specification to the sandbox manifest":
                in_manifest = True
                continue
            section = next((phase for text, phase in SECTIONS if u.startswith(text)), None)
            if section:
                in_manifest = False
                pre_download = None
                if section != "downloading":
                    close_current()
                run["phase"] = section
                continue
            if (m := PRE_DOWNLOAD.match(u)):
                pre_download = m.group(1)
                pod(pre_download)["status"] = "downloading"
                continue
            if in_manifest and (m := MANIFEST.match(t)):
                change = {"A": "new", "M": "updated", "R": "removed", "-": "up to date"}[m.group(1)]
                p = pod(m.group(2))
                p["change"] = change
                p["status"] = "removed" if change == "removed" else "queued"
                continue
            if run["phase"] == "downloading" and (m := POD_SECTION.match(u)):
                action, name, rest = m.groups()
                if (v := VERSION_PAREN.match(rest)):
                    version, previous = v.group(1), None
                elif (v := VERSION_WAS.match(rest)):
                    version, previous = v.groups()
                else:
                    version, previous = rest.split(" ")[0], None
                if action != "Downloading":
                    close_current()
                p = pod(name)
                p["version"] = version
                p["previous"] = previous or p["previous"]
                if action == "Using":
                    p["change"] = "up to date" if p["change"] == "unknown" else p["change"]
                    p["status"] = "up to date"
                elif action == "Installing":
                    if p["change"] == "unknown":
                        p["change"] = "updated" if previous else "new"
                    p["status"] = "installing"
                    current = name
                else:
                    p["status"] = "downloading"
                in_manifest = False
                continue
            if run["phase"] == "downloading" and u.startswith("Removing "):
                p = pod(u.split(" ", 1)[1])
                p.update(change="removed", status="removed")

    meta = run["meta"]
    exit_code = int(meta["exit"]) if meta.get("exit", "").lstrip("-").isdigit() else None
    if current:
        pods[current]["status"] = "failed" if exit_code not in (None, 0) else pods[current]["status"]
        run["activity"] = f"installing {current}"
    if exit_code is None:
        alive = meta.get("pid") and pid_alive(meta["pid"])
        run["status"] = "running" if alive else ("succeeded" if run["complete"] else "interrupted (no exit code recorded)")
    elif exit_code == 0:
        run["status"] = "succeeded"
    elif exit_code in (130, 143):
        run["status"] = f"stopped (exit {exit_code})"
    else:
        run["status"] = f"failed (exit {exit_code})"
    if run["status"] != "running":
        for r in run["requests"]:
            if r["state"] == "running":
                r["state"] = "ok" if exit_code == 0 else "unfinished"

    st = os.stat(path)
    start = getattr(st, "st_birthtime", st.st_ctime)
    run["duration_seconds"] = round(max(0.0, st.st_mtime - start), 1)
    run["project"] = meta.get("cwd")
    run["command"] = meta.get("cmd", "pod install")
    return run


def add_sizes(run, cwd):
    project = cwd or run.get("project")
    run["project"] = project
    if not project:
        return
    for p in run["pods"].values():
        root = p["name"].split("/")[0]
        installed = p["status"] in ("installed", "cached", "up to date")
        p["bytes"] = tree_size(os.path.join(project, "Pods", root)) if installed else None
    run["pods_folder_bytes"] = tree_size(os.path.join(project, "Pods"))


def render(run):
    pods = list(run["pods"].values())
    reqs = run["requests"]
    change = Counter(p["change"] for p in pods)
    planned = [p for p in pods if p["change"] in ("new", "updated", "unknown")]
    installed = [p for p in planned if p["status"] in ("installed", "cached")]
    out = []
    project = os.path.basename(run["project"] or "") or "?"
    if project == "ios" and run["project"]:
        project = os.path.basename(os.path.dirname(run["project"])) + "/ios"
    out.append(f"PodViz run: {project} · {run['command']}")
    out.append(f"Log: {run['log']}")
    status = run["status"]
    if status == "running":
        status += f" — phase: {run['phase']}" + (f", {run['activity']}" if run["activity"] else "")
    out.append(f"Status: {status} · {run['duration_seconds']}s")
    if run["status"].startswith(("failed", "stopped", "interrupted")) and run["messages"]:
        out.append(f"Last CocoaPods message: [!] {run['messages'][-1]}")
    out.append("")

    out.append(f"Pods: {len(planned)} to install ({change['new']} new, {change['updated']} updated), "
               f"{change['up to date']} up to date, {change['removed']} removed — {len(installed)}/{len(planned)} installed")
    if pods:
        w = max(len(p["name"]) for p in pods) + 2
        out.append(f"  {'NAME'.ljust(w)}{'VERSION'.ljust(22)}{'CHANGE'.ljust(12)}{'HOW / STATUS'.ljust(22)}SIZE")
        order = {"new": 0, "updated": 0, "unknown": 0, "up to date": 1, "removed": 2}
        for p in sorted(pods, key=lambda p: (order.get(p["change"], 3), -(p.get("bytes") or 0))):
            version = f"{p['previous']} → {p['version']}" if p["previous"] else (p["version"] or "-")
            how = {"installed": f"{p['source'] or 'installed'}", "cached": "download cache", "up to date": "already installed",
                   "queued": "waiting", "downloading": f"downloading ({p['source'] or '?'})", "installing": "installing",
                   "removed": "removed", "failed": "FAILED"}.get(p["status"], p["status"])
            out.append(f"  {p['name'].ljust(w)}{version.ljust(22)}{p['change'].ljust(12)}{how.ljust(22)}{human(p.get('bytes'))}")
    total = sum(p.get("bytes") or 0 for p in pods)
    if run.get("pods_folder_bytes") is not None:
        out.append(f"Size: pods {human(total)} · whole Pods/ folder {human(run['pods_folder_bytes'])}")
    out.append("")

    kinds = Counter(r["kind"] for r in reqs)
    codes = Counter(r["status"] for r in reqs if r["kind"] == "cdn" and r["status"])
    code_text = ", ".join(f"{c}×{n}" for c, n in sorted(codes.items()))
    cdn_bytes = sum(r["bytes"] or 0 for r in reqs if r["kind"] == "cdn")
    out.append(f"Network: {len(reqs)} requests — CDN {kinds['cdn']}" + (f" ({code_text}; {human(cdn_bytes)} of specs)" if code_text else "")
               + f", git {kinds['git']}, HTTP {kinds['http']}; {run['cdn_local_hits']} spec files served from the local cache")
    for r in reqs:
        if r["kind"] != "cdn":
            ref = f" @ {r['ref']}" if r.get("ref") else ""
            verb = f"git {r.get('verb')}" if r["kind"] == "git" else "GET"
            out.append(f"  {verb} {r['url']}{ref} → {r['pod'] or '-'} [{r['state']}]")
    failed_cdn = [r for r in reqs if r["kind"] == "cdn" and r["state"] == "failed"]
    for r in failed_cdn[:10]:
        out.append(f"  CDN {r['status'] or 'ERR'} {r['url']}")
    hosts = Counter(host_of(r["url"]) for r in reqs if host_of(r["url"]))
    if hosts:
        out.append("  Hosts: " + ", ".join(f"{h} {n}" for h, n in hosts.most_common(6)))

    if run["messages"]:
        out.append("")
        out.append("CocoaPods messages:")
        for msg in run["messages"][-8:]:
            out.append(f"  [!] {msg}")
    return "\n".join(out)


def runs_newest_first():
    if not os.path.isdir(RUNS):
        return []
    files = [os.path.join(RUNS, f) for f in os.listdir(RUNS) if f.endswith(".log")]
    return sorted(files, key=os.path.getmtime, reverse=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log", nargs="?", help="log file (default: newest in ~/.podviz/runs)")
    ap.add_argument("--cwd", help="project folder containing the Podfile")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--list", action="store_true", help="list recent runs")
    args = ap.parse_args()

    if args.list:
        for f in runs_newest_first()[:15]:
            run = parse(f)
            print(f"{os.path.basename(f)}  {run['status']:<28} {run['command']:<24} {run['project'] or ''}")
        return
    log = args.log or next(iter(runs_newest_first()), None)
    if not log:
        sys.exit("No PodViz runs found in ~/.podviz/runs. Run `podviz install` in a project first.")
    run = parse(log)
    add_sizes(run, args.cwd)
    if args.json:
        run["pods"] = list(run["pods"].values())
        run["cdn_status"] = {}
        print(json.dumps(run, indent=2, default=str))
    else:
        print(render(run))


if __name__ == "__main__":
    main()
