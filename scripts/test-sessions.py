#!/usr/bin/env python3
"""Scripted tests for sessions and the sidebar (M24), run against Poppy Dev.

Drives Poppy Dev through its debug hook (DESIGN §12.2): writes debug-cmd-<id>.json into
~/.config/poppy-dev/run/ and reads back debug-state-<id>.json. Agent reports are faked by
writing a status word into a session's status file, exactly as the agents' hooks do.
Fake agents are `cat` in throwaway folders, so no real agent is started.

Usage: ./scripts/dev.sh && ./scripts/test-sessions.py
Poppy Dev briefly takes the keyboard while a test needs its panel focused.
"""
import json, os, signal, sys, tempfile, time, uuid

RUN = os.path.expanduser("~/.config/poppy-dev/run")
CONFIG = os.path.expanduser("~/.config/poppy-dev/config.json")
LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build", "poppy-dev.log")
TMP = tempfile.mkdtemp(prefix="poppy-tests-")
A = os.path.join(TMP, "proj-a")
B = os.path.join(TMP, "proj-b")
for d in (A, B):
    os.makedirs(d)
# Poppy normalizes paths without resolving symlinks (/private/var stays /var, DESIGN §9.8).
A, B = os.path.normpath(A), os.path.normpath(B)

passed, failed = [], []


def cmd(op, **kw):
    """Runs one op in Poppy Dev and returns its state afterwards."""
    cid = uuid.uuid4().hex
    tmp = os.path.join(RUN, f".tmp-{cid}")
    with open(tmp, "w") as f:
        json.dump({"id": cid, "op": op, **kw}, f)
    os.rename(tmp, os.path.join(RUN, f"debug-cmd-{cid}.json"))
    answer = os.path.join(RUN, f"debug-state-{cid}.json")
    deadline = time.time() + 5
    while not os.path.exists(answer):
        if time.time() > deadline:
            sys.exit(f"Poppy Dev didn't answer '{op}' (is it running? ./scripts/dev.sh)")
        time.sleep(0.05)
    with open(answer) as f:
        state = json.load(f)
    os.remove(answer)
    if "error" in state:
        raise AssertionError(f"{op}: {state['error']}")
    return state


def state():
    return cmd("state")


def settle(extra=0.35):
    """Waits for animations (and the fades after them) to end."""
    deadline = time.time() + 5
    while state()["animating"]:
        if time.time() > deadline:
            raise AssertionError("still animating after 5 s")
        time.sleep(0.05)
    time.sleep(extra)
    return state()


def wait_for(predicate, what, timeout=3):
    deadline = time.time() + timeout
    while True:
        s = state()
        if predicate(s):
            return s
        if time.time() > deadline:
            raise AssertionError(f"timed out waiting for {what}; state: {summary(s)}")
        time.sleep(0.05)


def summary(s):
    rows = ", ".join(f"{i}:{x['name']}={x['status']}" + ("*" if i == s["selected"] else "")
                     for i, x in enumerate(s["sessions"]))
    return (f"{s['state']} key={s['key']} pill={s['pill']['status']} badge={s['pill']['badge']} "
            f"sidebar={s['sidebarWidth']} [{rows}]")


def report(session, word):
    """What an agent's hook does: one word into its status file (only if it exists)."""
    path = session["statusFile"]
    assert path and os.path.exists(path), f"{session['name']} has no status file"
    with open(path, "w") as f:
        f.write(word)


def by_id(s, sid):
    return next((x for x in s["sessions"] if x["id"] == sid), None)


def index_of(s, sid):
    return next(i for i, x in enumerate(s["sessions"]) if x["id"] == sid)


def statuses(s):
    return [x["status"] for x in s["sessions"]]


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def log_size():
    return os.path.getsize(LOG) if os.path.exists(LOG) else 0


def log_since(offset):
    with open(LOG, errors="replace") as f:
        f.seek(offset)
        return f.read()


def check(name, condition, detail=""):
    if not condition:
        raise AssertionError(f"{name} {detail}".strip())


def test(fn):
    name = fn.__doc__ or fn.__name__
    try:
        fn()
        passed.append(name)
        print(f"  ok    {name}")
    except AssertionError as e:
        failed.append((name, str(e)))
        print(f"  FAIL  {name}\n        {e}")
    return fn


