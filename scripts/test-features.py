#!/usr/bin/env python3
"""Scripted tests for what the other scripts don't cover, run against Poppy Dev:
resuming conversations on relaunch (DESIGN §9.16), Fold when you send a prompt (§7.15),
the Panel settings (keep open and the pin, hide the pill, fade; §6.3, §7.20, §7.21),
numeric settings being clamped and saved (§8.1), and the intro (§9.15).

Like scripts/test-pills.py it drives Poppy Dev through its debug hook (DESIGN §12.2),
restarts it, and puts its config.json and state.json back at the end. Agents are fakes:
`cat`, and scripts named claude, codex and opencode that log their arguments and then run
`cat`, so resuming is checked through the real command line without starting an agent.
Poppy Dev runs with CODEX_HOME and XDG_CONFIG_HOME in a temp folder, so the Codex and
opencode hooks it installs never touch your real ~/.codex or ~/.config/opencode.

Usage: ./scripts/dev.sh && ./scripts/test-features.py
Poppy Dev briefly takes the keyboard while a test needs a panel focused. The fade test
assumes the mouse isn't over the panel (hovering keeps it at full opacity).
"""
import json, os, subprocess, sys, tempfile, time, uuid

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
APP = os.path.join(ROOT, "build", "Poppy Dev.app", "Contents", "MacOS", "poppy-dev")
LOG = os.path.join(ROOT, "build", "poppy-dev.log")
DIR = os.path.expanduser("~/.config/poppy-dev")
RUN = os.path.join(DIR, "run")
CONFIG = os.path.join(DIR, "config.json")
STATE = os.path.join(DIR, "state.json")
TMP = os.path.normpath(tempfile.mkdtemp(prefix="poppy-features-"))
A, B = (os.path.join(TMP, n) for n in ("proj-a", "proj-b"))
BIN = os.path.join(TMP, "bin")
CODEX_HOME = os.path.join(TMP, "codex-home")
XDG = os.path.join(TMP, "xdg")
for d in (A, B, BIN, CODEX_HOME, XDG):
    os.makedirs(d)

# Fake agents: log the arguments they got (one line per start), then behave like `cat`.
FAKES = {}
for name in ("claude", "codex", "opencode"):
    path = os.path.join(BIN, name)
    with open(path, "w") as f:
        f.write(f'#!/bin/sh\nprintf "%s\\n" "$*" >> "{TMP}/{name}-args.log"\nexec cat\n')
    os.chmod(path, 0o755)
    FAKES[name] = path

passed, failed = [], []


def cmd(op, **kw):
    """Runs one op in Poppy Dev (on the most recent pill) and returns its state."""
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
    rows = ", ".join(f"{i}:{x['name']}={x['status']}" + ("*" if i == s["selected"] else "")
                     + (f" conv={x['conversation']}" if x.get("conversation") else "")
                     for i, x in enumerate(s["sessions"]))
    return (f"{s['state']} key={s['key']} settings={s['settings']} pinned={s['pinned']} "
            f"visible={s['visible']} fade={s['fade']} [{rows}]")


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
    finally:
        tidy()
    return fn


def tidy():
    """Back to a known state between tests: settings page and pin off, collapsed, all idle."""
    try:
        s = state()
        if s["intro"]:
            cmd("intro", value=False)
        if s["settings"]:
            cmd("settings", value=False)
        if s["pinned"]:
            cmd("pin")
        cmd("autoOpen", key="foldOnPrompt", value=False)
        if state()["state"] == "expanded":
            cmd("collapse")
        settle(0.1)
        for i, x in enumerate(state()["sessions"]):
            if x["status"] != "idle" and x["statusFile"] and os.path.exists(x["statusFile"]):
                report(i, "idle")
        wait_for(lambda s: all(x["status"] == "idle" for x in s["sessions"]), "all idle")
    except AssertionError as e:
        print(f"        (tidy: {e})")


def report(index, word):
    """Fakes a status hook: writes the word into the session's status file."""
    path = state()["sessions"][index]["statusFile"]
    check("status file", path and os.path.exists(path), f"session {index} has none")
    with open(path, "w") as f:
        f.write(word)


