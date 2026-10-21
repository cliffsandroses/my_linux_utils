#!/usr/bin/env python3
"""Point every Plex library at the media pool, keeping watch history.

Pass 1 adds /mnt/pool/Media/<folder> beside the per-disk folders and scans; pass 2 drops
the per-disk folders, scans, and empties the trash of the old paths. Prints item and
watched counts before and after. Run on the homelab VM.
"""
import json, re, sys, time, urllib.parse, urllib.request
from pathlib import Path

PREFS = Path.home() / "homelab/plex/config/Library/Application Support/Plex Media Server/Preferences.xml"
TOKEN = re.search(r'PlexOnlineToken="([^"]+)"', PREFS.read_text()).group(1)
BASE = "http://127.0.0.1:32400"
POOL = "/mnt/pool/Media/"


def call(method, path, params=None):
    q = urllib.parse.urlencode(params or [], doseq=True)
    url = f"{BASE}{path}{'&' if '?' in path else '?'}{q}" if q else f"{BASE}{path}"
    req = urllib.request.Request(url, method=method, headers={"X-Plex-Token": TOKEN, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        b = r.read()
        return json.loads(b) if b.strip().startswith(b"{") else {}


def sections():
    return call("GET", "/library/sections")["MediaContainer"].get("Directory", [])


def counts(s):
    k = s["key"]
    items = call("GET", f"/library/sections/{k}/all", {"X-Plex-Container-Start": 0, "X-Plex-Container-Size": 0})["MediaContainer"].get("totalSize")
    if s["type"] == "show":
        eps = call("GET", f"/library/sections/{k}/all", {"type": 4, "X-Plex-Container-Start": 0, "X-Plex-Container-Size": 0})["MediaContainer"].get("totalSize")
        watched = call("GET", f"/library/sections/{k}/all", {"type": 4, "viewCount>>": 0, "X-Plex-Container-Start": 0, "X-Plex-Container-Size": 0})["MediaContainer"].get("totalSize")
        return {"shows": items, "episodes": eps, "watched_episodes": watched}
    watched = call("GET", f"/library/sections/{k}/all", {"viewCount>>": 0, "X-Plex-Container-Start": 0, "X-Plex-Container-Size": 0})["MediaContainer"].get("totalSize")
    return {"items": items, "watched": watched}


def set_locations(s, locs):
    call("PUT", f"/library/sections/{s['key']}", [("agent", s["agent"]), ("language", s["language"]),
                                                   ("name", s["title"]), ("type", s["type"])] + [("location", l) for l in locs])


def scan_and_wait(s):
    call("GET", f"/library/sections/{s['key']}/refresh")
    time.sleep(5)
    for _ in range(240):
        cur = next(x for x in sections() if x["key"] == s["key"])
        if not cur.get("refreshing"):
            return
        time.sleep(5)
    print("  scan still running after 20 min, continuing")


def main():
    before = {}
    for s in sections():
        locs = [l["path"] for l in s.get("Location", [])]
        names = sorted({l.rstrip("/").split("/")[-1] for l in locs})
        target = [POOL + n for n in names]
        before[s["key"]] = counts(s)
        print(f"== {s['title']} ({s['type']}): {locs}\n   before {before[s['key']]}")
        if locs == target:
            print("   already on the pool"); continue
        set_locations(s, sorted(set(locs) | set(target)))
        scan_and_wait(s)
        p1 = counts(s)
        print(f"   pass 1 (pool added) {p1}")
        watched = before[s["key"]].get("watched", before[s["key"]].get("watched_episodes", 0))
        if p1 != before[s["key"]] and watched:
            set_locations(s, locs)
            print("   counts changed after adding the pool: old folders put back, this library left as it was")
            continue
        if p1 != before[s["key"]]:
            # Home-video libraries match files by path, so the pool shows each file twice until the
            # old folders go. With nothing watched there is no history to lose: finish the switch.
            print("   counts changed (path duplicates), nothing watched: switching to the pool only")
        set_locations(s, target)
        scan_and_wait(s)
        call("PUT", f"/library/sections/{s['key']}/emptyTrash")
        time.sleep(5)
        after = counts(s)
        now = [l["path"] for l in next(x for x in sections() if x["key"] == s["key"]).get("Location", [])]
        print(f"   pass 2 (pool only) {after}\n   locations now {now}")
        if after != before[s["key"]]:
            print("   NOTE: counts differ from before")


if __name__ == "__main__":
    main()
