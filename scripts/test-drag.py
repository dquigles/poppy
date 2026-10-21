#!/usr/bin/env python3
"""Scripted tests for dragging sessions between pills (M26), run against Poppy Dev.

Like scripts/test-pills.py, it restarts Poppy Dev with `cat` as the agent in throwaway
folders, drives it through the debug hook (DESIGN §12.2) and fakes agent reports through
the status files. The drags themselves are the debug ops `moveRow`, `dropRow` and
`dropPill`, which run the same code as a drop with the mouse; the mouse part (the image,
the highlights, hit-testing) stays in the user's manual test. At the end it puts Poppy
Dev's config.json and state.json back and starts it again.

Usage: ./scripts/dev.sh && ./scripts/test-drag.py
"""
import json, os, subprocess, sys, tempfile, time, uuid

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
APP = os.path.join(ROOT, "build", "Poppy Dev.app", "Contents", "MacOS", "poppy-dev")
LOG = os.path.join(ROOT, "build", "poppy-dev.log")
DIR = os.path.expanduser("~/.config/poppy-dev")
RUN = os.path.join(DIR, "run")
CONFIG = os.path.join(DIR, "config.json")
STATE = os.path.join(DIR, "state.json")
TMP = tempfile.mkdtemp(prefix="poppy-drag-")
FOLDERS = [os.path.normpath(os.path.join(TMP, f"proj-{n}")) for n in "abcde"]
for d in FOLDERS:
    os.makedirs(d)

passed, failed = [], []


def cmd(op, **kw):
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
    return "[" + " | ".join(
        f"#{i} {p['state']} " + ",".join(f"{x['name']}={x['status']}" + ("<" if j == p["selected"] else "")
                                       for j, x in enumerate(p["sessions"]))
        for i, p in enumerate(s["pills"])) + "]"


def report(pill, index, word):
    with open(state(pill)["sessions"][index]["statusFile"], "w") as f:
        f.write(word)


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
        cid = uuid.uuid4().hex
        try:
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


def ids(s, pill):
    return [x["id"] for x in s["pills"][pill]["sessions"]]


def pids(s):
    return {x["id"]: x["pid"] for p in s["pills"] for x in p["sessions"]}


# --- setup: one pill with three sessions, a second with two -----------------------------

if not os.path.exists(APP):
    sys.exit("build Poppy Dev first: ./scripts/dev.sh")
original_config = open(CONFIG).read() if os.path.exists(CONFIG) else None
original_state = open(STATE).read() if os.path.exists(STATE) else None
stop()
config = json.loads(original_config or "{}")
config.update(command="cat", cwd=FOLDERS[0], autoOpenOnInput=False, autoOpenOnDone=False, autoOpenFocus=True,
              hotkeyTarget="recent")
with open(CONFIG, "w") as f:
    json.dump(config, f)
with open(STATE, "w") as f:
    json.dump({"pillDiameter": 44}, f)
launch()
cmd("new", directory=FOLDERS[1], pill=0)
cmd("new", directory=FOLDERS[2], pill=0)
settle()
cmd("collapse", pill=0)
cmd("newPill", directory=FOLDERS[3], value=False)
cmd("new", directory=FOLDERS[4], pill=1)
settle()
for i, p in enumerate(state()["pills"]):
    if p["state"] == "expanded":
        cmd("collapse", pill=i)
s = settle()
print(f"Poppy Dev: {summary(s)}\nfolders: {TMP}\n")
check("setup", [len(p["sessions"]) for p in s["pills"]] == [3, 2], summary(s))


@test
def reorder():
    """reorder within the sidebar: the selected session stays selected, the order is saved"""
    cmd("click", pill=0, index=1)
    before = ids(state(), 0)
    s = cmd("moveRow", pill=0, index=0, target=2)
    after = ids(s, 0)
    check("order", after == [before[1], before[2], before[0]], f"{before} -> {after}")
    check("selection follows", s["pills"][0]["selected"] == 0, summary(s))
    saved = json.load(open(STATE))["pills"][0]
    check("saved", [x["cwd"].split("/")[-1] for x in saved["sessions"]] == ["proj-b", "proj-c", "proj-a"]
          and saved["selected"] == 0, str(saved))


@test
def drag_out_to_new_pill():
    """a working session dragged out: a new collapsed pill at the point, same agent, status rewired"""
    report(0, 1, "working")
    s = wait_for(lambda s: s["pills"][0]["sessions"][1]["status"] == "working", "working")
    moving = s["pills"][0]["sessions"][1]
    before = pids(s)
    s = cmd("dropRow", pill=0, index=1, x=600, y=500)
    check("three pills", len(s["pills"]) == 3, summary(s))
    new = s["pills"][2]
    check("collapsed", new["state"] == "collapsed", summary(s))
    check("near the point", abs(new["x"] + 22 - 600) < 1 and abs(new["y"] + 22 - 500) < 1, f"{new['x']},{new['y']}")
    check("same session", [x["id"] for x in new["sessions"]] == [moving["id"]] and new["sessions"][0]["name"] == moving["name"],
          summary(s))
    check("no restart", pids(s)[moving["id"]] == before[moving["id"]] > 0, f"{before} -> {pids(s)}")
    check("status kept", new["sessions"][0]["status"] == "working", summary(s))
    check("source has two", len(s["pills"][0]["sessions"]) == 2, summary(s))
    report(2, 0, "waiting")
    s = wait_for(lambda s: s["pills"][2]["sessions"][0]["status"] == "waiting", "waiting in the new pill")
    check("new pill's color", state(2)["pill"]["status"] == "waiting", str(state(2)["pill"]))
    check("source untouched", state(0)["pill"]["status"] != "waiting", str(state(0)["pill"]))