def record_conversation(index, conversation):
    """Fakes the conversation hook (DESIGN §9.16)."""
    path = state()["sessions"][index]["statusFile"]
    check("status file", path and os.path.exists(path), f"session {index} has none")
    with open(path + ".conversation", "w") as f:
        f.write(conversation)


def args_lines(name):
    path = os.path.join(TMP, f"{name}-args.log")
    return open(path).read().splitlines() if os.path.exists(path) else []


def wait_args(name, count, timeout=8):
    """The fake agent's argument lines, once it has started `count` times."""
    deadline = time.time() + timeout
    while len(args_lines(name)) < count:
        if time.time() > deadline:
            raise AssertionError(f"{name} started {len(args_lines(name))} times, expected {count}")
        time.sleep(0.1)
    return args_lines(name)


def saved_sessions():
    with open(STATE) as f:
        return [x for p in json.load(f).get("pills") or [] for x in p["sessions"]]


def saved_config():
    with open(CONFIG) as f:
        return json.load(f)


def index_of(command):
    for i, x in enumerate(state()["sessions"]):
        if x["command"] == command:
            return i
    raise AssertionError(f"no session running {command}; {summary(state())}")


def focus_expanded(index=0):
    cmd("click", index=index)
    if state()["state"] != "expanded":
        cmd("expand", value=True)
    s = settle()
    if not s["key"]:
        cmd("focus")
        s = wait_for(lambda s: s["key"], "the panel to take the keyboard")
    check("expanded and key", s["state"] == "expanded" and s["key"], summary(s))
    return s


def log_size():
    return os.path.getsize(LOG) if os.path.exists(LOG) else 0


def log_since(offset):
    with open(LOG, errors="replace") as f:
        f.seek(offset)
        return f.read()


def stop():
    subprocess.run(["pkill", "-x", "poppy-dev"])
    for _ in range(40):
        if subprocess.run(["pgrep", "-xq", "poppy-dev"]).returncode != 0:
            return
        time.sleep(0.25)
    sys.exit("Poppy Dev didn't stop")


def launch(isolated=True):
    env = dict(os.environ)
    if isolated:
        env.update(CODEX_HOME=CODEX_HOME, XDG_CONFIG_HOME=XDG)
    with open(LOG, "a") as log:
        subprocess.Popen(["nohup", APP], stdout=log, stderr=subprocess.STDOUT, start_new_session=True, env=env)
    deadline = time.time() + 10
    while True:
        cid = uuid.uuid4().hex
        try:
            with open(os.path.join(RUN, f"debug-cmd-{cid}.json"), "w") as f:
                json.dump({"id": cid, "op": "state"}, f)
        except FileNotFoundError:
            pass
        answer = os.path.join(RUN, f"debug-state-{cid}.json")
        for _ in range(20):
            if os.path.exists(answer):
                os.remove(answer)
                return settle()
            time.sleep(0.1)
        if time.time() > deadline:
            sys.exit("Poppy Dev didn't start")


# --- setup ------------------------------------------------------------------------------

if not os.path.exists(APP):
    sys.exit("build Poppy Dev first: ./scripts/dev.sh")
# Started again at the end only if it was running now (it isn't left running otherwise).
was_running = subprocess.run(["pgrep", "-xq", "poppy-dev"]).returncode == 0
original_config = open(CONFIG).read() if os.path.exists(CONFIG) else None
original_state = open(STATE).read() if os.path.exists(STATE) else None
stop()
config = json.loads(original_config or "{}")
config.update(command="cat", cwd=A, statusHooks=True, autoOpenOnInput=False, autoOpenOnDone=False,
              autoOpenFocus=True, foldOnPrompt=False, foldOnClickOutside=True, fadeWhenInactive=False,
              hidePill=False, introShown=True)
with open(CONFIG, "w") as f:
    json.dump(config, f)
with open(STATE, "w") as f:
    json.dump({"pills": [{"origin": {"x": 300, "y": 300}, "selected": 0,
                          "sessions": [{"command": "cat", "cwd": A}]}], "pillDiameter": 44}, f)
s = launch()
print(f"Poppy Dev: {summary(s)}\nfolders: {TMP}\n")


# --- resuming conversations (DESIGN §9.16) ----------------------------------------------

