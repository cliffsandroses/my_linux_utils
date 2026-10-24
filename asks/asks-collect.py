#!/usr/bin/env python3
"""Asks: every request Moosa made to Claude, what was done about it and the proof.

Runs on the laptop every 5 minutes (asks-collect.timer). Reads Claude Code's own chat records
(~/.claude/projects/*/*.jsonl: chats on this laptop, including the ones driven from the phone
through Remote Control) and adds each new message to the ledger, ~/Projects/asks/ledger.json.
Claude records each ask's items there: {"t": what, "s": done|said|open|waiting|blocked|chat,
"p": the proof}. Asks from cloud chats come from the Moosa's Asks page on claude.ai: its "Save for Nucleus"
button saves moosas-asks-*.json, which is imported from ~/Downloads (or ~/Projects/asks/inbox) and filed
under ~/Projects/asks/imported. "said" = a chat reported it done and nobody checked. It then writes
~/Projects/asks/asks.json, which Syncthing carries to the homelab for Nucleus. Keys pasted into
a message are hidden. Nothing leaves the laptop except through Syncthing.

    asks-collect.py            # update the ledger and asks.json
    asks-collect.py --test     # self-check on made-up chats
"""
import json, os, re, sys, time
from pathlib import Path

HOME = Path.home()
PROJECTS = HOME / ".claude/projects"
DIR = Path(os.environ.get("ASKS_DIR") or HOME / "Projects/asks")
STATE = Path(os.environ.get("ASKS_STATE") or HOME / ".local/state/asks/offsets.json")
SKIP = ("<", "Caveat:", "[Request interrupted", "This session is being continued")
KEYS = re.compile(r"\b(hskey-[\w-]+|tskey-[\w-]+|sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[\w-]{10,})")


def redact(t):
    t = KEYS.sub("[key hidden]", t)
    return re.sub(r"\b[A-Za-z0-9_\-]{48,}\b", "[long token hidden]", t)


def ask_of(d):
    """The text of a message Moosa typed, or None for everything else in a chat record."""
    if d.get("type") != "user" or d.get("isMeta") or d.get("isCompactSummary") or d.get("isSidechain"):
        return None
    c = (d.get("message") or {}).get("content")
    if isinstance(c, list):
        if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
            return None
        c = "\n".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
    t = re.sub(r"<pasted_content[^>]*>[\s\S]*?</pasted_content[^>]*>", "[pasted output]", (c or "")).strip()
    if not t or t.startswith(SKIP):
        return None
    return redact(t)[:4000]


def load(p, default):
    try:
        return json.loads(p.read_text())
    except (OSError, ValueError):
        return default


def save(p, data):
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_name("." + p.name + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1))
    tmp.replace(p)


def scan(ledger, offsets):
    """New messages from every chat record since the last run (by byte offset); returns how many were added."""
    added = 0
    for f in sorted(PROJECTS.glob("*/*.jsonl")):
        if "openclaw" in f.parent.name:            # OpenClaw's own agents, not Moosa typing
            continue
        st = f.stat(); key = str(f); seen = offsets.get(key, [0, 0])
        start = seen[0] if seen[1] == st.st_ino and seen[0] <= st.st_size else 0
        if start == st.st_size:
            continue
        with f.open("rb") as fh:
            fh.seek(start); data = fh.read()
        end = data.rfind(b"\n") + 1                # a line still being written waits for the next run
        for line in data[:end].splitlines():
            try:
                d = json.loads(line)
            except ValueError:
                continue
            t = ask_of(d); u = d.get("uuid")
            if not t or not u or u in ledger["asks"]:
                continue
            sid = d.get("sessionId") or f.stem
            title = ledger["sessions"].setdefault(sid, {"title": t.splitlines()[0][:70], "file": f.name})["title"]
            ledger["asks"][u] = {"text": t, "at": d.get("timestamp"), "where": "Laptop", "session": sid, "title": title, "items": []}
            added += 1
        offsets[key] = [start + end, st.st_ino]
    return added


def import_exports(ledger):
    """Files saved by the claude.ai page's "Save for Nucleus": new asks are added; an ask already here keeps
    its items unless it has none yet. Each file is moved to imported/ once read."""
    n = 0
    for f in sorted([*Path(HOME / "Downloads").glob("moosas-asks-*.json"), *(DIR / "inbox").glob("*.json")]):
        d = load(f, None)
        if not isinstance(d, dict) or d.get("source") != "moosas-asks" or not isinstance(d.get("asks"), dict):
            continue
        for k, a in d["asks"].items():
            if not isinstance(a, dict) or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,200}", k):
                continue
            a = {"text": redact(str(a.get("text") or ""))[:4000], "at": a.get("at"), "where": a.get("where") or "Cloud",
                 "session": a.get("session"), "title": a.get("title") or "Chat", "items": a.get("items") if isinstance(a.get("items"), list) else []}
            mine = ledger["asks"].get(k)
            if mine is None:
                ledger["asks"][k] = a; n += 1
            elif not mine.get("items") and a["items"]:
                mine["items"] = a["items"]; n += 1
        (DIR / "imported").mkdir(parents=True, exist_ok=True)
        f.replace(DIR / "imported" / f.name)
    return n


