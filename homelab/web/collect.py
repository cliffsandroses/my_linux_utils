#!/usr/bin/env python3
"""Homelab web: gather everything about the homelab into one JSON file for the /web page.

Runs on the homelab VM as moosa every 2 minutes (homelab-web.timer). Read-only: it asks
Docker, Proxmox (an auditor-only API token), Headscale, Syncthing and the apps' own
status endpoints, and never writes anywhere except its output file. No secrets go into
the output: API keys are read to ask a question and then dropped.

    collect.py                      # write ~/homelab/dashboard/www/web/data.json
    collect.py --stdout             # print instead
"""
import json, os, re, socket, ssl, struct, subprocess, sys, time, urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HOME = Path.home()
OUT = HOME / "homelab/dashboard/www/web/data.json"
PVE = "https://192.168.10.13:8006/api2/json"
PVE_TOKEN = HOME / ".config/homelab-web/pve-token"   # "user@realm!tokenid=secret", mode 600
BACKUPS = Path("/mnt/data/Backups/homelab")
VM_IP = "192.168.10.20"
NOCERT = ssl.create_default_context(); NOCERT.check_hostname = False; NOCERT.verify_mode = ssl.CERT_NONE

# Friendly names and where each app's page lives. Containers not listed still appear,
# under their own name, with a link built from their first published port.
APPS = {
    "immich_server": ("Immich", "Photos", "http://{ip}:2283"),
    "nextcloud": ("Nextcloud", "Files", "http://{ip}:8082"),
    "homeassistant": ("Home Assistant", "Home", "http://{ip}:8123"),
    "plex": ("Plex", "Media", "http://{ip}:32400/web"),
    "sonarr": ("Sonarr", "Media automation", "http://{ip}:8989"),
    "radarr": ("Radarr", "Media automation", "http://{ip}:7878"),
    "prowlarr": ("Prowlarr", "Media automation", "http://{ip}:9696"),
    "bazarr": ("Bazarr", "Media automation", "http://{ip}:6767"),
    "seerr": ("Seerr", "Media automation", "http://{ip}:5055"),
    "profilarr": ("Profilarr", "Media automation", "http://{ip}:6868"),
    "recyclarr": ("Recyclarr", "Media automation", None),
    "cleanuparr": ("Cleanuparr", "Media automation", "http://{ip}:11011"),
    "flaresolverr": ("FlareSolverr", "Media automation", None),
    "qbittorrent": ("qBittorrent", "Downloads", "http://{ip}:8181"),
    "qui": ("Qui", "Downloads", "http://{ip}:7476"),
    "watchstate": ("WatchState", "Media", "http://{ip}:8095"),
    "adguardhome": ("AdGuard Home", "Network", "http://{ip}:8080"),
    "caddy": ("Caddy", "Network", None),
    "headscale": ("Headscale", "Network", "https://hs.meldev.duckdns.org/health"),
    "vaultwarden": ("Vaultwarden", "Security", "https://vaultwarden.meldev.duckdns.org"),
    "dockhand": ("Dockhand", "Admin", "http://{ip}:3000"),
    "dozzle": ("Dozzle", "Admin", "http://{ip}:8888"),
    "watchtower": ("Watchtower", "Admin", None),
    "homelab-dashboard": ("Port Map", "Admin", "http://{ip}:8090"),
    "freellmapi": ("FreeLLMAPI", "AI", "http://{ip}:3001"),
    "ps5-mqtt": ("PS5 MQTT", "Home", None),
    "mosquitto": ("Mosquitto", "Home", None),
    "immich_postgres": ("Immich database", "Photos", None),
    "immich_machine_learning": ("Immich smart search", "Photos", None),
    "immich_redis": ("Immich cache", "Photos", None),
    "nextcloud-db": ("Nextcloud database", "Files", None),
}
# Pages that are not containers on this VM.
EXTRA_PAGES = [
    ("Soma", "Admin", "http://{ip}:8443", "user service"),
    ("Proxmox", "Admin", "https://192.168.10.13:8006", "host"),
    ("Jellyfin", "Media", "http://192.168.10.21:8096", "CT 200"),
]