IDS = {"claude": "11111111-aaaa-4bbb-8ccc-000000000001", "codex": "22222222-aaaa-4bbb-8ccc-000000000002",
       "opencode": "ses_3fA9xYz"}


@test
def conversations_are_recorded_and_saved():
    """each agent's conversation id, reported by its hook, is shown and saved in state.json"""
    for name, path in FAKES.items():
        cmd("new", command=path, directory=B)
        wait_args(name, 1)
        check(f"{name} starts fresh", "--resume" not in args_lines(name)[0] and "resume " not in args_lines(name)[0]
              and "--session" not in args_lines(name)[0], args_lines(name)[0])
    for name, path in FAKES.items():
        record_conversation(index_of(path), IDS[name])
    s = wait_for(lambda s: all(x["conversation"] == IDS[n] for n, p in FAKES.items()
                               for x in s["sessions"] if x["command"] == p), "the conversations")
    check("cat has none", s["sessions"][0]["conversation"] == "", summary(s))
    deadline = time.time() + 3
    while time.time() < deadline:
        saved = {x["command"]: x.get("conversation") for x in saved_sessions()}
        if all(saved.get(p) == IDS[n] for n, p in FAKES.items()):
            break
        time.sleep(0.1)
    check("saved", all(saved.get(p) == IDS[n] for n, p in FAKES.items()), str(saved))
    check("cat saved without one", saved.get("cat") is None, str(saved))


@test
def codex_gets_the_conversation_hook():
    """Codex's hooks file (in the test's CODEX_HOME) gains the conversation entry next to the status ones"""
    with open(os.path.join(CODEX_HOME, "hooks.json")) as f:
        hooks = json.load(f)["hooks"]
    prompt = [h["command"] for entry in hooks["UserPromptSubmit"] for h in entry["hooks"]]
    check("status entry", any("printf %s working" in c for c in prompt), str(prompt))
    check("conversation entry", any("POPPY_STATUS_FILE.conversation" in c for c in prompt), str(prompt))
    plugin = os.path.join(XDG, "opencode", "plugins", "poppy-status.ts")
    check("opencode plugin records it", '".conversation"' in open(plugin).read(), plugin)


@test
def relaunch_resumes_each_conversation():
    """after quitting and reopening, each session's agent resumes its conversation"""
    before = {n: len(args_lines(n)) for n in FAKES}
    stop()
    s = launch()
    lines = {n: wait_args(n, before[n] + 1)[-1] for n in FAKES}
    check("claude --resume", f"--resume {IDS['claude']}" in lines["claude"], lines["claude"])
    check("claude keeps its hooks", "--settings" in lines["claude"], lines["claude"])
    check("codex resume, daemon off first", lines["codex"].startswith(f"--no-daemon resume {IDS['codex']}"), lines["codex"])
    check("opencode --session", lines["opencode"] == f"--session {IDS['opencode']}", lines["opencode"])
    s = state()
    for name, path in FAKES.items():
        check(f"{name} still has it", s["sessions"][index_of(path)]["conversation"] == IDS[name], summary(s))
    check("same sessions", [x["command"] for x in s["sessions"]] == ["cat"] + list(FAKES.values()), summary(s))


@test
def a_new_conversation_replaces_the_saved_one():
    """a new id (e.g. after /clear) replaces the saved one"""
    path = FAKES["claude"]
    record_conversation(index_of(path), "33333333-aaaa-4bbb-8ccc-000000000003")
    wait_for(lambda s: s["sessions"][index_of(path)]["conversation"].startswith("3333"), "the new id")
    time.sleep(0.3)
    saved = {x["command"]: x.get("conversation") for x in saved_sessions()}
    check("saved", saved[path] == "33333333-aaaa-4bbb-8ccc-000000000003", str(saved))
    IDS["claude"] = saved[path]


@test
def restart_starts_a_new_conversation():
    """Restart Agent starts fresh (no resume) and forgets the saved conversation"""
    path = FAKES["claude"]
    count = len(args_lines("claude"))
    cmd("restart", index=index_of(path))
    line = wait_args("claude", count + 1)[-1]
    check("no resume", "--resume" not in line, line)
    s = wait_for(lambda s: s["sessions"][index_of(path)]["conversation"] == "", "the id to clear")
    time.sleep(0.3)
    saved = {x["command"]: x.get("conversation") for x in saved_sessions()}
    check("not saved", saved[path] is None, str(saved))
    check("others kept", saved[FAKES["codex"]] == IDS["codex"], str(saved))