def publish(ledger):
    asks = sorted(({"id": k, **v} for k, v in ledger["asks"].items()), key=lambda a: a.get("at") or "", reverse=True)[:600]
    n = {"todo": 0, "waiting": 0, "done": 0}
    for a in asks:
        for i in a.get("items") or [{"s": "none"}]:
            s = i.get("s")
            n["todo"] += s in ("open", "waiting", "blocked", "none", None)
            n["waiting"] += s == "waiting"
            n["done"] += s in ("done", "said")
    save(DIR / "asks.json", {"updated": int(time.time()), "counts": n, "asks": asks})
    return n


def main():
    ledger = load(DIR / "ledger.json", {"asks": {}, "sessions": {}})
    ledger.setdefault("asks", {}); ledger.setdefault("sessions", {})
    offsets = load(STATE, {})
    added = scan(ledger, offsets) + import_exports(ledger)
    if added:
        save(DIR / "ledger.json", ledger)
    save(STATE, offsets)
    n = publish(ledger)
    print(f"asks: {added} new · {len(ledger['asks'])} in all · to do {n['todo']} · your turn {n['waiting']} · done {n['done']}")


if __name__ == "__main__" and sys.argv[1:] == ["--test"]:
    import tempfile
    t = Path(tempfile.mkdtemp()); HOME = t; PROJECTS = t / ".claude/projects"; DIR = t / "asks"; STATE = t / "state/offsets.json"
    p = PROJECTS / "-home-moosa"; p.mkdir(parents=True)
    rec = lambda **k: json.dumps({"type": "user", "sessionId": "s1", "timestamp": "2026-10-24T10:00:00Z", **k}) + "\n"
    (p / "s1.jsonl").write_text(rec(uuid="a1", message={"role": "user", "content": "Fix the sync hskey-auth-abc123_DEF"})
        + rec(uuid="a2", message={"role": "user", "content": [{"type": "tool_result", "content": "x"}]})
        + rec(uuid="a3", message={"role": "user", "content": "<task-notification>done</task-notification>"})
        + rec(uuid="a4", isMeta=True, message={"role": "user", "content": "meta"})
        + rec(uuid="a5", message={"role": "user", "content": [{"type": "text", "text": "Show me <pasted_content id=1>secret log</pasted_content> please"}]})
        + '{"type":"user","uuid":"half"')
    save(DIR / "ledger.json", {"asks": {"a1": {"text": "old", "items": [{"t": "x", "s": "done", "p": "proof"}]}}, "sessions": {}})
    main()
    L = load(DIR / "ledger.json", {}); A = load(DIR / "asks.json", {})
    assert set(L["asks"]) == {"a1", "a5"}, L["asks"].keys()
    assert L["asks"]["a1"]["text"] == "old", "a recorded ask keeps its text and items"
    assert L["asks"]["a5"]["text"] == "Show me [pasted output] please" and L["asks"]["a5"]["items"] == []
    assert A["counts"] == {"todo": 1, "waiting": 0, "done": 1} and A["asks"][0]["id"] in ("a1", "a5")
    with (p / "s1.jsonl").open("a") as fh: fh.write(',"message":{"role":"user","content":"late one"},"sessionId":"s1"}\n')
    main(); L = load(DIR / "ledger.json", {})
    assert "half" in L["asks"] and L["asks"]["half"]["text"] == "late one", "a line written in two goes is read once it's whole"
    assert redact("key tskey-auth-kXyZ-123 end") == "key [key hidden] end"
    (t / "Downloads").mkdir(); json.dump({"source": "moosas-asks", "asks": {"c1": {"text": "cloud ask", "where": "Cloud", "items": [{"t": "x", "s": "done", "p": "y"}]},
        "a5": {"text": "dup", "items": [{"t": "z", "s": "open"}]}, "../bad": {"text": "no"}}}, (t / "Downloads/moosas-asks-1.json").open("w"))
    json.dump({"something": "else"}, (t / "Downloads/moosas-asks-2.json").open("w"))
    main(); L = load(DIR / "ledger.json", {})
    assert L["asks"]["c1"]["text"] == "cloud ask" and L["asks"]["a5"]["items"] == [{"t": "z", "s": "open"}] and "../bad" not in L["asks"], "import adds, fills empty items, skips bad ids"
    assert (DIR / "imported/moosas-asks-1.json").exists() and not (t / "Downloads/moosas-asks-1.json").exists(), "imported file moved"
    assert (t / "Downloads/moosas-asks-2.json").exists(), "a file that isn't an export is left alone"
    print("asks-collect: ok")
elif __name__ == "__main__":
    main()