def sh(cmd, timeout=30):
    try:
        r = subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, timeout=timeout)
        return r.stdout
    except Exception:
        return ""


def jload(s, default=None):
    try:
        return json.loads(s)
    except Exception:
        return default


def http(url, headers=None, timeout=4, body=False):
    t = time.time()
    try:
        req = urllib.request.Request(url, headers=headers or {})
        opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=NOCERT), NoRedirect())
        with opener.open(req, timeout=timeout) as r:
            data = r.read() if body else b""
            return r.status, round((time.time() - t) * 1000), data
    except urllib.error.HTTPError as e:
        return e.code, round((time.time() - t) * 1000), b""
    except Exception:
        return 0, None, b""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def to_bytes(s):
    m = re.match(r"([\d.]+)\s*([KMGT]?i?B)", s or "")
    if not m:
        return 0
    n, u = float(m.group(1)), m.group(2)
    mult = {"B": 1, "KiB": 1024, "MiB": 1024**2, "GiB": 1024**3, "TiB": 1024**4,
            "kB": 1e3, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12}.get(u, 1)
    return int(n * mult)


# --- this VM -------------------------------------------------------------------------------
def vm():
    mi = dict(re.findall(r"^(\w+):\s+(\d+)", Path("/proc/meminfo").read_text(), re.M))
    load = Path("/proc/loadavg").read_text().split()[:3]
    psi = Path("/proc/pressure/memory").read_text().splitlines()[0]
    disks = []
    for line in sh(["df", "-B1", "--output=target,source,size,used,avail", "/", "/mnt/data", "/mnt/media", "/mnt/nvme"]).splitlines()[1:]:
        t, s, size, used, av = line.split()
        disks.append({"mount": t, "device": s, "size": int(size), "used": int(used), "avail": int(av)})
    return {
        "hostname": socket.gethostname(), "ip": VM_IP,
        "kernel": os.uname().release,
        "os": (re.search(r'PRETTY_NAME="([^"]+)"', Path("/etc/os-release").read_text()) or [None, "?"])[1],
        "uptime_s": int(float(Path("/proc/uptime").read_text().split()[0])),
        "cpus": os.cpu_count(), "load": [float(x) for x in load],
        "mem_total": int(mi["MemTotal"]) * 1024, "mem_avail": int(mi["MemAvailable"]) * 1024,
        "swap_total": int(mi["SwapTotal"]) * 1024,
        "mem_pressure_avg60": float(re.search(r"avg60=([\d.]+)", psi).group(1)),
        "oom_kills_since_boot": int((re.search(r"oom_kill (\d+)", Path("/proc/vmstat").read_text()) or [0, 0])[1]),
        "disks": disks,
    }


# --- Docker --------------------------------------------------------------------------------
def containers():
    ps = [jload(l, {}) for l in sh(["docker", "ps", "-a", "--format", "{{json .}}"]).splitlines()]
    stats = {s.get("Name"): s for s in (jload(l, {}) for l in sh(["docker", "stats", "--no-stream", "--format", "{{json .}}"], 60).splitlines())}
    names = [p["Names"] for p in ps if p.get("Names")]
    insp = {c["Name"].lstrip("/"): c for c in jload(sh(["docker", "inspect", *names]), [])} if names else {}

    def errors(name):
        out = sh(f"docker logs --since 1h {name} 2>&1 | grep -ciE '\\b(error|fatal|panic|exception)\\b'", 20).strip()
        return int(out or 0)
    with ThreadPoolExecutor(8) as ex:
        errs = dict(zip(names, ex.map(errors, names)))

    rows = []
    for p in ps:
        n = p.get("Names"); i = insp.get(n, {}); st = stats.get(n, {}); state = i.get("State", {})
        mu, ml = (st.get("MemUsage", "0B / 0B").split(" / ") + ["0B"])[:2]
        ports = sorted({f'{b.get("HostPort")}/{k.split("/")[1]}' for k, v in (i.get("NetworkSettings", {}).get("Ports") or {}).items() if v for b in v if b.get("HostIp") in ("0.0.0.0", "")})
        labels = i.get("Config", {}).get("Labels") or {}
        rows.append({
            "name": n, "image": p.get("Image"), "state": state.get("Status"),
            "health": (state.get("Health") or {}).get("Status"),
            "started": state.get("StartedAt"), "restarts": i.get("RestartCount", 0),
            "oom_killed": state.get("OOMKilled", False),
            "project": labels.get("com.docker.compose.project"),
            "compose_dir": labels.get("com.docker.compose.project.working_dir"),
            "ports": ports, "network_mode": i.get("HostConfig", {}).get("NetworkMode"),
            "mem_used": to_bytes(mu), "mem_limit": i.get("HostConfig", {}).get("Memory") or to_bytes(ml),
            "mem_limit_set": bool(i.get("HostConfig", {}).get("Memory")),
            "cpu_pct": float((st.get("CPUPerc") or "0%").rstrip("%") or 0),
            "errors_1h": errs.get(n, 0),
            "mounts": [m.get("Source") or m.get("Name") for m in i.get("Mounts", [])][:8],
            "restart_policy": i.get("HostConfig", {}).get("RestartPolicy", {}).get("Name"),
        })
    return rows