@test
def unsafe_ids_are_never_resumed():
    """a recorded id with shell characters is ignored at the next launch (fresh start)"""
    path = FAKES["opencode"]
    record_conversation(index_of(path), "x; touch " + os.path.join(TMP, "pwned"))
    wait_for(lambda s: s["sessions"][index_of(path)]["conversation"].startswith("x; "), "the odd id")
    time.sleep(0.3)
    count = len(args_lines("opencode"))
    stop()
    launch()
    line = wait_args("opencode", count + 1)[-1]
    check("fresh start", line == "", repr(line))
    check("nothing ran", not os.path.exists(os.path.join(TMP, "pwned")))


@test
def closing_sessions_back_to_one():
    """(cleanup) the fake agents' sessions close"""
    for path in FAKES.values():
        cmd("close", index=index_of(path))
        if state()["confirm"]:
            cmd("confirm", value=True)
    s = wait_for(lambda s: len(s["sessions"]) == 1, "one session")
    check("cat left", s["sessions"][0]["command"] == "cat", summary(s))


# --- Fold when you send a prompt (DESIGN §7.15) -----------------------------------------

@test
def fold_on_prompt_off_stays_open():
    """with the setting off, a prompt leaves the panel open"""
    focus_expanded()
    report(0, "working")
    wait_for(lambda s: s["sessions"][0]["status"] == "working", "working")
    s = settle(0.3)
    check("still open", s["state"] == "expanded", summary(s))


@test
def fold_on_prompt_folds():
    """on: sending a prompt in the focused panel folds it to the pill"""
    cmd("autoOpen", key="foldOnPrompt", value=True)
    check("saved", saved_config().get("foldOnPrompt") is True, str(saved_config().get("foldOnPrompt")))
    focus_expanded()
    offset = log_size()
    report(0, "working")
    s = wait_for(lambda s: s["state"] == "collapsed", "the fold")
    s = settle()
    check("collapsed, keyboard given back", s["state"] == "collapsed" and not s["key"], summary(s))
    check("logged", "auto-open: folding, the agent is working" in log_since(offset))


@test
def fold_on_prompt_after_answering():
    """on: answering a permission prompt (waiting -> working) in the panel folds it"""
    cmd("autoOpen", key="foldOnPrompt", value=True)
    report(0, "waiting")
    wait_for(lambda s: s["sessions"][0]["status"] == "waiting", "waiting")
    focus_expanded()
    report(0, "working")
    wait_for(lambda s: s["state"] == "collapsed", "the fold")


@test
def fold_on_prompt_once_per_turn():
    """on: opening the panel while the agent already works doesn't fold it again on the next tool call"""
    cmd("autoOpen", key="foldOnPrompt", value=True)
    report(0, "working")
    wait_for(lambda s: s["sessions"][0]["status"] == "working", "working")
    focus_expanded()
    time.sleep(0.3)
    report(0, "working")  # another hook, same status
    s = settle(0.5)
    check("still open", s["state"] == "expanded", summary(s))


@test
def fold_on_prompt_not_when_unfocused():
    """on: a panel you've left (not key) doesn't fold"""
    cmd("autoOpen", key="foldOnPrompt", value=True)
    focus_expanded()
    cmd("blur")
    wait_for(lambda s: not s["key"], "the panel to lose the keyboard")
    report(0, "working")
    wait_for(lambda s: s["sessions"][0]["status"] == "working", "working")
    s = settle(0.3)
    check("still open", s["state"] == "expanded", summary(s))
    cmd("focus")


@test
def fold_on_prompt_not_when_pinned():
    """on: a pinned panel stays open"""
    cmd("autoOpen", key="foldOnPrompt", value=True)
    focus_expanded()
    cmd("pin")
    report(0, "working")
    wait_for(lambda s: s["sessions"][0]["status"] == "working", "working")
    s = settle(0.3)
    check("still open", s["state"] == "expanded" and s["pinned"], summary(s))


