"""The data guard, run by `netwatch sample` every minute, so it works with nobody watching (Moosa, 2026-10-27: "Make a
stop when the data goes over the daily limit … sessions allowed on the tv approved only by me … All this automated",
then: "what about other people in my house??? Keep a constant monitor of each session. I want a dashboard with on off for
each device").

Every device in the house has a mode (Soma → Homelab → Internet switches it):
  on        always online
  guarded   online until the day goes over its share (the default for everyone else in the house and new devices)
  ask       online only for sessions Moosa approves from the phone alert (the TV); asks again near the end and when a
            session runs past its normal length
  off       never online
Over today's share, downloads (qBittorrent) pause too, until midnight or "Lift for today".
Sessions: a device is in a session while it looks names up (AdGuard's query log); a gap of 10 minutes ends it. Each minute
the counts are kept; finished sessions go to ~/.local/share/netwatch/sessions.jsonl. AdGuard sees names, not bytes, so a
session's data is the whole house's while it ran (the router reports no per-device bytes).
Blocking is AdGuard refusing names for that device; local names (the homelab's apps) keep working.

Settings: ~/.config/netwatch/guard.json (made on first run). Answers come from the phone alert buttons (ntfy topic
"<topic>-guard") and from Soma (actions.jsonl). The AdGuard login is read from its file at run time, never printed.
"""
import base64, calendar, fcntl, json, os, re, statistics, subprocess, time, urllib.request

CONF = os.path.expanduser("~/.config/netwatch/guard.json")
D = os.path.expanduser("~/.local/share/netwatch")
STATE, SESS, ACTS, LOCK = f"{D}/guard.json", f"{D}/sessions.jsonl", f"{D}/actions.jsonl", f"{D}/guard.lock"
AG = "http://127.0.0.1:8080"
MODES = ("on", "guarded", "ask", "off")
DEFAULT = {"on": True, "net": "192.168.10.0/24", "default_mode": "guarded", "normal_gb": 5,
           "devices": {"192.168.10.16": {"name": "Moosa's phone", "mode": "on"}, "192.168.10.87": {"name": "Work PC", "mode": "on"},
                       "192.168.10.30": {"name": "Laptop", "mode": "on"}, "192.168.10.20": {"name": "Homelab", "mode": "on"},
                       "192.168.10.13": {"name": "Proxmox", "mode": "on"}, "192.168.10.10": {"name": "VM (Proxmox)", "mode": "on"},
                       "192.168.10.1": {"name": "Router", "mode": "on"}, "192.168.10.50": {"name": "LG TV", "mode": "ask"},
                       "192.168.10.119": {"name": "PS5", "mode": "guarded"}},
           "local": ["duckdns.org", "lan", "local", "home.arpa", "ts.net", "in-addr.arpa"]}
START, END = "! dataguard start", "! dataguard end"


def conf():
    if not os.path.exists(CONF):
        os.makedirs(os.path.dirname(CONF), exist_ok=True); json.dump(DEFAULT, open(CONF, "w"), indent=1)
    c = {**DEFAULT, **json.load(open(CONF))}
    if "allow" in c:   # the first version's settings: allow → on, tv → ask
        for ip, n in c.pop("allow").items(): c["devices"].setdefault(ip, {"name": n, "mode": "on"})
        if c.get("tv"): c["devices"][c.pop("tv")] = {"name": "LG TV", "mode": "ask"}
        for k in ("tv_approval", "tv_normal_gb"): c.pop(k, None)
        save_conf(c)
    return c


def save_conf(c):
    json.dump(c, open(CONF + ".tmp", "w"), indent=1); os.replace(CONF + ".tmp", CONF)