def reset_statuses():
    for x in state()["sessions"]:
        if x["statusFile"] and os.path.exists(x["statusFile"]):
            report(x, "idle")
    wait_for(lambda s: all(st == "idle" for st in statuses(s)), "every session idle")


def close_extra_sessions():
    """Back to the first session only, answering any confirmation."""
    reset_statuses()
    while len(state()["sessions"]) > 1:
        s = state()
        if s["confirm"]:
            cmd("confirm", value=True)
        cmd("close", index=len(s["sessions"]) - 1)
        time.sleep(0.05)


# --- setup -------------------------------------------------------------------------------

with open(CONFIG) as f:
    original = json.load(f)
s = settle()
if s["state"] == "expanded":
    cmd("collapse")
    s = settle()
close_extra_sessions()
first_id = state()["sessions"][0]["id"]
for key in ("autoOpenOnInput", "autoOpenOnDone", "autoOpenFocus"):
    cmd("autoOpen", key=key, value=False)
print(f"Poppy Dev: {summary(state())}\nfolders: {TMP}\n")

ids = {}


# --- tests -------------------------------------------------------------------------------

@test
def single_session_unchanged():
    """one session: no sidebar, no badge, label and header as before"""
    s = state()
    check("sidebar hidden", s["sidebarWidth"] == 0, summary(s))
    check("no badge", s["pill"]["badge"] == 0)
    check("label has no session name", " — " not in s["pill"]["label"], s["pill"]["label"])
    check("header is the folder name", s["header"] == s["sessions"][0]["name"], s["header"])


@test
def new_sessions_and_names():
    """three new sessions: two in one folder are 'proj-a' and 'proj-a 2'"""
    cmd("new", command="cat", directory=A)
    cmd("new", command="cat", directory=A)
    s = cmd("new", command="cat", directory=B)
    names = [x["name"] for x in s["sessions"][1:]]
    check("names", names == ["proj-a", "proj-a 2", "proj-b"], str(names))
    ids.update(a1=s["sessions"][1]["id"], a2=s["sessions"][2]["id"], b=s["sessions"][3]["id"])
    check("newest selected", s["selected"] == 3, summary(s))
    check("sidebar shown", s["sidebarWidth"] == 168, summary(s))
    check("header is the selected name", s["header"] == "proj-b", s["header"])
    shown = [x["shown"] for x in s["sessions"]]
    check("only the selected terminal is in the panel", shown == [False, False, False, True], str(shown))
    settle()
    if state()["state"] == "expanded":
        cmd("collapse")
        settle()


@test
def status_files_unique():
    """every session has its own status file (the M24 collision fix)"""
    s = state()
    files = [x["statusFile"] for x in s["sessions"]]
    check("all set", all(files), str(files))
    check("all different", len(set(files)) == len(files), str(files))
    pids = [x["pid"] for x in s["sessions"]]
    check("agents running", all(p > 0 and alive(p) for p in pids), str(pids))


@test
def status_never_crosses():
    """a report changes only its own session; the pill takes the most urgent"""
    s = state()
    report(by_id(s, ids["a1"]), "working")
    s = wait_for(lambda s: by_id(s, ids["a1"])["status"] == "working", "a1 working")
    check("only a1 working", sorted(statuses(s)) == ["idle", "idle", "idle", "working"], summary(s))
    check("pill working", s["pill"]["status"] == "working")
    check("no badge for working", s["pill"]["badge"] == 0)
    report(by_id(s, ids["a2"]), "waiting")
    s = wait_for(lambda s: by_id(s, ids["a2"])["status"] == "waiting", "a2 waiting")
    check("a1 still working", by_id(s, ids["a1"])["status"] == "working", summary(s))
    check("pill orange (waiting beats working)", s["pill"]["status"] == "waiting", summary(s))
    check("badge 1", s["pill"]["badge"] == 1, summary(s))
    check("label counts it", "1 session needs you" in s["pill"]["label"], s["pill"]["label"])
    report(by_id(s, ids["b"]), "done")
    s = wait_for(lambda s: by_id(s, ids["b"])["status"] == "done", "b done")
    check("badge 2 (waiting + unseen done)", s["pill"]["badge"] == 2, summary(s))
    reset_statuses()
    s = state()
    check("pill idle again", s["pill"]["status"] == "idle" and s["pill"]["badge"] == 0, summary(s))


