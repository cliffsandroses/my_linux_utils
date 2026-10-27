"""The data guard, run by `netwatch sample` every minute, so it works with nobody watching (Moosa, 2026-10-27: "Make a
stop when the data goes over the daily limit … sessions allowed on the tv approved only by me … All this automated").

Over today's share: only the devices in `allow` keep the internet (AdGuard answers no names for the rest) and
qBittorrent is paused; both lift at midnight, or earlier when Moosa taps "Lift for today".
The TV: its internet is off until Moosa approves a session from the phone alert (1 or 3 hours). A session that runs
past its time or past `tv_normal_gb` asks again; with no answer at the end of its time, the TV goes off again.
Its local apps (Jellyfin by address, the homelab's names) keep working.

Settings: ~/.config/netwatch/guard.json (made on first run). Answers come back through ntfy: the alert buttons post
to "<topic>-guard", which this polls. The AdGuard login is read from its file at run time, never printed.
"""
import base64, json, os, re, subprocess, time, urllib.request

CONF = os.path.expanduser("~/.config/netwatch/guard.json")
STATE = os.path.expanduser("~/.local/share/netwatch/guard.json")
AG = "http://127.0.0.1:8080"
DEFAULT = {"on": True, "net": "192.168.10.0/24",
           "allow": {"192.168.10.16": "phone", "192.168.10.87": "work PC", "192.168.10.20": "homelab",
                     "192.168.10.30": "laptop", "192.168.10.13": "Proxmox", "192.168.10.10": "VM"},
           "tv": "192.168.10.50", "tv_approval": "always",     # "always", or "over" (only when over today's share)
           "tv_normal_gb": 5, "local": ["duckdns.org", "lan", "local", "home.arpa", "ts.net", "in-addr.arpa"]}
START, END = "! dataguard start", "! dataguard end"


def conf():
    if not os.path.exists(CONF):
        os.makedirs(os.path.dirname(CONF), exist_ok=True); json.dump(DEFAULT, open(CONF, "w"), indent=1)
    return {**DEFAULT, **json.load(open(CONF))}


