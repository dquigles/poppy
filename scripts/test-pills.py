#!/usr/bin/env python3
"""Scripted tests for several pills (M25), run against Poppy Dev.

Like scripts/test-sessions.py, it drives Poppy Dev through its debug hook (DESIGN §12.2)
and fakes agent reports by writing into the status files; the agents are `cat` in
throwaway folders. Unlike it, it restarts Poppy Dev: first with an old (pre-M25)
state.json, later to check that a relaunch restores the layout. At the end it puts
Poppy Dev's config.json and state.json back and starts it again as it was.

Usage: ./scripts/dev.sh && ./scripts/test-pills.py
Poppy Dev briefly takes the keyboard while a test needs a panel focused.
"""
import json, os, subprocess, sys, tempfile, time, uuid

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
APP = os.path.join(ROOT, "build", "Poppy Dev.app", "Contents", "MacOS", "poppy-dev")
LOG = os.path.join(ROOT, "build", "poppy-dev.log")
DIR = os.path.expanduser("~/.config/poppy-dev")
RUN = os.path.join(DIR, "run")
CONFIG = os.path.join(DIR, "config.json")
STATE = os.path.join(DIR, "state.json")
TMP = tempfile.mkdtemp(prefix="poppy-pills-")
A, B, C = (os.path.normpath(os.path.join(TMP, n)) for n in ("proj-a", "proj-b", "proj-c"))
for d in (A, B, C):
    os.makedirs(d)

passed, failed = [], []


def cmd(op, **kw):
    """Runs one op in Poppy Dev (on pill `pill`, default the most recent) and returns its state."""
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
    if "error" in state and op != "reloadLayout":
        raise AssertionError(f"{op}: {state['error']}")
    return state


def state(pill=None):
    return cmd("state", **({} if pill is None else {"pill": pill}))


def settle(extra=0.35):
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
            raise AssertionError(f"timed out waiting for {what}; {summary(s)}")
        time.sleep(0.05)


def summary(s):
    pills = " | ".join(
        f"#{i}{'*' if i == s['recent'] else ''} {p['state']}{' key' if p['key'] else ''} "
        + ",".join(f"{x['name']}={x['status']}" + ("<" if j == p["selected"] else "") for j, x in enumerate(p["sessions"]))
        for i, p in enumerate(s["pills"]))
    return f"[{pills}]"


def expanded(s):
    return [i for i, p in enumerate(s["pills"]) if p["state"] == "expanded"]


def report(pill, index, word):
    session = state(pill)["sessions"][index]
    with open(session["statusFile"], "w") as f:
        f.write(word)


def log_size():
    return os.path.getsize(LOG) if os.path.exists(LOG) else 0


def log_since(offset):
    with open(LOG, errors="replace") as f:
        f.seek(offset)
        return f.read()


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


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


def collapse_all():
    for i, p in enumerate(state()["pills"]):
        if p["state"] == "expanded":
            cmd("collapse", pill=i)
            settle()


def reset_statuses():
    for i, p in enumerate(state()["pills"]):
        for j, x in enumerate(state(i)["sessions"]):
            if x["statusFile"] and os.path.exists(x["statusFile"]):
                report(i, j, "idle")
    wait_for(lambda s: all(x["status"] == "idle" for p in s["pills"] for x in p["sessions"]), "all idle")


def stop():
    subprocess.run(["pkill", "-x", "poppy-dev"])
    for _ in range(40):
        if subprocess.run(["pgrep", "-xq", "poppy-dev"]).returncode != 0:
            return
        time.sleep(0.25)
    sys.exit("Poppy Dev didn't stop")