@test
def fold_on_prompt_not_under_settings():
    """on: the settings page stays open"""
    cmd("autoOpen", key="foldOnPrompt", value=True)
    focus_expanded()
    cmd("settings", value=True)
    s = settle()
    check("settings shown", s["settings"], summary(s))
    report(0, "working")
    wait_for(lambda s: s["sessions"][0]["status"] == "working", "working")
    s = settle(0.3)
    check("still open", s["state"] == "expanded" and s["settings"], summary(s))


@test
def fold_on_prompt_ignores_background_sessions():
    """on: another session starting work doesn't fold the panel you're typing in"""
    cmd("new", command="cat", directory=B)
    s = settle()
    cmd("autoOpen", key="foldOnPrompt", value=True)
    focus_expanded(0)
    report(1, "working")
    wait_for(lambda s: s["sessions"][1]["status"] == "working", "working")
    s = settle(0.3)
    check("still open", s["state"] == "expanded" and s["selected"] == 0, summary(s))
    report(1, "idle")
    wait_for(lambda s: s["sessions"][1]["status"] == "idle", "idle")  # else closing asks first
    cmd("close", index=1)
    wait_for(lambda s: len(s["sessions"]) == 1, "one session")


@test
def fold_on_prompt_needs_agent_status():
    """the switch is saved off again, and turning it off stops folding"""
    cmd("autoOpen", key="foldOnPrompt", value=True)
    cmd("autoOpen", key="foldOnPrompt", value=False)
    check("saved off", saved_config().get("foldOnPrompt") is False)
    focus_expanded()
    report(0, "working")
    wait_for(lambda s: s["sessions"][0]["status"] == "working", "working")
    s = settle(0.3)
    check("still open", s["state"] == "expanded", summary(s))


# --- Panel settings (DESIGN §6.3, §7.20, §7.21) -----------------------------------------

@test
def fold_when_clicking_outside_setting():
    """Fold when clicking outside: off removes the click-outside watch, on brings it back; saved"""
    s = focus_expanded()
    check("watching", s["clickOutsideMonitor"], summary(s))
    s = cmd("setting", key="foldOnClickOutside", value=False)
    check("not watching", not s["clickOutsideMonitor"], summary(s))
    check("saved off", saved_config().get("foldOnClickOutside") is False)
    s = cmd("setting", key="foldOnClickOutside", value=True)
    check("watching again", s["clickOutsideMonitor"], summary(s))
    check("saved on", saved_config().get("foldOnClickOutside") is True)


@test
def the_pin_keeps_it_open():
    """the pin stops click-outside folding, is saved per pill, and lasts across a fold"""
    focus_expanded()
    s = cmd("pin")
    check("pinned, not watching", s["pinned"] and not s["clickOutsideMonitor"], summary(s))
    time.sleep(0.3)
    with open(STATE) as f:
        check("saved", json.load(f)["pills"][0].get("pinned") is True)
    cmd("collapse")
    settle()
    s = focus_expanded()
    check("still pinned", s["pinned"] and not s["clickOutsideMonitor"], summary(s))
    s = cmd("pin")
    check("unpinned, watching", not s["pinned"] and s["clickOutsideMonitor"], summary(s))
    time.sleep(0.3)
    with open(STATE) as f:
        check("not saved", "pinned" not in json.load(f)["pills"][0])


@test
def hide_the_pill():
    """Hide pill when collapsed: hidden while collapsed, shown while open, back when turned off"""
    s = cmd("setting", key="hidePill", value=True)
    check("hidden", s["pillHidden"] and not s["visible"], summary(s))
    cmd("expand", value=True)
    s = settle()
    check("shown open", s["visible"] and s["state"] == "expanded", summary(s))
    cmd("collapse")
    s = settle(0.5)
    check("hidden again", s["pillHidden"] and not s["visible"], summary(s))
    s = cmd("setting", key="hidePill", value=False)
    check("shown", not s["pillHidden"] and s["visible"], summary(s))
    check("saved", saved_config().get("hidePill") is False)