def _ag(path, body=None):
    t = open(os.path.expanduser("~/homelab/adguard/admin-login.txt")).read()
    u, p = (re.search(rf"^{k}:\s*(\S+)", t, re.M).group(1) for k in ("user", "password"))
    r = urllib.request.Request(AG + path, json.dumps(body).encode() if body is not None else None,
                               {"Authorization": "Basic " + base64.b64encode(f"{u}:{p}".encode()).decode(), "Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=10) as f: return f.read()


def rules(c, house, tv):
    """Our block of AdGuard user rules: everything off for the house (but `allow`) and/or the TV, local names kept."""
    out = []
    if house:
        out += [f"||*^$client={c['net']}", "@@||*^$client=" + "|".join(c["allow"])]
    if tv and not house:
        out += [f"||*^$client={c['tv']}"]
    if out: out += [f"@@||{d}^" for d in c["local"]]
    return out


def apply(c, house, tv):
    cur = json.loads(_ag("/control/filtering/status")).get("user_rules") or []
    if START in cur: i, j = cur.index(START), cur.index(END) + 1; keep = cur[:i] + cur[j:]
    else: keep = cur
    mine = rules(c, house, tv)
    new = keep + ([START] + mine + [END] if mine else [])
    if new != cur: _ag("/control/filtering/set_rules", {"rules": new})


def tv_asked(c, since):
    """Did the TV look anything up (and get refused) since `since`? From AdGuard's query log."""
    q = json.loads(_ag(f"/control/querylog?search={c['tv']}&response_status=blocked&limit=5"))
    for e in q.get("data", []):
        t = e.get("time", "")[:19]
        if t and time.mktime(time.strptime(t, "%Y-%m-%dT%H:%M:%S")) > since: return True
    return False


def answers(topic, g):
    """Taps on the alert buttons since the last check (they post 'tv 60', 'tv 180', 'tv no', 'lift' to <topic>-guard)."""
    try:
        with urllib.request.urlopen(f"https://ntfy.sh/{topic}-guard/json?poll=1&since={g.get('since', 'all')}", timeout=15) as f:
            ev = [json.loads(l) for l in f.read().decode().splitlines() if l.strip()]
    except Exception: return []
    ev = [e for e in ev if e.get("event") == "message"]
    if ev: g["since"] = ev[-1]["id"]
    return [e.get("message", "").strip().lower() for e in ev]


def ask(topic, title, body, buttons):
    acts = "; ".join(f"http, {lbl}, https://ntfy.sh/{topic}-guard, method=POST, body={b}, clear=true" for lbl, b in buttons)
    urllib.request.urlopen(urllib.request.Request(f"https://ntfy.sh/{topic}", body.encode(),
                           {"Title": title, "Priority": "high", "Tags": "shield", "Actions": acts}), timeout=15)


def qbit(pause):
    st = subprocess.run(["docker", "inspect", "-f", "{{.State.Paused}}", "qbittorrent"], capture_output=True, text=True).stdout.strip()
    if pause and st == "false": subprocess.run(["docker", "pause", "qbittorrent"], capture_output=True)
    if not pause and st == "true": subprocess.run(["docker", "unpause", "qbittorrent"], capture_output=True)


def run(s, day, budget, topic, notify):
    """Called once a minute from netwatch sample with its state, today's key and today's share in bytes."""
    c = conf()
    try: g = json.load(open(STATE))
    except (OSError, ValueError): g = {}
    if not c["on"]: apply(c, False, False); qbit(False); return "guard off"
    now = time.time()
    for a in answers(topic, g):
        if a == "lift": g["lifted"] = day
        elif a.startswith("tv "):
            m = a.split()[1]
            if m.isdigit():
                if now >= g.get("tv_until", 0): g["tv_start_used"] = s["used"]      # a new session, not more time
                g["tv_until"] = now + int(m) * 60; g["tv_until_prev"] = 1
                for k in ("tv_asked_at", "tv_end_asked"): g.pop(k, None)
            else: g["tv_until"] = 0; g["tv_no_until"] = now + 1800
    over = s["days"].get(day, 0) > budget and g.get("lifted") != day
    if over and g.get("over_day") != day:
        g["over_day"] = day
        names = ", ".join(c["allow"].values())
        ask(topic, "Internet: over today's share, guard on", f"{s['days'][day]/1e9:.1f} GB of {budget/1e9:.1f} GB used. Only {names} stay "
            "online and downloads are paused until midnight.", [("Lift for today", "lift")])
    tv_on = now < g.get("tv_until", 0)
    if not tv_on and g.get("tv_until_prev"):   # the session's time ran out
        g["tv_until_prev"] = 0; g.pop("tv_start_used", None)
        notify("TV session over", "The TV's internet is off again. It asks you next time it's used.")
    need_ok = c["tv_approval"] == "always" or over
    if need_ok and not tv_on and now > g.get("tv_no_until", 0) and now - g.get("tv_asked_at", 0) > 900 and tv_asked(c, now - 120):
        g["tv_asked_at"] = now
        ask(topic, "The TV wants the internet", "Allow a session?", [("1 hour", "tv 60"), ("3 hours", "tv 180"), ("No", "tv no")])
    if tv_on:
        left = g["tv_until"] - now; gb = (s["used"] - g.get("tv_start_used", s["used"])) / 1e9
        if left < 600 and not g.get("tv_end_asked"):
            g["tv_end_asked"] = 1
            ask(topic, "TV session ends in 10 min", f"{gb:.1f} GB used by the house since it started. Keep going?", [("1 more hour", "tv 60"), ("Stop", "tv no")])
        if gb > c["tv_normal_gb"] and not g.get("tv_gb_asked"):
            g["tv_gb_asked"] = 1
            ask(topic, "TV session past its normal size", f"{gb:.1f} GB since it started (normal: {c['tv_normal_gb']} GB). Keep going?",
                [("Keep going", f"tv {max(10, int(left // 60))}"), ("Stop", "tv no")])
    else: g.pop("tv_end_asked", None)
    apply(c, over, need_ok and not tv_on); qbit(over)
    json.dump(g, open(STATE + ".tmp", "w")); os.replace(STATE + ".tmp", STATE)
    return f"guard: {'OVER, only ' + str(len(c['allow'])) + ' devices online, downloads paused' if over else 'under share'}; TV " + \
        (f"on for {int((g['tv_until'] - now) // 60)} min" if tv_on else ("off (needs your OK)" if need_ok else "free"))