def _ag(path, body=None):
    t = open(os.path.expanduser("~/homelab/adguard/admin-login.txt")).read()
    u, p = (re.search(rf"^{k}:\s*(\S+)", t, re.M).group(1) for k in ("user", "password"))
    r = urllib.request.Request(AG + path, json.dumps(body).encode() if body is not None else None,
                               {"Authorization": "Basic " + base64.b64encode(f"{u}:{p}".encode()).decode(), "Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=10) as f: return f.read()


def _t(s):   # AdGuard's query times are UTC ("…Z")
    return calendar.timegm(time.strptime(s[:19], "%Y-%m-%dT%H:%M:%S"))


def activity(since):
    """{ip: [lookups, refused, {names}]} since `since` (epoch), from AdGuard's query log, newest first, paged."""
    out, older = {}, ""
    for _ in range(20):
        q = json.loads(_ag(f"/control/querylog?limit=500{'&older_than=' + older if older else ''}"))
        rows = q.get("data") or []
        for e in rows:
            if _t(e["time"]) < since: return out
            a = out.setdefault(e.get("client", ""), [0, 0, set()]); a[0] += 1; a[2].add(".".join(e["question"]["name"].split(".")[-2:]))
            if e.get("reason", "").startswith("Filtered"): a[1] += 1
        older = q.get("oldest") or ""
        if not rows or not older: break
    return out


def neighbours():
    """LAN addresses the homelab has seen lately (ARP), so quiet devices are listed too."""
    r = subprocess.run(["ip", "-4", "neigh"], capture_output=True, text=True).stdout
    return {l.split()[0]: l.split()[4] for l in r.splitlines() if l.startswith("192.168.10.") and "lladdr" in l}


def rules(c, blocked, lockdown, allowed):
    out = []
    if lockdown: out += [f"||*^$client={c['net']}"] + (["@@||*^$client=" + "|".join(sorted(allowed))] if allowed else [])
    if blocked: out += ["||*^$client=" + "|".join(sorted(blocked))]
    if out: out += [f"@@||{d}^" for d in c["local"]]
    return out


def apply(c, blocked, lockdown, allowed):
    cur = json.loads(_ag("/control/filtering/status")).get("user_rules") or []
    keep = cur[:cur.index(START)] + cur[cur.index(END) + 1:] if START in cur else cur
    mine = rules(c, blocked, lockdown, allowed)
    new = keep + ([START] + mine + [END] if mine else [])
    if new != cur: _ag("/control/filtering/set_rules", {"rules": new})


def answers(topic, g):
    """Taps on the alert buttons ('ok <ip> <min>', 'no <ip>', 'lift'; the first version's 'tv 60' too), and Soma's."""
    msgs = []
    try:
        with urllib.request.urlopen(f"https://ntfy.sh/{topic}-guard/json?poll=1&since={g.get('since', 'all')}", timeout=15) as f:
            ev = [json.loads(l) for l in f.read().decode().splitlines() if l.strip()]
        ev = [e for e in ev if e.get("event") == "message"]
        if ev: g["since"] = ev[-1]["id"]
        msgs += [e.get("message", "") for e in ev]
    except Exception: pass
    try:
        os.replace(ACTS, ACTS + ".work"); msgs += [json.loads(l)["a"] for l in open(ACTS + ".work") if l.strip()]; os.remove(ACTS + ".work")
    except (OSError, ValueError): pass
    return [m.strip() for m in msgs]


def act(a):
    """Soma's switches: queue an answer for the next run (and run it now)."""
    os.makedirs(D, exist_ok=True)
    with open(ACTS, "a") as f: f.write(json.dumps({"a": a, "at": time.time()}) + "\n")


def ask(topic, title, body, buttons):
    acts = "; ".join(f"http, {lbl}, https://ntfy.sh/{topic}-guard, method=POST, body={b}, clear=true" for lbl, b in buttons)
    urllib.request.urlopen(urllib.request.Request(f"https://ntfy.sh/{topic}", body.encode(),
                           {"Title": title, "Priority": "high", "Tags": "shield", "Actions": acts}), timeout=15)


def qbit(pause):
    st = subprocess.run(["docker", "inspect", "-f", "{{.State.Paused}}", "qbittorrent"], capture_output=True, text=True).stdout.strip()
    if pause and st == "false": subprocess.run(["docker", "pause", "qbittorrent"], capture_output=True)
    if not pause and st == "true": subprocess.run(["docker", "unpause", "qbittorrent"], capture_output=True)


def normal_min(ip):
    """A device's normal session length: the median of its last 20 finished sessions (at least 30 min)."""
    try: ls = [json.loads(l) for l in open(SESS)][-400:]
    except OSError: return 90
    m = [s["min"] for s in ls if s["ip"] == ip][-20:]
    return max(30, statistics.median(m)) if len(m) >= 3 else 90


def run(s, day, budget, topic, notify):
    """Called once a minute from netwatch sample with its state, today's key and today's share in bytes."""
    os.makedirs(D, exist_ok=True)
    with open(LOCK, "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        return _run(s, day, budget, topic, notify)


def _run(s, day, budget, topic, notify):
    c = conf()
    try: g = json.load(open(STATE))
    except (OSError, ValueError): g = {}
    now = time.time(); dev = g.setdefault("dev", {})
    if not c["on"]:
        apply(c, set(), False, set()); qbit(False); g["summary"] = "guard off"; _save(g); return "guard off"
    for a in answers(topic, g):
        w = a.split(); w[0] = w[0].lower() if w else ""
        if a.lower() == "lift": g["lifted"] = day
        elif w[0] == "tv" and len(w) == 2: w = (["no", "192.168.10.50"] if w[1] == "no" else ["ok", "192.168.10.50", w[1]])
        if w[0] == "ok" and len(w) == 3 and w[2].isdigit():
            d = dev.setdefault(w[1], {})
            if now >= d.get("until", 0): d["start_used"] = s["used"]          # a new approved session, not more time
            d["until"] = now + int(w[2]) * 60; d.pop("asked", None); d.pop("end_asked", None); d.pop("gb_asked", None); d.pop("len_asked", None)
        elif w[0] == "no" and len(w) == 2:
            d = dev.setdefault(w[1], {}); d["until"] = 0; d["no_until"] = now + 1800
        elif w[0] == "mode" and len(w) == 3 and w[2].lower() in MODES:
            c["devices"].setdefault(w[1], {"name": f"Device .{w[1].rsplit('.', 1)[-1]}"})["mode"] = w[2].lower(); save_conf(c)
        elif w[0] == "name" and len(w) >= 3:
            c["devices"].setdefault(w[1], {"mode": c["default_mode"]})["name"] = a.split(None, 2)[2][:40]; save_conf(c)

    # sessions: lookups since the last run, per device
    seen = activity(g.get("at", now - 120)); g["at"] = now
    for ip, mac in neighbours().items(): dev.setdefault(ip, {})["mac"] = mac
    for ip, (q, refused, names) in seen.items():
        if not ip.startswith("192.168.10."): continue
        d = dev.setdefault(ip, {}); d["last"] = now; d["q"] = d.get("q", 0) + q
        if not d.get("start"): d.update(start=now, sq=0, house0=s["used"])
        d["sq"] = d.get("sq", 0) + q; d["refused"] = refused
        d["use"] = now if len(names) >= 4 else d.get("use", 0)   # several different sites in a minute: someone is using it, not background chatter
    for ip, d in dev.items():   # a 10-minute gap ends a session
        if d.get("start") and now - d.get("last", 0) > 600:
            with open(SESS, "a") as f:
                f.write(json.dumps({"ip": ip, "name": c["devices"].get(ip, {}).get("name", ""), "start": d["start"], "end": d["last"],
                                    "min": round((d["last"] - d["start"]) / 60), "lookups": d.get("sq", 0),
                                    "house_gb": round((s["used"] - d.get("house0", s["used"])) / 1e9, 2)}) + "\n")
            d.pop("start", None); d.pop("sq", None)

    over = s["days"].get(day, 0) > budget and g.get("lifted") != day
    if over and g.get("over_day") != day:
        g["over_day"] = day
        names = ", ".join(v["name"] for v in c["devices"].values() if v.get("mode") == "on")
        ask(topic, "Internet: over today's share, guard on", f"{s['days'][day]/1e9:.1f} GB of {budget/1e9:.1f} GB used. Only {names} "
            "(and approved sessions) stay online; downloads are paused until midnight.", [("Lift for today", "lift")])

    blocked, allowed = set(), set()
    for ip in set(c["devices"]) | {i for i in dev if i.startswith("192.168.10.")}:
        mode = c["devices"].get(ip, {}).get("mode", c["default_mode"]); d = dev.setdefault(ip, {}); name = c["devices"].get(ip, {}).get("name", ip)
        live = now < d.get("until", 0)
        if mode == "on" or live: allowed.add(ip)
        if mode == "off" or (mode == "ask" and not live) or (mode == "guarded" and over and not live): blocked.add(ip)
        if mode == "ask" and not live and d.get("refused") and now - d.get("use", 0) < 120 and now > d.get("no_until", 0) \
                and now - d.get("asked", 0) > 900:
            d["asked"] = now
            ask(topic, f"{name} wants the internet", "Allow a session?", [("1 hour", f"ok {ip} 60"), ("3 hours", f"ok {ip} 180"), ("No", f"no {ip}")])
        if live:
            left = d["until"] - now; gb = (s["used"] - d.get("start_used", s["used"])) / 1e9; mins = (now - d.get("start", now)) / 60
            if left < 600 and not d.get("end_asked"):
                d["end_asked"] = 1
                ask(topic, f"{name}: session ends in 10 min", f"{gb:.1f} GB used by the house since it started. Keep going?",
                    [("1 more hour", f"ok {ip} 60"), ("Stop", f"no {ip}")])
            if (gb > c["normal_gb"] and not d.get("gb_asked")) or (mins > 2 * normal_min(ip) and not d.get("len_asked")):
                d["gb_asked"] = d["len_asked"] = 1
                ask(topic, f"{name}: session past its normal size", f"{mins:.0f} min, {gb:.1f} GB (normal: {normal_min(ip):.0f} min, "
                    f"{c['normal_gb']} GB). Keep going?", [("Keep going", f"ok {ip} {max(10, int(left // 60))}"), ("Stop", f"no {ip}")])
        elif d.pop("until", None):   # an approved session's time ran out
            d.pop("end_asked", None); notify(f"{name}: session over", "Its internet is off again; it asks you next time.")
    apply(c, blocked, over, allowed); qbit(over)
    g["summary"] = {"over": over, "lifted": g.get("lifted") == day, "blocked": sorted(blocked), "share_gb": round(budget / 1e9, 1),
                    "today_gb": round(s["days"].get(day, 0) / 1e9, 2)}
    _save(g)
    return f"guard: {'OVER (downloads paused)' if over else 'under share'}; {len(blocked)} blocked: " + \
        ", ".join(c["devices"].get(i, {}).get("name", i) for i in sorted(blocked))


def _save(g):
    json.dump(g, open(STATE + ".tmp", "w")); os.replace(STATE + ".tmp", STATE)


def board():
    """Everything Soma's Internet tab shows: each device, its mode, whether it's in a session now, today's sessions."""
    c = conf()
    try: g = json.load(open(STATE))
    except (OSError, ValueError): g = {}
    now, dev = time.time(), g.get("dev", {})
    midnight = time.mktime(time.localtime(now)[:3] + (0, 0, 0, 0, 0, -1))
    try: today = [json.loads(l) for l in open(SESS)][-2000:]
    except OSError: today = []
    today = [x for x in today if x["end"] >= midnight]
    out = []
    for ip in sorted(set(c["devices"]) | {i for i in dev if i.startswith("192.168.10.")}, key=lambda i: tuple(int(p) for p in i.split("."))):
        d, cd = dev.get(ip, {}), c["devices"].get(ip, {})
        out.append({"ip": ip, "name": cd.get("name") or f"Device .{ip.rsplit('.', 1)[-1]}", "mode": cd.get("mode", c["default_mode"]),
                    "mac": d.get("mac", ""), "last": d.get("last"), "active": bool(d.get("start")),
                    "session_min": round((now - d["start"]) / 60) if d.get("start") else 0, "session_lookups": d.get("sq", 0),
                    "until": d.get("until") if now < d.get("until", 0) else None,
                    "blocked": ip in (g.get("summary") or {}).get("blocked", []) if isinstance(g.get("summary"), dict) else False,
                    "today": [x for x in today if x["ip"] == ip][-12:], "normal_min": normal_min(ip)})
    return {"on": c["on"], "summary": g.get("summary"), "at": g.get("at"), "devices": out}