def apps(ctrs):
    by = {c["name"]: c for c in ctrs}
    targets = []
    for c in ctrs:
        name, group, url = APPS.get(c["name"], (c["name"], "Other", None))
        if url is None and c["ports"] and c["name"] not in APPS:
            url = "http://{ip}:" + c["ports"][0].split("/")[0]
        targets.append((name, group, url.format(ip=VM_IP) if url else None, c["name"], c["state"]))
    for name, group, url, where in EXTRA_PAGES:
        targets.append((name, group, url.format(ip=VM_IP), where, None))

    def check(t):
        name, group, url, where, state = t
        code, ms, _ = http(url) if url else (None, None, b"")
        return {"name": name, "group": group, "url": url, "where": where, "container_state": state,
                "code": code, "ms": ms, "up": bool(code) and code < 500 if url else state == "running"}
    with ThreadPoolExecutor(12) as ex:
        return list(ex.map(check, targets))


# --- Proxmox -------------------------------------------------------------------------------
def proxmox():
    try:
        tok = PVE_TOKEN.read_text().strip()
    except OSError:
        return {"error": "no Proxmox token at " + str(PVE_TOKEN)}
    h = {"Authorization": "PVEAPIToken=" + tok}

    def get(path):
        code, _, b = http(PVE + path, h, timeout=6, body=True)
        return (jload(b, {}) or {}).get("data") if code == 200 else None
    node = "pve"
    st = get(f"/nodes/{node}/status") or {}
    guests = []
    for kind in ("qemu", "lxc"):
        for g in get(f"/nodes/{node}/{kind}") or []:
            guests.append({"id": g.get("vmid"), "type": "VM" if kind == "qemu" else "CT", "name": g.get("name"),
                           "status": g.get("status"), "cpu": g.get("cpu"), "cpus": g.get("cpus"),
                           "mem": g.get("mem"), "maxmem": g.get("maxmem"), "maxdisk": g.get("maxdisk"),
                           "uptime": g.get("uptime"), "onboot": None})
    storage = [{"name": s.get("storage"), "type": s.get("type"), "used": s.get("used"), "total": s.get("total"),
                "active": s.get("active")} for s in get(f"/nodes/{node}/storage") or []]
    disks = [{"dev": d.get("devpath"), "model": d.get("model"), "size": d.get("size"), "health": d.get("health"),
              "type": d.get("type"), "wearout": d.get("wearout")} for d in get(f"/nodes/{node}/disks/list") or []]
    mem = st.get("memory", {})
    return {
        "node": node, "ip": "192.168.10.13", "pve": (get("/version") or {}).get("version"),
        "cpu_model": (st.get("cpuinfo") or {}).get("model"), "cpus": (st.get("cpuinfo") or {}).get("cpus"),
        "cpu": st.get("cpu"), "load": st.get("loadavg"), "uptime_s": st.get("uptime"),
        "mem_total": mem.get("total"), "mem_used": mem.get("used"),
        "mem_promised": sum(g["maxmem"] or 0 for g in guests if g["status"] == "running"),
        "kernel": (st.get("current-kernel") or {}).get("release"),
        "guests": guests, "storage": storage, "disks": disks,
    }