@test
def drop_onto_collapsed_pill():
    """dropped onto another collapsed pill: joins its end; its position, selection and state stay"""
    s = state()
    target = s["pills"][1]
    moving = s["pills"][0]["sessions"][0]
    s = cmd("dropRow", pill=0, index=0, target=1)
    t = s["pills"][1]
    check("joined at the end", [x["id"] for x in t["sessions"]][-1] == moving["id"] and len(t["sessions"]) == 3, summary(s))
    check("position kept", (t["x"], t["y"]) == (target["x"], target["y"]), str(t))
    check("selection kept", t["selected"] == target["selected"], summary(s))
    check("still collapsed", t["state"] == "collapsed", summary(s))
    check("source alone, sidebar hidden", len(s["pills"][0]["sessions"]) == 1 and state(0)["sidebarWidth"] == 0,
          str(state(0)["sidebarWidth"]))
    report(1, 2, "done")
    s = wait_for(lambda s: s["pills"][1]["sessions"][2]["status"] == "done", "done in the target")
    check("badge on the target", state(1)["pill"]["badge"] >= 1, str(state(1)["pill"]))


@test
def auto_open_follows_the_move():
    """Auto-Open after a move: the session's new pill expands on it"""
    cmd("autoOpen", key="autoOpenOnInput", value=True)
    try:
        report(1, 2, "waiting")
        s = wait_for(lambda s: s["pills"][1]["state"] == "expanded", "the target pill to open", timeout=4)
        s = settle()
        check("on that session", s["pills"][1]["selected"] == 2, summary(s))
        check("only that pill", [p["state"] for p in s["pills"]].count("expanded") == 1, summary(s))
    finally:
        cmd("autoOpen", key="autoOpenOnInput", value=False)
        for i, p in enumerate(state()["pills"]):
            if p["state"] == "expanded":
                cmd("collapse", pill=i)
        settle()


@test
def merge_pills():
    """a 3-session pill dropped onto a 2-session pill: 5 rows; position and selection kept"""
    # pills now: #0 one session, #1 three, #2 one. Give #0 a second session, then merge #1 onto #0.
    cmd("new", pill=0, directory=FOLDERS[0])
    settle()
    for i, p in enumerate(state()["pills"]):
        if p["state"] == "expanded":
            cmd("collapse", pill=i)
    s = settle()
    target, source = s["pills"][0], s["pills"][1]
    check("sizes", len(target["sessions"]) == 2 and len(source["sessions"]) == 3, summary(s))
    before = pids(s)
    s = cmd("dropPill", pill=1, target=0)
    t = s["pills"][0]
    check("two pills left", len(s["pills"]) == 2, summary(s))
    check("five rows in order", [x["id"] for x in t["sessions"]] == ids({"pills": [target]}, 0) + ids({"pills": [source]}, 0),
          summary(s))
    check("position kept", (t["x"], t["y"]) == (target["x"], target["y"]), str(t))
    check("selection kept", t["selected"] == target["selected"], summary(s))
    check("collapsed", t["state"] == "collapsed", summary(s))
    check("no restarts", all(pids(s)[k] == v for k, v in before.items() if k in pids(s)) and len(pids(s)) == len(before),
          f"{before} -> {pids(s)}")
    saved = json.load(open(STATE))["pills"]
    check("saved", [len(p["sessions"]) for p in saved] == [5, 1], str([len(p["sessions"]) for p in saved]))


@test
def drop_pill_onto_open_panel():
    """a pill dropped onto an open panel: its sessions join that sidebar; it stays open on its session"""
    s = state()
    target = s["pills"][0]
    cmd("expand", pill=0)
    s = settle()
    check("open", s["pills"][0]["state"] == "expanded", summary(s))
    selected_id = s["pills"][0]["sessions"][s["pills"][0]["selected"]]["id"]
    moving = s["pills"][1]["sessions"][0]["id"]
    pill = s["pills"][1]
    cx, cy = s["frame"][0] + s["frame"][2] / 2, s["frame"][1] + s["frame"][3] / 2
    cmd("drag", pill=1, key="pillMove", x=cx, y=cy)
    cmd("drag", pill=1, key="pillEnd", x=cx, y=cy)
    s = wait_for(lambda s: len(s["pills"]) == 1, "the dropped pill to go")
    t = s["pills"][0]
    check("joined at the end", t["sessions"][-1]["id"] == moving and len(t["sessions"]) == len(target["sessions"]) + 1,
          summary(s))
    check("still open", t["state"] == "expanded", summary(s))
    check("selection kept", t["sessions"][t["selected"]]["id"] == selected_id, summary(s))
    cmd("collapse", pill=0)
    settle()


@test
def names_stay_unique():
    """names stay unique after moving; every session has its own status file"""
    s = state()
    names = [x["name"] for p in s["pills"] for x in p["sessions"]]
    check("unique", len(names) == len(set(names)), str(names))
    files = [state(i)["sessions"][j]["statusFile"] for i, p in enumerate(s["pills"]) for j in range(len(p["sessions"]))]
    check("status files", len(files) == len(set(files)), str(files))


# --- teardown ---------------------------------------------------------------------------

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