@test
def busy_no_switch():
    """auto-open while typing in another session: no switch, only color and badge"""
    cmd("autoOpen", key="autoOpenOnInput", value=True)
    cmd("autoOpen", key="autoOpenFocus", value=True)
    cmd("expand")
    settle()
    if not state()["key"]:
        cmd("focus")
    s = cmd("click", index=index_of(state(), ids["b"]))
    s = wait_for(lambda s: s["state"] == "expanded" and s["key"], "panel expanded and key")
    before = s["selected"]
    offset = log_size()
    report(by_id(s, ids["a1"]), "waiting")
    s = wait_for(lambda s: by_id(s, ids["a1"])["status"] == "waiting", "a1 waiting")
    time.sleep(0.3)
    s = state()
    check("selection unchanged", s["selected"] == before, summary(s))
    check("still expanded and key", s["state"] == "expanded" and s["key"], summary(s))
    check("pill orange, badge 1", s["pill"]["status"] == "waiting" and s["pill"]["badge"] == 1, summary(s))
    check("logged as busy", "auto-open: skipped (busy in another session)" in log_since(offset))
    reset_statuses()


@test
def expanded_not_key_selects():
    """auto-open with the panel open but not key: selects that session"""
    cmd("autoOpen", key="autoOpenFocus", value=False)  # stays unfocused
    cmd("blur")
    s = wait_for(lambda s: not s["key"], "panel not key")
    report(by_id(s, ids["a2"]), "waiting")
    s = wait_for(lambda s: s["selected"] == index_of(s, ids["a2"]), "a2 selected")
    check("still not key (focus off)", not s["key"], summary(s))
    check("header follows", s["header"] == "proj-a 2", s["header"])
    reset_statuses()


@test
def collapsed_auto_open_selects_then_collapses():
    """collapsed: a background session's prompt expands the pill on it; answering collapses"""
    cmd("focus")
    cmd("collapse")
    settle()
    s = state()
    target = ids["a1"]
    check("a1 not selected", s["selected"] != index_of(s, target), summary(s))
    report(by_id(s, target), "waiting")
    s = wait_for(lambda s: s["state"] == "expanded", "expanded")
    s = settle()
    check("a1 selected", s["selected"] == index_of(s, target), summary(s))
    check("auto-opened for waiting", s["autoOpenedFor"] == "waiting", summary(s))
    report(by_id(s, target), "working")
    s = wait_for(lambda s: s["state"] == "collapsed", "collapsed after the answer")
    settle()
    reset_statuses()


@test
def answer_in_other_session_does_not_collapse():
    """the auto-collapse only follows the session that opened it, while it's shown"""
    s = state()
    report(by_id(s, ids["a2"]), "waiting")
    s = wait_for(lambda s: s["state"] == "expanded", "expanded")
    settle()
    report(by_id(state(), ids["b"]), "working")  # another session starts working
    time.sleep(0.6)
    s = state()
    check("still expanded", s["state"] == "expanded", summary(s))
    cmd("focus")
    cmd("collapse")
    settle()
    reset_statuses()


@test
def done_seen_only_when_looked_at():
    """done stays green in the background; selecting it while key clears it"""
    s = state()
    report(by_id(s, ids["b"]), "done")
    s = wait_for(lambda s: by_id(s, ids["b"])["status"] == "done", "b done")
    time.sleep(0.3)
    check("still done while collapsed", by_id(state(), ids["b"])["status"] == "done")
    cmd("expand")
    settle()
    cmd("focus")
    s = wait_for(lambda s: s["key"], "key")
    if s["selected"] == index_of(s, ids["b"]):
        cmd("cmdN", index=0)
    check("b still done (not selected)", by_id(state(), ids["b"])["status"] == "done", summary(state()))
    cmd("cmdN", index=index_of(state(), ids["b"]))  # ⌘n
    s = wait_for(lambda s: by_id(s, ids["b"])["status"] == "idle", "b seen")
    check("selected b", s["selected"] == index_of(s, ids["b"]), summary(s))
    report(by_id(s, ids["b"]), "done")  # done while selected and key: seen at once
    wait_for(lambda s: by_id(s, ids["b"])["status"] == "idle", "b seen at once")