@test
def fade_when_not_focused():
    """Fade when not focused: the open panel fades to the set opacity when it loses the keyboard"""
    cmd("setting", key="inactiveOpacity", width=0.4)
    cmd("setting", key="fadeWhenInactive", value=True)
    try:
        s = focus_expanded()
        check("full while focused", s["fade"] == 1, summary(s))
        cmd("blur")
        s = wait_for(lambda s: abs(s["fade"] - 0.4) < 0.01, "the fade (is the mouse over the panel?)")
        cmd("focus")
        wait_for(lambda s: s["fade"] == 1, "full opacity again")
        cmd("blur")
        wait_for(lambda s: abs(s["fade"] - 0.4) < 0.01, "the fade")
        cmd("collapse")
        s = settle()
        check("the pill never fades", s["fade"] == 1, summary(s))
    finally:
        cmd("setting", key="fadeWhenInactive", value=False)
        cmd("focus") if state()["state"] == "expanded" else None


@test
def numbers_are_clamped_and_saved():
    """numeric settings are clamped to their range and saved"""
    cmd("setting", key="inactiveOpacity", width=5)
    check("opacity max", saved_config().get("inactiveOpacity") == 0.9, str(saved_config().get("inactiveOpacity")))
    cmd("setting", key="inactiveOpacity", width=0)
    check("opacity min", saved_config().get("inactiveOpacity") == 0.2, str(saved_config().get("inactiveOpacity")))
    cmd("setting", key="terminalOpacity", width=0.05)
    check("terminal opacity min", saved_config().get("terminalOpacity") == 0.3, str(saved_config().get("terminalOpacity")))
    cmd("setting", key="terminalFontSize", width=99)
    check("font size max", saved_config().get("terminalFontSize") == 24, str(saved_config().get("terminalFontSize")))
    cmd("setting", key="terminalFontSize", width=13)
    cmd("setting", key="terminalOpacity", width=0.8)
    cmd("setting", key="inactiveOpacity", width=0.5)


@test
def switches_are_saved():
    """Copy on select and Confirm before quitting are saved"""
    for key in ("copyOnSelect", "confirmQuit"):
        before = saved_config().get(key)
        cmd("setting", key=key, value=True)
        check(f"{key} on", saved_config().get(key) is True)
        cmd("setting", key=key, value=False)
        check(f"{key} off", saved_config().get(key) is False)
        cmd("setting", key=key, value=before if before is not None else key == "confirmQuit")


# --- Send Selection (DESIGN §9.17) -----------------------------------------------------

@test
def send_selection_pastes_into_the_recent_session():
    """Send Selection pastes into the recent pill's session and opens it, not into a waiting agent"""
    settle()
    cmd("actSend", command="sent from another app")
    s = wait_for(lambda s: s["state"] == "expanded" and s["key"], "the panel to open")
    wait_for(lambda s: "sent from another app" in s["sessions"][0]["screen"], "the pasted text")
    cmd("type", index=0)  # Return: cat echoes it, the line is done
    cmd("collapse")
    settle()
    report(0, "waiting")
    wait_for(lambda s: s["sessions"][0]["status"] == "waiting", "waiting")
    cmd("actSend", command="not for a question")
    s = wait_for(lambda s: s["state"] == "expanded", "the panel to open")
    time.sleep(0.3)
    check("not pasted", "not for a question" not in state()["sessions"][0]["screen"], summary(s))


# --- intro (DESIGN §9.15) ---------------------------------------------------------------

@test
def intro_pages_and_skip():
    """the intro shows each page in the panel, never folds on a click outside, and Skip ends it"""
    focus_expanded()
    for page in ("welcome", "agent", "hotkeys", "permissions", "finish"):
        s = cmd("intro", key=page)
        check(f"page {page}", s["intro"] == page, summary(s))
        check("no click-outside fold", not s["clickOutsideMonitor"], summary(s))
    s = cmd("intro", value=False)
    check("ended", s["intro"] == "" and not s["settings"], summary(s))
    check("watching again", s["clickOutsideMonitor"], summary(s))
    check("introShown saved", saved_config().get("introShown") is True)


# --- teardown: Poppy Dev as it was ------------------------------------------------------

stop()
for path, text in ((CONFIG, original_config), (STATE, original_state)):
    if text is None:
        os.path.exists(path) and os.remove(path)
    else:
        with open(path, "w") as f:
            f.write(text)
if was_running:
    launch(isolated=False)
print(f"\n{len(passed)} passed, {len(failed)} failed")
for name, error in failed:
    print(f"  FAIL  {name}: {error}")
sys.exit(1 if failed else 0)