def launch():
    with open(LOG, "a") as log:
        subprocess.Popen(["nohup", APP], stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    deadline = time.time() + 10
    while True:
        try:
            cid = uuid.uuid4().hex
            with open(os.path.join(RUN, f"debug-cmd-{cid}.json"), "w") as f:
                json.dump({"id": cid, "op": "state"}, f)
            answer = os.path.join(RUN, f"debug-state-{cid}.json")
            for _ in range(20):
                if os.path.exists(answer):
                    os.remove(answer)
                    return settle()
                time.sleep(0.1)
        except FileNotFoundError:
            pass
        if time.time() > deadline:
            sys.exit("Poppy Dev didn't start")


def relaunch():
    stop()
    return launch()


# --- setup: Poppy Dev from an old (pre-M25) state.json ----------------------------------

if not os.path.exists(APP):
    sys.exit("build Poppy Dev first: ./scripts/dev.sh")
original_config = open(CONFIG).read() if os.path.exists(CONFIG) else None
original_state = open(STATE).read() if os.path.exists(STATE) else None
stop()
config = json.loads(original_config or "{}")
config.update(command="cat", cwd=A, autoOpenOnInput=False, autoOpenOnDone=False, autoOpenFocus=True,
              hotkeyTarget="recent")
with open(CONFIG, "w") as f:
    json.dump(config, f)
old_origin = {"x": 400, "y": 300}
with open(STATE, "w") as f:
    json.dump({"pillOrigin": old_origin, "pillDiameter": 44, "expandedSize": {"width": 760, "height": 480}}, f)
s = launch()
print(f"Poppy Dev: {summary(s)}\nfolders: {TMP}\n")
D = 44


# --- tests -------------------------------------------------------------------------------

@test
def old_state_loads_as_one_pill():
    """an old state.json (no pills) loads as one pill with config.json's agent and folder"""
    s = state()
    check("one pill", len(s["pills"]) == 1, summary(s))
    p = s["pills"][0]
    check("at the saved origin", (p["x"], p["y"]) == (old_origin["x"], old_origin["y"]), f"{p['x']},{p['y']}")
    check("one session, cat in A", [(x["command"], x["directory"]) for x in p["sessions"]] == [("cat", A)], summary(s))
    saved = json.load(open(STATE))
    check("saved with pills", len(saved.get("pills", [])) == 1, str(saved))


@test
def new_pills_dont_overlap():
    """New Pill: expanded and focused, the other folds; pills never overlap"""
    cmd("newPill", command="cat", directory=B)
    s = settle()
    check("two pills", len(s["pills"]) == 2, summary(s))
    check("only the new one expanded", expanded(s) == [1], summary(s))
    check("it's the most recent", s["recent"] == 1, summary(s))
    cmd("newPill", command="cat", directory=C)
    s = settle()
    check("only the third expanded", expanded(s) == [2], summary(s))
    spots = [(p["x"], p["y"]) for p in s["pills"]]
    for i in range(3):
        for j in range(i + 1, 3):
            (x1, y1), (x2, y2) = spots[i], spots[j]
            check("no overlap", abs(x1 - x2) >= D or abs(y1 - y2) >= D, str(spots))


@test
def one_expanded_at_a_time():
    """expanding a pill folds the open one"""
    cmd("expand", pill=0)
    s = settle()
    check("pill 0 open, 2 folded", expanded(s) == [0], summary(s))
    cmd("expand", pill=1)
    s = settle()
    check("pill 1 open", expanded(s) == [1], summary(s))
    collapse_all()


@test
def menu_bar_lists_pills():
    """the menu bar menu lists every pill"""
    s = cmd("statusMenu")
    check("three entries", len(s["menuPills"]) == 3, str(s["menuPills"]))
    check("named by the selected session", s["menuPills"][1].startswith("proj-b"), str(s["menuPills"]))


@test
def hotkey_recent():
    """Hotkey opens the most recent pill: toggles it"""
    cmd("hotkeyTarget", key="recent")
    cmd("openPill", pill=1)
    s = settle()
    check("pill 1 open and recent", expanded(s) == [1] and s["recent"] == 1, summary(s))
    if not s["pills"][1]["key"]:
        cmd("focus", pill=1)
    cmd("hotkey")
    s = settle()
    check("folded", expanded(s) == [], summary(s))
    cmd("hotkey")
    s = settle()
    check("pill 1 again", expanded(s) == [1], summary(s))


@test
def hotkey_cycle():
    """Hotkey cycles: folds the open pill and opens the next, wrapping around"""
    cmd("hotkeyTarget", key="cycle")
    order = []
    for _ in range(3):
        s = state()
        if not s["pills"][expanded(s)[0]]["key"]:
            cmd("focus", pill=expanded(s)[0])
        cmd("hotkey")
        s = settle()
        order += expanded(s)
    check("2, 0, 1", order == [2, 0, 1], f"{order} {summary(state())}")
    collapse_all()


@test
def hotkey_urgent():
    """Hotkey opens the most urgent: the pill and session that need you, else the recent one"""
    cmd("hotkeyTarget", key="urgent")
    report(0, 0, "waiting")
    wait_for(lambda s: s["pills"][0]["sessions"][0]["status"] == "waiting", "pill 0 waiting")
    check("recent is pill 1", state()["recent"] == 1)
    cmd("hotkey")
    s = settle()
    check("pill 0 opened", expanded(s) == [0], summary(s))
    reset_statuses()
    if not state()["pills"][0]["key"]:
        cmd("focus", pill=0)
    cmd("hotkey")  # nothing urgent: the most recent (pill 0) toggles
    s = settle()
    check("folded", expanded(s) == [], summary(s))
    cmd("hotkeyTarget", key="recent")


@test
def auto_open_busy_in_other_pill():
    """Auto-Open while typing in another pill: no switch, only the color"""
    cmd("autoOpen", key="autoOpenOnInput", value=True)
    cmd("openPill", pill=1)
    settle()
    cmd("focus", pill=1)
    offset = log_size()
    report(0, 0, "waiting")
    wait_for(lambda s: s["pills"][0]["sessions"][0]["status"] == "waiting", "pill 0 waiting")
    time.sleep(0.4)
    s = state(0)
    check("pill 1 still open", expanded(s) == [1] and s["pills"][1]["key"], summary(s))
    check("pill 0 orange", s["pill"]["status"] == "waiting", str(s["pill"]))
    check("logged", "auto-open: skipped (busy in another pill)" in log_since(offset))
    reset_statuses()


@test
def auto_open_across_pills():
    """Auto-Open with no pill busy: that pill opens (the open, unfocused one folds); answering collapses"""
    cmd("blur")
    wait_for(lambda s: not s["pills"][1]["key"], "pill 1 not key")
    report(2, 0, "waiting")
    s = wait_for(lambda s: expanded(s) == [2], "pill 2 open")
    settle()
    report(2, 0, "working")
    wait_for(lambda s: expanded(s) == [], "collapsed after the answer")
    settle()
    reset_statuses()
    cmd("autoOpen", key="autoOpenOnInput", value=False)


@test
def poppy_reuses_session():
    """poppy <dir> with a session there: selects it and opens its pill, no restart, no new session"""
    before = state()
    pid = before["pills"][0]["sessions"][0]["pid"]
    total = sum(len(p["sessions"]) for p in before["pills"])
    cmd("apply", directory=A)
    s = settle()
    check("pill 0 open", expanded(s) == [0], summary(s))
    check("same agent", s["pills"][0]["sessions"][0]["pid"] == pid, summary(s))
    check("no new session", sum(len(p["sessions"]) for p in s["pills"]) == total, summary(s))


@test
def poppy_new_and_other_agent():
    """poppy -c other, --new, --new-pill: new sessions, never a restart"""
    s = state()
    n0, pills = len(s["pills"][0]["sessions"]), len(s["pills"])
    cmd("apply", directory=A, command="cat -u")
    s = settle()
    check("another agent: new session in pill 0", len(s["pills"][0]["sessions"]) == n0 + 1, summary(s))
    check("its agent", s["pills"][0]["sessions"][-1]["command"] == "cat -u", summary(s))
    cmd("apply", directory=A, command="cat -u")
    check("that one is reused now", len(state()["pills"][0]["sessions"]) == n0 + 1, summary(state()))
    cmd("apply", directory=A, new=True)
    s = settle()
    check("--new: one more", len(s["pills"][0]["sessions"]) == n0 + 2, summary(s))
    cmd("apply", directory=B, newPill=True)
    s = settle()
    check("--new-pill: a new pill, open", len(s["pills"]) == pills + 1 and expanded(s) == [pills], summary(s))


@test
def poppy_background():
    """poppy -b in a new folder: added to the most recent pill, nothing opens or switches"""
    s = state()
    recent = s["recent"]
    if not s["pills"][recent]["key"]:
        cmd("focus", pill=recent)
    s = state()
    selected = s["pills"][recent]["selected"]
    n = len(s["pills"][recent]["sessions"])
    D2 = os.path.join(TMP, "proj-d")
    os.makedirs(D2)
    cmd("apply", directory=D2, value=False)
    s = state()
    check("added", len(s["pills"][recent]["sessions"]) == n + 1, summary(s))
    check("not selected (busy)", s["pills"][recent]["selected"] == selected, summary(s))
    collapse_all()
    cmd("apply", directory=os.path.join(TMP, "proj-d"), value=False)
    s = state()
    check("reused, still collapsed", expanded(s) == [] and len(s["pills"][recent]["sessions"]) == n + 1, summary(s))


@test
def layout_saved():
    """state.json follows the layout: pills, sessions, custom names, the rail"""
    cmd("rename", pill=1, index=0, name="api")
    cmd("rail", pill=0)
    saved = json.load(open(STATE))["pills"]
    s = state()
    check("same pills", len(saved) == len(s["pills"]), f"{len(saved)} vs {summary(s)}")
    for sp, p in zip(saved, s["pills"]):
        check("sessions", [x["command"] for x in sp["sessions"]] == [x["command"] for x in p["sessions"]], str(sp))
    check("custom name", saved[1]["sessions"][0].get("name") == "api", str(saved[1]))
    check("default names not saved", "name" not in saved[0]["sessions"][0], str(saved[0]))
    check("rail", saved[0]["sidebarCollapsed"] is True, str(saved[0]))


@test
def relaunch_restores_layout():
    """quit and relaunch: the same pills and sessions, with fresh agents"""
    before = state()
    old_pids = [x["pid"] for p in before["pills"] for x in p["sessions"]]
    # Default names aren't saved, so they may renumber (e.g. "proj-b 2" once "proj-b" was renamed).
    shape = lambda s: [((p["x"], p["y"]), p["selected"], [(x["command"], x["directory"]) for x in p["sessions"]])
                       for p in s["pills"]]
    after = relaunch()
    check("same layout", shape(after) == shape(before), f"\n  before {shape(before)}\n  after  {shape(after)}")
    new_pids = [x["pid"] for p in after["pills"] for x in p["sessions"]]
    check("fresh agents", all(p > 0 and alive(p) for p in new_pids) and not set(new_pids) & set(old_pids),
          f"{old_pids} -> {new_pids}")
    check("all collapsed", expanded(after) == [], summary(after))
    check("custom name kept", after["pills"][1]["sessions"][0]["name"] == "api", summary(after))
    check("rail kept", state(0)["rail"], summary(after))


@test
def missing_folder_starts_home():
    """a saved session whose folder is gone starts in the home folder"""
    gone = os.path.join(TMP, "proj-d")
    os.rmdir(gone)
    s = relaunch()
    dirs = [x["directory"] for p in s["pills"] for x in p["sessions"]]
    check("no session in the gone folder", gone not in dirs, str(dirs))
    check("home instead", os.path.expanduser("~") in dirs, str(dirs))


@test
def closing_last_session_removes_pill():
    """closing a pill's last session removes it; the last pill too, then the hotkey brings one back"""
    reset_statuses()
    n = len(state()["pills"])
    while state()["pills"]:
        last = len(state()["pills"]) - 1
        cmd("close", pill=last, index=0)
        time.sleep(0.05)
        check("pill count", len(state()["pills"]) >= last, summary(state()))
    s = cmd("statusMenu")
    check("no pills", s["pills"] == [] and s["menuPills"] == [], summary(s))
    saved = json.load(open(STATE))
    check("saved empty", saved.get("pills") == [], str(saved))
    cmd("hotkey")
    s = settle()
    check("a new pill, open", len(s["pills"]) == 1 and expanded(s) == [0], summary(s))
    check(f"closed {n} pills", n >= 4, str(n))


# --- teardown: Poppy Dev as it was ------------------------------------------------------

stop()
for path, text in ((CONFIG, original_config), (STATE, original_state)):
    if text is None:
        os.path.exists(path) and os.remove(path)
    else:
        with open(path, "w") as f:
            f.write(text)
launch()
print(f"\n{len(passed)} passed, {len(failed)} failed")
sys.exit(1 if failed else 0)