@test
def rename():
    """rename, empty name back to the folder name, numbering kept unique"""
    i = index_of(state(), ids["a2"])
    s = cmd("rename", index=i, name="  api  ")
    check("custom name trimmed", s["sessions"][i]["name"] == "api" and s["sessions"][i]["custom"], summary(s))
    s = cmd("rename", index=i, name="")
    check("default again", s["sessions"][i]["name"] == "proj-a 2" and not s["sessions"][i]["custom"], summary(s))
    a1 = index_of(s, ids["a1"])
    s = cmd("rename", index=a1, name="x")
    s = cmd("rename", index=i, name="")
    check("lowest free number", s["sessions"][i]["name"] == "proj-a", summary(s))
    s = cmd("rename", index=a1, name="")
    check("then the other gets 2", s["sessions"][a1]["name"] == "proj-a 2", summary(s))
    s = cmd("rename", index=a1, name=None)
    check("cancel keeps it", s["sessions"][a1]["name"] == "proj-a 2", summary(s))


@test
def rail():
    """the rail narrows the sidebar; the terminal widens by the same amount"""
    s = state()
    wide = s["terminalWidth"]
    s = cmd("rail")
    check("rail 44", s["sidebarWidth"] == 44 and s["rail"], summary(s))
    check("terminal wider", abs(s["terminalWidth"] - (wide + 168 - 44)) < 0.5, f"{wide} -> {s['terminalWidth']}")
    s = cmd("rail")
    check("names again", s["sidebarWidth"] == 168 and abs(s["terminalWidth"] - wide) < 0.5, summary(s))


@test
def sidebar_drag():
    """dragging the edge: resizes within 120–360, snaps to the rail below 96, opens again"""
    s = state()
    wide = s["terminalWidth"] + s["sidebarWidth"]
    s = cmd("dragSidebar", width=240)
    check("240 wide", s["sidebarWidth"] == 240 and not s["rail"], summary(s))
    check("terminal gives way", abs(s["terminalWidth"] + 240 - wide) < 0.5, f"{s['terminalWidth']}")
    s = cmd("dragSidebar", width=100)
    check("not below 120", s["sidebarWidth"] == 120 and not s["rail"], summary(s))
    s = cmd("dragSidebar", width=60)
    check("snaps to the rail", s["sidebarWidth"] == 44 and s["rail"], summary(s))
    s = cmd("dragSidebar", width=200)
    check("opens again", s["sidebarWidth"] == 200 and not s["rail"], summary(s))
    s = cmd("dragSidebar", width=5000)
    check("at most 360", s["sidebarWidth"] == min(360, wide + 8 - 240), summary(s))
    cmd("dragSidebar", width=168)


@test
def sidebar_scrolls_only_when_needed():
    """no scrolling with a few rows; scrolling once they don't fit"""
    s = state()
    check("4 rows: no scrolling", not s["sidebarScrolls"], summary(s))
    n = len(s["sessions"])
    for _ in range(20):
        cmd("new", command="cat", directory=B)
    s = state()
    check("24 rows: scrolls", s["sidebarScrolls"], summary(s))
    while len(state()["sessions"]) > n:
        cmd("close", index=len(state()["sessions"]) - 1)
    s = state()
    check("back to 4: no scrolling", not s["sidebarScrolls"], summary(s))


@test
def keys_blocked_under_settings():
    """⌘T and ⌘W do nothing while the settings page shows"""
    n = len(state()["sessions"])
    cmd("settings", value=True)
    settle()
    cmd("cmdT")
    s = cmd("cmdW")
    check("count unchanged", len(s["sessions"]) == n, summary(s))
    cmd("settings", value=False)
    s = settle()
    check("settings closed", not s["settings"])


@test
def cmd_t_copies_selected():
    """⌘T: same agent and folder as the selected session, selected"""
    cmd("cmdN", index=index_of(state(), ids["b"]))
    s = cmd("cmdT")
    new = s["sessions"][-1]
    check("same folder", new["directory"] == B, new["directory"])
    check("same agent", new["command"] == "cat", new["command"])
    check("numbered", new["name"] == "proj-b 2", new["name"])
    check("selected", s["selected"] == len(s["sessions"]) - 1, summary(s))
    ids["b2"] = new["id"]