# --- backups, schedules --------------------------------------------------------------------
def backups():
    sets = sorted([d for d in BACKUPS.glob("20*") if d.is_dir()], reverse=True) if BACKUPS.exists() else []
    rows = []
    for d in sets:
        log = (d / "backup.log").read_text(errors="replace") if (d / "backup.log").exists() else ""
        size = sum(f.stat().st_size for f in d.iterdir() if f.is_file() and f.stat().st_nlink == 1) + \
               sum(f.stat().st_size for f in d.iterdir() if f.is_file() and f.stat().st_nlink > 1) // 2
        rows.append({"name": d.name, "time": d.stat().st_mtime, "ok": log.rstrip().endswith("OK"),
                     "offsite": (d / ".offsite-done").exists(), "size": size,
                     "fails": [l.strip() for l in log.splitlines() if "FAIL" in l][:5]})
    latest = rows[0] if rows else None
    mirrors = Path("/mnt/data/Backups/git-mirrors")
    return {"dir": str(BACKUPS), "sets": rows, "latest_age_h": round((time.time() - latest["time"]) / 3600, 1) if latest else None,
            "git_mirrors": sorted(p.stem for p in mirrors.glob("*.git")) if mirrors.exists() else [],
            "log_tail": (sets[0] / "backup.log").read_text(errors="replace").splitlines()[-12:] if sets else []}


def schedules():
    env = dict(os.environ, XDG_RUNTIME_DIR=f"/run/user/{os.getuid()}")
    timers = []
    names = re.findall(r"(\S+\.timer)", subprocess.run(["systemctl", "--user", "list-timers", "--all", "--no-legend", "--plain"],
                                                       capture_output=True, text=True, env=env).stdout)
    for t in sorted(set(names)):
        p = dict(l.split("=", 1) for l in subprocess.run(
            ["systemctl", "--user", "show", t, "-p", "NextElapseUSecRealtime,LastTriggerUSec,Unit,ActiveState,Description"],
            capture_output=True, text=True, env=env).stdout.splitlines() if "=" in l)
        svc = p.get("Unit", t.replace(".timer", ".service"))
        r = dict(l.split("=", 1) for l in subprocess.run(["systemctl", "--user", "show", svc, "-p", "Result,ExecMainStatus"],
                                                         capture_output=True, text=True, env=env).stdout.splitlines() if "=" in l)
        timers.append({"timer": t, "service": svc, "description": p.get("Description"), "active": p.get("ActiveState"),
                       "next": p.get("NextElapseUSecRealtime"), "last": p.get("LastTriggerUSec"),
                       "result": r.get("Result"), "exit": r.get("ExecMainStatus")})
    cron = [l for l in sh("crontab -l").splitlines() if l.strip() and not l.startswith("#")]
    return {"timers": timers, "cron": cron,
            "cron_d": [l for f in Path("/etc/cron.d").glob("*") for l in f.read_text(errors="replace").splitlines()
                       if l.strip() and not l.startswith("#") and "=" not in l.split()[0]]}


# --- network -------------------------------------------------------------------------------
def dns_query(server, name="example.com", port=53, timeout=2):
    q = struct.pack(">HHHHHH", 0x1234, 0x0100, 1, 0, 0, 0) + b"".join(
        bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\0" + struct.pack(">HH", 1, 1)
    t = time.time()
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(timeout); s.sendto(q, (server, port))
        data = s.recv(512); s.close()
        return {"ok": struct.unpack(">H", data[6:8])[0] > 0, "ms": round((time.time() - t) * 1000)}
    except Exception:
        return {"ok": False, "ms": None}


def network():
    nodes = jload(sh(["docker", "exec", "headscale", "headscale", "nodes", "list", "-o", "json"]), []) or []
    ts = jload(sh(["tailscale", "status", "--json"]), {}) or {}
    online = {p.get("HostName", "").lower(): p.get("Online") for p in (ts.get("Peer") or {}).values()}
    tail = [{"name": n.get("given_name"), "ip": (n.get("ip_addresses") or ["?"])[0], "online": n.get("online"),
             "last_seen": (n.get("last_seen") or {}).get("seconds") if isinstance(n.get("last_seen"), dict) else n.get("last_seen"),
             "os": None} for n in nodes]
    exports = [l for l in Path("/etc/exports").read_text().splitlines() if l.strip() and not l.startswith("#")]
    return {
        "tailnet": tail,
        "dns": {"adguard": dns_query(VM_IP), "adguard_blocks": dns_query(VM_IP, "doubleclick.net"),
                "fallback": dns_query("192.168.10.10"), "router": dns_query("192.168.10.1")},
        "nfs_exports": exports,
        "ips": [l.split()[0] + " " + " ".join(l.split()[2:3]) for l in sh(["ip", "-br", "-4", "addr"]).splitlines()
                if not l.startswith(("lo", "br-", "veth", "docker"))],
    }


def syncthing():
    cfg = HOME / ".local/state/syncthing/config.xml"
    try:
        key = re.search(r"<apikey>([^<]+)", cfg.read_text()).group(1)
    except Exception:
        return {"error": "Syncthing config not found"}
    h = {"X-API-Key": key}

    def get(p):
        return jload(http("http://127.0.0.1:8384/rest" + p, h, body=True)[2], {})
    me = (get("/system/status") or {}).get("myID")
    devs = {d["deviceID"]: d["name"] for d in get("/config/devices") or []}
    conns = (get("/system/connections") or {}).get("connections", {})
    folders = []
    for f in get("/config/folders") or []:
        s = get("/db/status?folder=" + f["id"]) or {}
        folders.append({"id": f["id"], "label": f.get("label") or f["id"], "path": f["path"], "type": f["type"],
                        "state": s.get("state"), "files": s.get("globalFiles"), "bytes": s.get("globalBytes"),
                        "need": s.get("needFiles"), "errors": s.get("errors"),
                        "with": [devs.get(d["deviceID"], d["deviceID"][:7]) for d in f["devices"] if d["deviceID"] != me]})
    pending = get("/cluster/pending/folders") or {}
    return {"folders": folders,
            "devices": [{"name": n, "id": d[:7], "connected": (conns.get(d) or {}).get("connected"),
                         "address": (conns.get(d) or {}).get("address")} for d, n in devs.items() if d != me],
            "pending_folders": [{"id": k, "from": [devs.get(x, x[:7]) for x in v.get("offeredBy", {})]} for k, v in pending.items()]}


# --- what the apps hold --------------------------------------------------------------------
def counts():
    out = {}
    q = lambda c, db, u, sql: sh(["docker", "exec", c, "psql", "-U", u, "-d", db, "-tAc", sql]).strip()
    try:
        out["immich_assets"] = int(q("immich_postgres", "immich", "immich", 'select count(*) from asset where "deletedAt" is null'))
        out["immich_albums"] = int(q("immich_postgres", "immich", "immich", "select count(*) from album"))
    except ValueError:
        pass
    try:
        out["nextcloud_files"] = int(q("nextcloud-db", "nextcloud", "oc_admin", "select count(*) from oc_filecache"))
    except ValueError:
        pass
    for app, port, path, key in (("sonarr", 8989, "/api/v3/series", "sonarr_series"), ("radarr", 7878, "/api/v3/movie", "radarr_movies"),
                                 ("prowlarr", 9696, "/api/v1/indexer", "prowlarr_indexers")):
        try:
            k = re.search(r"<ApiKey>([^<]+)", (HOME / f"homelab/arr/config/{app}/config.xml").read_text()).group(1)
            out[key] = len(jload(http(f"http://127.0.0.1:{port}{path}", {"X-Api-Key": k}, body=True)[2], []) or [])
        except Exception:
            pass
    try:
        out["torrents"] = len(list(Path("/DATA/AppData/qbittorrent/config/data/BT_backup").glob("*.fastresume")))
    except OSError:
        pass
    return out


# --- alerts --------------------------------------------------------------------------------
def alerts(d):
    a = []
    add = lambda lvl, txt: a.append({"level": lvl, "text": txt})
    v = d["vm"]
    if v["mem_avail"] / v["mem_total"] < 0.12:
        add("warn", f'Homelab VM has {v["mem_avail"] // 2**20} MB of RAM free out of {v["mem_total"] // 2**20} MB, and no swap.')
    for k in v["disks"]:
        if k["used"] / max(k["size"], 1) > 0.9:
            add("warn", f'{k["mount"]} is {round(100 * k["used"] / k["size"])}% full ({k["avail"] // 2**30} GB left).')
    p = d["proxmox"]
    if p.get("mem_total") and p["mem_promised"] > p["mem_total"]:
        add("warn", f'Proxmox has promised {p["mem_promised"] // 2**20} MB of RAM to running guests but has {p["mem_total"] // 2**20} MB.')
    for g in p.get("guests", []):
        if g["status"] != "running":
            add("info", f'{g["type"]} {g["id"]} {g["name"]} is {g["status"]}.')
    for c in d["containers"]:
        if c["state"] != "running":
            add("bad", f'{c["name"]} is {c["state"]}.')
        elif c["health"] == "unhealthy":
            add("bad", f'{c["name"]} reports unhealthy.')
        if c["oom_killed"]:
            add("warn", f'{c["name"]} was killed for running out of memory since it last started.')
        if c["mem_limit_set"] and c["mem_used"] / max(c["mem_limit"], 1) > 0.9:
            add("warn", f'{c["name"]} is at {round(100 * c["mem_used"] / c["mem_limit"])}% of its memory cap.')
    for x in d["apps"]:
        if x["url"] and not x["up"]:
            add("bad", f'{x["name"]} does not answer at {x["url"]}.')
    b = d["backups"]
    if b["latest_age_h"] is None or b["latest_age_h"] > 26:
        add("bad", f'Last homelab backup is {b["latest_age_h"]} hours old.')
    elif b["sets"] and not b["sets"][0]["ok"]:
        add("bad", f'Last homelab backup ({b["sets"][0]["name"]}) did not finish OK.')
    elif b["sets"] and not b["sets"][0]["offsite"]:
        add("warn", f'Last backup ({b["sets"][0]["name"]}) has not reached the laptop yet.')
    for t in d["schedules"]["timers"]:
        if t["result"] not in (None, "", "success"):
            add("warn", f'{t["service"]} last ended with {t["result"]}.')
    n = d["network"]
    for k, lbl in (("adguard", "AdGuard"), ("fallback", "DNS fallback")):
        if not n["dns"][k]["ok"]:
            add("bad", f"{lbl} is not answering DNS.")
    for node in n["tailnet"]:
        if not node["online"]:
            add("info", f'Tailnet device {node["name"]} is offline.')
    s = d["syncthing"]
    for f in s.get("folders", []):
        if f["errors"]:
            add("warn", f'Syncthing folder {f["label"]} has {f["errors"]} errors.')
    for f in s.get("pending_folders", []):
        add("info", f'Syncthing: {", ".join(f["from"])} is offering folder "{f["id"]}". Accept it to start syncing.')
    order = {"bad": 0, "warn": 1, "info": 2}
    return sorted(a, key=lambda x: order[x["level"]])


def main():
    t = time.time()
    with ThreadPoolExecutor(6) as ex:
        f = {k: ex.submit(fn) for k, fn in (("vm", vm), ("containers", containers), ("proxmox", proxmox), ("backups", backups),
                                            ("schedules", schedules), ("network", network), ("syncthing", syncthing), ("counts", counts))}
        d = {k: v.result() for k, v in f.items()}
    d["apps"] = apps(d["containers"])
    d["alerts"] = alerts(d)
    d["generated"] = int(time.time()); d["took_s"] = round(time.time() - t, 1)
    js = json.dumps(d, separators=(",", ":"))
    if "--stdout" in sys.argv:
        print(json.dumps(d, indent=1)); return
    OUT.parent.mkdir(parents=True, exist_ok=True)
    tmp = OUT.with_suffix(".tmp"); tmp.write_text(js); tmp.replace(OUT)


if __name__ == "__main__":
    main()