@test
def close_idle_background():
    """closing a background idle session: no question, agent ends, selection kept"""
    s = state()
    selected_id = s["sessions"][s["selected"]]["id"]
    victim = by_id(s, ids["a2"])
    s = cmd("close", index=index_of(s, ids["a2"]))
    check("removed", by_id(s, ids["a2"]) is None, summary(s))
    check("selection kept", s["sessions"][s["selected"]]["id"] == selected_id, summary(s))
    check("status file removed", not os.path.exists(victim["statusFile"]))
    time.sleep(1.2)
    check("agent ended", not alive(victim["pid"]), f"pid {victim['pid']}")


@test
def close_working_asks():
    """closing a working session asks; Cancel keeps it, Close ends it"""
    s = state()
    victim = by_id(s, ids["a1"])
    report(victim, "working")
    wait_for(lambda s: by_id(s, ids["a1"])["status"] == "working", "a1 working")
    s = cmd("close", index=index_of(state(), ids["a1"]))
    check("confirmation shown", s["confirm"], summary(s))
    check("still there", by_id(s, ids["a1"]) is not None)
    check("its terminal greyed (live one out)", not by_id(s, ids["a1"])["shown"], summary(s))
    check("question centered on the terminal", s["confirmAligned"], summary(s))
    check("header and sidebar untouched", s["sidebarWidth"] == 168, summary(s))
    s = cmd("cmdW")
    check("⌘W ignored while asking", s["confirm"] and by_id(s, ids["a1"]) is not None, summary(s))
    s = cmd("confirm", value=False)
    check("cancel keeps it", by_id(s, ids["a1"]) is not None and not s["confirm"], summary(s))
    check("its terminal back", by_id(s, ids["a1"])["shown"], summary(s))
    n = len(s["sessions"])
    cmd("close", index=index_of(state(), ids["a1"]))
    s = cmd("cmdT")
    check("⌘T cancels and adds", not s["confirm"] and len(s["sessions"]) == n + 1
          and by_id(s, ids["a1"]) is not None, summary(s))
    cmd("close", index=len(s["sessions"]) - 1)
    cmd("close", index=index_of(state(), ids["a1"]))
    s = cmd("confirm", value=True)
    check("closed", by_id(s, ids["a1"]) is None, summary(s))
    time.sleep(1.2)
    check("agent ended", not alive(victim["pid"]), f"pid {victim['pid']}")


@test
def close_selected_selects_neighbour():
    """⌘W on the selected session: the next one, or the previous if it was last"""
    s = state()
    last = len(s["sessions"]) - 1
    cmd("cmdN", index=last)
    s = cmd("cmdW")
    check("previous selected", s["selected"] == len(s["sessions"]) - 1, summary(s))
    check("its terminal shown", s["sessions"][s["selected"]]["shown"], summary(s))


@test
def exited_agent_keeps_row():
    """an agent that exits on its own keeps its row"""
    s = cmd("new", command="exit 3", directory=A)
    sid = s["sessions"][-1]["id"]
    s = wait_for(lambda s: by_id(s, sid)["exited"], "agent exited", timeout=8)
    check("row kept", by_id(s, sid) is not None and by_id(s, sid)["status"] == "idle", summary(s))
    cmd("close", index=index_of(s, sid))


@test
def back_to_one_session():
    """closing down to one session hides the sidebar and the badge; ⌘W then does nothing"""
    close_extra_sessions()
    s = state()
    check("one left, the first", len(s["sessions"]) == 1 and s["sessions"][0]["id"] == first_id, summary(s))
    check("sidebar hidden", s["sidebarWidth"] == 0, summary(s))
    check("label as before", " — " not in s["pill"]["label"], s["pill"]["label"])
    s = cmd("cmdW")
    check("last session stays", len(s["sessions"]) == 1)


# --- teardown ----------------------------------------------------------------------------

cmd("focus") if state()["state"] == "expanded" else None
if state()["state"] == "expanded":
    cmd("collapse")
    settle()
for key in ("autoOpenOnInput", "autoOpenOnDone", "autoOpenFocus"):
    default = key == "autoOpenFocus"
    cmd("autoOpen", key=key, value=original.get(key, default))

print(f"\n{len(passed)} passed, {len(failed)} failed")
sys.exit(1 if failed else 0)
