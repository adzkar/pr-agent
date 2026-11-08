#!/usr/bin/env python3
"""PTY driver for `pr-agent status -w` — spawns the tool on a real pty and
exercises the interactive viewport: key navigation, bounds, resize, small
terminal, NO_COLOR, terminal lifecycle restoration, and the instrumented
"navigation never gathers" bound. Usage: status_pty.py REPO STATE_DIR GH_BIN

Prints one `ok`/`FAIL` line per assertion; exit status is 1 on any failure."""
import json
import os
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import fcntl
import time

REPO, STATE, GHBIN = sys.argv[1:4]
GHLOG = os.path.join(STATE, "gh.log")
TOOL = os.path.join(REPO, "pr-agent")
OKC = 0
FAILC = 0


def ok(name):
    global OKC
    OKC += 1
    print("ok   %s" % name)


def bad(name, why):
    global FAILC
    FAILC += 1
    print("FAIL %s — %s" % (name, why))


class Pty:
    """One pty pair; spawn() runs a child on it with a controlling terminal."""

    def __init__(self, rows=24, cols=80):
        self.master, self.slave = pty.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ,
                    struct.pack("HHHH", rows, cols, 0, 0))
        self.buf = b""

    def spawn(self, cmd, env, ctty=True):
        slave = self.slave
        pid = os.fork()
        if pid == 0:
            if ctty:
                os.setsid()
                fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
            os.dup2(slave, 0)
            os.dup2(slave, 1)
            os.dup2(slave, 2)
            os.execvpe("/bin/bash", ["bash", "-c", cmd], env)
        return pid

    def resize(self, rows, cols):
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ,
                    struct.pack("HHHH", rows, cols, 0, 0))

    def pump(self, secs):
        end = time.time() + secs
        while time.time() < end:
            r, _, _ = select.select([self.master], [], [], 0.1)
            if r:
                try:
                    self.buf += os.read(self.master, 65536)
                except OSError:
                    break

    def pump_until(self, pat, secs):
        end = time.time() + secs
        while time.time() < end:
            if pat in self.buf:
                return True
            self.pump(0.2)
        return pat in self.buf

    def send(self, data):
        os.write(self.master, data)

    def wait(self, pid, secs):
        end = time.time() + secs
        while time.time() < end:
            w, s = os.waitpid(pid, os.WNOHANG)
            if w:
                if os.WIFEXITED(s):
                    return os.WEXITSTATUS(s)
                return -os.WTERMSIG(s)
            self.pump(0.2)
        return None

    def paints(self):
        return self.buf.count(b"\x1b[H")

    def last_frame(self):
        parts = self.buf.split(b"\x1b[H")
        return parts[-1] if len(parts) > 1 else self.buf

    def frame_lines(self):
        """Physical lines of the last painted frame, ANSI stripped."""
        frame = self.last_frame()
        frame = re.sub(rb"\x1b\[[0-9;?]*[a-zA-Z]", b"", frame)
        frame = re.sub(rb"\x1b[()][0-9AB]", b"", frame)
        return frame.replace(b"\r", b"").split(b"\n")

    def close(self):
        try:
            os.close(self.master)
            os.close(self.slave)
        except OSError:
            pass


def env(extra=None):
    e = dict(os.environ)
    e["PATH"] = os.path.dirname(GHBIN) + ":" + e["PATH"]
    e["PR_AGENT_STATE_DIR"] = STATE
    e["PR_AGENT_REPO"] = "test/pty"
    e["PR_AGENT_UPDATE_CHECK"] = "0"
    e["TERM"] = "xterm-256color"
    e.pop("NO_COLOR", None)
    e.pop("COLUMNS", None)          # stale exports must not poison winsize
    e.pop("LINES", None)
    e.pop("TMPDIR", None)           # ambient TMPDIR would route stub-mktemps
    if extra:                       # outside MKTEMP_STUB_DIR, vacating the
        e.update(extra)             # leak asserts
    return e


def gh_calls():
    try:
        return open(GHLOG).read().count("\n")
    except OSError:
        return 0


def stub_leftovers(d):
    """Files the mktemp stub left behind in dir d (leaks); [] = clean."""
    try:
        return os.listdir(d)
    except OSError:
        return []


def alive_pid(s):
    """pid string -> still running (EPERM counts as alive, zombies get reaped
    by launchd quickly so an orphan can't masquerade as dead)."""
    try:
        os.kill(int(s), 0)
        return True
    except PermissionError:
        return True
    except (ProcessLookupError, ValueError):
        return False


def finish(p, pid, secs=15):
    """Wait for the child to exit after quit/EOF was sent. If it is still
    alive past the budget — e.g. a slow gather+rebuild+paint cycle was
    in-flight when the key landed — SIGTERM it so cleanup asserts never
    read a live snap and the child can't leak into the next scenario."""
    rc = p.wait(pid, secs)
    if rc is None:
        try:
            os.killpg(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass                    # child exited in the WNOHANG→kill gap
        p.wait(pid, 5)
    return rc


def refresh_caches():
    """Keep the seeded ttl caches fresh so status_gather stays cheap."""
    d = os.path.join(STATE, "repos", "test__pty")
    for f in ("prs.jsonl", "status_pending"):
        try:
            os.utime(os.path.join(d, f))
        except OSError:
            pass


def cell_w(bs):
    """Display cells: box-drawing/dingbats are 1, CJK wide is 2 (enough for this
    test's frames — full wcwidth lives in cell_ops)."""
    w = 0
    for ch in bs.decode("utf-8", "replace"):
        w += 2 if "⺀" <= ch <= "�" else 1
    return w


def bounded(lines, rows, cols):
    """Every emitted line fits cols cells and there are at most rows of them."""
    if len(lines) > rows:
        return "lines=%d > rows=%d" % (len(lines), rows)
    for l in lines:
        w = cell_w(l)
        if w > cols:
            return "line %d cells > %d cols: %r" % (w, cols, l[:40])
    return None


def norm_lflag(s):
    """stty -g lflag masked over kernel-transient PENDIN/NOFLSH bits."""
    try:
        f = dict(x.split("=", 1) for x in s.split(":")[1:])
        return int(f["lflag"], 16) & ~0xA0000000
    except (IndexError, KeyError, ValueError):
        return -1


# --- scenario 1: interactive lifecycle + navigation ---------------------------
def s_nav():
    p = Pty(24, 80)
    wtmp = os.path.join(STATE, "wtmp-nav")
    os.makedirs(wtmp)           # stub_leftovers([]) must mean empty, not absent
    pid = p.spawn('trap ":" INT; stty -g >"%s/tty.before"; "%s" status -w 60; '
                  'echo "rc=$?" >"%s/watch.rc"; stty -g >"%s/tty.after"'
                  % (STATE, TOOL, STATE, STATE), env({"MKTEMP_STUB_DIR": wtmp}))
    refresh_caches()
    # the async pipeline paints a loading frame immediately and the real table
    # only after the first worker lands — wait for records, then assert the
    # loading frame really did precede them in the byte stream
    if not p.pump_until(b"#20", 25):
        bad("records paint", "no data frame in 25s, %d bytes" % len(p.buf))
        p.close()
        return
    p.pump(1.0)
    ok("alt-screen entered") if b"\x1b[?1049h" in p.buf else bad("alt-screen entered", "no smcup")
    ok("cursor hidden") if b"\x1b[?25l" in p.buf else bad("cursor hidden", "no civis")
    li = p.buf.find(b"gathering status"); ri = p.buf.find(b"#20")
    ok("loading frame precedes records") if 0 <= li < ri else \
        bad("loading frame precedes records", "gathering=%d records=%d" % (li, ri))
    f0 = bytes(p.last_frame())
    ok("first paint renders records") if b"#20" in f0 else bad("first paint renders records", "no #20x record")
    b = bounded(p.frame_lines(), 24, 80)
    ok("frame bounded 80x24") if b is None else bad("frame bounded 80x24", b)

    g0 = gh_calls()
    n0 = p.paints()
    p.send(b"G"); p.pump(1.5)
    f_G = bytes(p.last_frame())
    ok("G repaints to bottom") if p.paints() > n0 and f_G != f0 else \
        bad("G repaints to bottom", "paints=%d" % p.paints())
    p.send(b"k"); p.pump(1.2)
    f_k = bytes(p.last_frame())
    ok("k scrolls back up") if f_k != f_G else bad("k scrolls back up", "frame unchanged")
    p.send(b"g"); p.pump(1.2)
    f_g = bytes(p.last_frame())
    ok("g back to top") if f_g == f0 else bad("g back to top", "differs from first frame")
    p.send(b"l"); p.pump(1.2)
    f_l = bytes(p.last_frame())
    ok("l scrolls right") if f_l != f_g else bad("l scrolls right", "unchanged")
    p.send(b"$"); p.pump(1.2)
    f_d = bytes(p.last_frame())
    ok("$ reaches hmax") if f_d != f_l else bad("$ reaches hmax", "unchanged")
    p.send(b"l"); p.pump(1.2)
    ok("bound: extra l at max is a no-op") if bytes(p.last_frame()) == f_d else \
        bad("bound: extra l at max", "frame changed")
    p.send(b"0"); p.pump(1.2)
    ok("0 resets hoff") if bytes(p.last_frame()) == f_g else \
        bad("0 resets hoff", "differs from hoff=0 frame")
    ok("navigation made no gh calls") if gh_calls() == g0 else \
        bad("navigation made no gh calls", "+%d calls" % (gh_calls() - g0))
    p.send(b"q")
    rc = p.wait(pid, 6)
    p.pump(0.5)
    ok("q exits rc 0") if rc == 0 else bad("q exits rc 0", "rc=%r" % rc)
    ok("alt-screen left") if b"\x1b[?1049l" in p.buf else bad("alt-screen left", "no rmcup")
    ok("cursor restored") if b"\x1b[?25h" in p.buf else bad("cursor restored", "no cnorm")
    try:
        before = open(os.path.join(STATE, "tty.before")).read().strip()
        after = open(os.path.join(STATE, "tty.after")).read().strip()
        ok("termios restored") if norm_lflag(before) == norm_lflag(after) and norm_lflag(after) != -1 \
            else bad("termios restored", "lflag %s vs %s" % (norm_lflag(before), norm_lflag(after)))
    except OSError as e:
        bad("termios restored", str(e))
    left = stub_leftovers(wtmp)
    ok("q leaves no tempfiles") if not left else bad("q leaves no tempfiles", left)
    p.close()


def _restore_check(p, name):
    try:
        before = open(os.path.join(STATE, "tty.before")).read().strip()
        after = open(os.path.join(STATE, "tty.after")).read().strip()
        ok(name) if norm_lflag(before) == norm_lflag(after) and norm_lflag(after) != -1 \
            else bad(name, "%s vs %s" % (norm_lflag(before), norm_lflag(after)))
    except OSError as e:
        bad(name, str(e))


# --- scenario 2: SIGINT restores ----------------------------------------------
def s_sigint():
    p = Pty(24, 80)
    wtmp = os.path.join(STATE, "wtmp-sigint")
    os.makedirs(wtmp)
    pid = p.spawn('trap ":" INT; stty -g >"%s/tty.before"; "%s" status -w 60; '
                  'echo "rc=$?" >"%s/watch.rc"; stty -g >"%s/tty.after"'
                  % (STATE, TOOL, STATE, STATE), env({"MKTEMP_STUB_DIR": wtmp}))
    refresh_caches()
    if not p.pump_until(b"#20", 25):
        bad("sigint first paint", "no data frame")
        p.close()
        return
    os.killpg(pid, signal.SIGINT)   # foreground process group, like a real ^C
    rc = p.wait(pid, 6)
    p.pump(0.5)
    ok("SIGINT exits") if rc is not None else bad("SIGINT exits", "still running")
    ok("SIGINT leaves alt-screen") if b"\x1b[?1049l" in p.buf else bad("SIGINT leaves alt-screen", "no rmcup")
    ok("SIGINT shows cursor") if b"\x1b[?25h" in p.buf else bad("SIGINT shows cursor", "no cnorm")
    _restore_check(p, "SIGINT restores termios")
    left = stub_leftovers(wtmp)
    ok("SIGINT leaves no tempfiles") if not left else \
        bad("SIGINT leaves no tempfiles", left)
    p.close()


# --- scenario 3: resize rebuilds at new geometry --------------------------------
def s_resize():
    p = Pty(24, 80)
    pid = p.spawn('"%s" status -w 60' % TOOL, env())
    refresh_caches()
    if not p.pump_until(b"#20", 25):
        bad("resize initial paint", "no data frame")
        p.close()
        return
    n0 = p.paints()
    g0 = gh_calls()
    p.resize(16, 50)
    os.killpg(pid, signal.SIGWINCH)
    p.pump(6)
    ok("resize repaints") if p.paints() > n0 else bad("resize repaints", "paints=%d" % p.paints())
    b = bounded(p.frame_lines(), 16, 50)
    ok("resized frame bounded 50x16") if b is None else bad("resized frame bounded 50x16", b)
    n1 = p.paints()
    p.resize(24, 100)
    os.killpg(pid, signal.SIGWINCH)
    p.pump(6)
    ok("grow repaints") if p.paints() > n1 else bad("grow repaints", "paints=%d" % p.paints())
    b = bounded(p.frame_lines(), 24, 100)
    ok("grown frame bounded 100x24") if b is None else bad("grown frame bounded 100x24", b)
    ok("resize made no gh calls") if gh_calls() == g0 else \
        bad("resize made no gh calls", "+%d" % (gh_calls() - g0))
    p.send(b"q")
    p.wait(pid, 6)
    p.close()


# --- scenario 4: too-small terminal -> compact safe state -----------------------
def s_small():
    p = Pty(24, 20)
    pid = p.spawn('exec "%s" status -w 60' % TOOL, env())
    refresh_caches()
    if p.pump_until(b"\x1b[H", 25):
        p.pump(0.5)
    ok("compact safe state at 20 cols") if b"terminal too small" in p.buf else \
        bad("compact safe state at 20 cols", "not in %d bytes" % len(p.buf))
    p.send(b"q")
    rc = p.wait(pid, 6)
    ok("compact exits on q") if rc == 0 else bad("compact exits on q", "rc=%r" % rc)
    p.close()


# --- scenario 5: NO_COLOR keeps navigation --------------------------------------
def s_nocolor():
    p = Pty(24, 80)
    pid = p.spawn('exec "%s" status -w 60' % TOOL, env({"NO_COLOR": "1"}))
    refresh_caches()
    if not p.pump_until(b"\x1b[H", 25):
        bad("nocolor first paint", "no frame")
        p.close()
        return
    frame = p.last_frame()
    ok("NO_COLOR strips color codes") if not re.search(rb"\x1b\[[0-9;]*[34][0-9]m", frame) else \
        bad("NO_COLOR strips color codes", "color SGR in frame")
    n0 = p.paints()
    p.send(b"j")
    p.pump(1.5)
    ok("NO_COLOR still navigates") if p.paints() > n0 else bad("NO_COLOR still navigates", "no repaint")
    p.send(b"q")
    p.wait(pid, 6)
    p.close()


# --- scenario 6: partial/garbage keys don't break the loop -----------------------
def s_garbage():
    p = Pty(24, 80)
    pid = p.spawn('exec "%s" status -w 60' % TOOL, env())
    refresh_caches()
    if not p.pump_until(b"\x1b[H", 25):
        bad("garbage first paint", "no frame")
        p.close()
        return
    n0 = p.paints()
    p.send(b"\x1b[9~")           # unknown CSI terminator
    p.send(b"\x1b[3;")           # partial sequence, abandoned mid-params
    p.send(b"zz")                # unknown plain keys
    p.pump(1.5)
    alive = os.waitpid(pid, os.WNOHANG)[0] == 0
    ok("garbage input keeps loop alive") if alive else bad("garbage input keeps loop alive", "process died")
    p.send(b"j")
    p.pump(1.5)
    ok("nav still works after garbage") if p.paints() > n0 else bad("nav still works after garbage", "no repaint")
    p.send(b"\x1b")              # lone ESC — next key must survive it
    p.pump(0.3)
    p.send(b"q")
    rc = p.wait(pid, 6)
    ok("ESC then q quits") if rc == 0 else bad("ESC then q quits", "rc=%r" % rc)
    p.close()


# --- scenario 7: garbage -w intervals normalize instead of dying/hot-looping ---
def s_badinterval():
    """status -w abc/.5/008: non-numeric input must not die under set -u inside
    the alt screen, and empty must not hot re-gather on every input tick."""
    for arg, want in (("abc", b"refresh 5s"), (".5", b"refresh 5s"), ("008", b"refresh 8s")):
        wtmp = os.path.join(STATE, "wtmp-i" + arg.replace(".", "d"))
        os.makedirs(wtmp)
        p = Pty(24, 80)
        pid = p.spawn('exec "%s" status -w %s' % (TOOL, arg),
                      env({"MKTEMP_STUB_DIR": wtmp}))
        refresh_caches()
        if not p.pump_until(b"\x1b[H", 25):
            bad("interval %s first paint" % arg, "no frame — died in alt screen")
            p.close()
            continue
        f0 = bytes(p.last_frame())
        ok("interval %s footer %s" % (arg, want.decode())) if want in f0 else \
            bad("interval %s footer" % arg, "%r not in frame" % want)
        n0 = p.paints()
        p.pump(3.0)
        # async refresh legitimately repaints on worker events (spawn/adopt —
        # up to ~2 per cycle); a garbage interval hot-loop paints ~30x more
        ok("interval %s no hot re-gather" % arg) if p.paints() - n0 <= 4 else \
            bad("interval %s no hot re-gather" % arg,
                "+%d paints in 3s" % (p.paints() - n0))
        p.send(b"q")
        rc = finish(p, pid)
        ok("interval %s q exits 0" % arg) if rc == 0 else \
            bad("interval %s q exits 0" % arg, "rc=%r" % rc)
        p.pump(0.5)
        left = stub_leftovers(wtmp)
        ok("interval %s no tempfile leak" % arg) if not left else \
            bad("interval %s no tempfile leak" % arg, left)
        p.close()


# --- scenario 8: ten multiline records stay reachable through the body ---------
def s_ten_records():
    """The seed carries 10 wrap-length titles (one CJK): G must reach the
    oldest record's rows through the vertical body and g must return to #209."""
    p = Pty(24, 80)
    pid = p.spawn('exec "%s" status -w 60' % TOOL, env())
    refresh_caches()
    # records order most-recent-first: #209 tops the table, #200 closes it
    if not p.pump_until(b"#209", 35):
        bad("ten records first paint", "no data frame")
        p.close()
        return
    p.send(b"G"); p.pump(1.5)
    ok("ten records: last reachable") if b"#200" in p.last_frame() else \
        bad("ten records: last reachable", "#200 not in bottom frame")
    b = bounded(p.frame_lines(), 24, 80)
    ok("ten records: bottom frame bounded") if b is None else \
        bad("ten records: bottom frame bounded", b)
    p.send(b"g"); p.pump(1.5)
    ok("ten records: first back on top") if b"#209" in p.last_frame() else \
        bad("ten records: first back on top", "#209 lost")
    p.send(b"q")
    p.wait(pid, 6)
    p.close()


# --- scenario 9: legacy saved caps hold under -w --------------------------------
def s_saved_caps():
    """A config written by an older install (CFG_TABLE_ROWS/CFG_TITLE_LINES —
    no header, no markers) is saved provenance: -w shows the cap row and
    truncates titles to one line instead of applying the uncapped mode
    default. Removed afterwards so later scenarios see the default again."""
    cfg = os.path.join(STATE, "repos", "test__pty", "config")
    open(cfg, "w").write("CFG_TABLE_ROWS=3\nCFG_TITLE_LINES=1\n")
    p = Pty(24, 80)
    pid = p.spawn('exec "%s" status -w 60' % TOOL, env())
    refresh_caches()
    if not p.pump_until(b"#20", 35):
        bad("saved caps first paint", "no data frame")
        p.close()
        try: os.remove(cfg)
        except OSError: pass
        return
    # wait for the cap row itself — '#20' fires on the first record byte, which
    # can be mid-paint, so a last_frame() snapshot can precede the row's write
    ok("saved caps: cap row") if p.pump_until(b"TABLE_ROWS=3", 8) else \
        bad("saved caps: cap row", "no cap row — saved TABLE_ROWS=3 not honored")
    frame = bytes(p.last_frame())
    ok("saved caps: titles truncated to one line") \
        if b"several lines of the body region" not in frame else \
        bad("saved caps: titles truncated", "wrapped title tail visible under TITLE_LINES=1")
    p.send(b"q")
    p.wait(pid, 6)
    try:
        os.remove(cfg)
    except OSError:
        pass
    p.close()


# --- scenario 10: SIGTERM restores like SIGINT ----------------------------------
def s_sigterm():
    p = Pty(24, 80)
    wtmp = os.path.join(STATE, "wtmp-term")
    os.makedirs(wtmp)
    pid = p.spawn('trap ":" INT; stty -g >"%s/tty.before"; "%s" status -w 60; '
                  'echo "rc=$?" >"%s/watch.rc"; stty -g >"%s/tty.after"'
                  % (STATE, TOOL, STATE, STATE), env({"MKTEMP_STUB_DIR": wtmp}))
    refresh_caches()
    if not p.pump_until(b"#20", 35):
        bad("sigterm first paint", "no data frame")
        p.close()
        return
    # TERM pr-agent itself, not the group: the wrapper bash shares the pgrp and
    # a group-TERM kills it mid-teardown — a harness artifact, not the watch's
    # restore path. (SIGINT above can killpg: the wrapper traps ":" INT anyway.)
    kid = subprocess.check_output(["pgrep", "-P", str(pid)]).split()
    os.kill(int(kid[0]), signal.SIGTERM)
    rc = p.wait(pid, 6)
    p.pump(0.5)
    ok("SIGTERM exits") if rc is not None else bad("SIGTERM exits", "still running")
    ok("SIGTERM leaves alt-screen") if b"\x1b[?1049l" in p.buf else \
        bad("SIGTERM leaves alt-screen", "no rmcup")
    ok("SIGTERM shows cursor") if b"\x1b[?25h" in p.buf else \
        bad("SIGTERM shows cursor", "no cnorm")
    _restore_check(p, "SIGTERM restores termios")
    left = stub_leftovers(wtmp)
    ok("SIGTERM leaves no tempfiles") if not left else \
        bad("SIGTERM leaves no tempfiles", left)
    p.close()


# --- scenario 11: input EOF (master closed) exits through cleanup ---------------
def s_eof():
    """Closing the pty master is the input-stream EOF case: the foreground
    pgrp gets SIGHUP — deferred like the other signals — and the watch must
    still exit through the cleanup path (no hang, no leaked tempfiles)."""
    wtmp = os.path.join(STATE, "wtmp-eof")
    os.makedirs(wtmp)
    p = Pty(24, 80)
    pid = p.spawn('exec "%s" status -w 60' % TOOL, env({"MKTEMP_STUB_DIR": wtmp}))
    refresh_caches()
    if not p.pump_until(b"#20", 25):
        bad("eof first paint", "no data frame")
        p.close()
        return
    p.close()                       # master gone -> SIGHUP to the fg pgrp
    rc = None                       # wait without pumping — master is closed
    end = time.time() + 8
    while time.time() < end:
        w, s = os.waitpid(pid, os.WNOHANG)
        if w:
            rc = os.WEXITSTATUS(s) if os.WIFEXITED(s) else -os.WTERMSIG(s)
            break
        time.sleep(0.2)
    ok("EOF exits the watch") if rc is not None else \
        bad("EOF exits the watch", "still running after 8s")
    left = stub_leftovers(wtmp)
    ok("EOF leaves no tempfiles") if not left else \
        bad("EOF leaves no tempfiles", left)


# --- scenario 12: missing terminal capabilities still render ---------------------
def s_term_dumb():
    """TERM=dumb: tput can't drive smcup/civis — the literal fallbacks must
    still paint records, keep the frame bounded at the real winsize, and let
    q exit through the same restore path."""
    e = env()
    e["TERM"] = "dumb"
    p = Pty(24, 80)
    pid = p.spawn('exec "%s" status -w 60' % TOOL, e)
    refresh_caches()
    ok("dumb term: records paint") if p.pump_until(b"#20", 25) else \
        bad("dumb term: records paint", "no data frame in 25s")
    b = bounded(p.frame_lines(), 24, 80)
    ok("dumb term: frame bounded") if b is None else \
        bad("dumb term: frame bounded", b)
    p.send(b"q")
    rc = p.wait(pid, 6)
    ok("dumb term: q exits") if rc == 0 else bad("dumb term: q exits", "rc=%r" % rc)
    p.close()


# --- scenario 13: persistent gather failure still honors q/EOF ------------------
def s_retry_quit():
    """Broken jq -> status_gather emits nothing and the watch retries; the
    retry loop must poll input so q still exits (sleep-only loops hung)."""
    wtmp = os.path.join(STATE, "wtmp-retry")
    os.makedirs(wtmp)
    badbin = os.path.join(STATE, "badbin")
    os.makedirs(badbin, exist_ok=True)
    jqpath = os.path.join(badbin, "jq")
    open(jqpath, "w").write("#!/usr/bin/env bash\nexit 1\n")
    os.chmod(jqpath, 0o755)
    e = env({"MKTEMP_STUB_DIR": wtmp})
    e["PATH"] = badbin + ":" + e["PATH"]
    p = Pty(24, 80)
    pid = p.spawn('exec "%s" status -w 60' % TOOL, e)
    p.pump(3.0)                 # a few gather retries; no snapshot ever lands
    p.send(b"q")
    rc = finish(p, pid)
    ok("q exits while gather fails") if rc == 0 else \
        bad("q exits while gather fails", "rc=%r" % rc)
    p.pump(0.5)
    ok("retry exit leaves alt-screen") if b"\x1b[?1049l" in p.buf else \
        bad("retry exit leaves alt-screen", "no rmcup")
    left = stub_leftovers(wtmp)
    ok("retry exit leaves no tempfile") if not left else \
        bad("retry exit leaves no tempfile", left)
    p.close()


# --- scenario 14: SIGINT mid-gather cleans worker + tempfiles -------------------
def s_sigint_mid_gather():
    """Signal while a gather worker is in flight: the loading frame may
    already be painted (that's the async design), but the gather's gh fan-out
    must still be running, and cancel must kill the worker subtree, rm the
    gather tempfiles under the private TMPDIR, and restore the terminal.
    Window: numeric targets fan fetch_feedback out to six PRs and the slow
    gh (0.4s/call) stretches the gather to ~8s; signal lands at ~2s."""
    wtmp = os.path.join(STATE, "wtmp-midg")
    os.makedirs(wtmp)
    d = os.path.join(STATE, "repos", "test__pty")
    # the gh stub replays this seed on `pr list` so refresh_prs repopulates;
    # numeric targets make status_prs fan fetch_feedback out per PR
    seed = os.path.join(STATE, "prs_seed.jsonl")
    with open(seed, "w") as f:
        for i in range(6):
            f.write(json.dumps({
                "number": 200 + i, "state": "OPEN", "title": "seed %d" % i,
                "review": "APPROVED", "draft": False, "updated": "u",
                "branch": "b", "head": "h", "base": "main",
                "mergeable": "MERGEABLE", "ci": "pass", "ci_failed": [],
                "author": "alice"}) + "\n")
    old_targets = open(os.path.join(d, "targets")).read()
    open(os.path.join(d, "targets"), "w").write("200 201 202 203 204 205\n")
    pids_file = os.path.join(STATE, "gh-midg.pids")
    open(pids_file, "w").close()
    slowbin = os.path.join(STATE, "slowbin")
    os.makedirs(slowbin, exist_ok=True)
    ghpath = os.path.join(slowbin, "gh")
    open(ghpath, "w").write(
        '#!/usr/bin/env bash\n[ -n "${GH_PIDFILE:-}" ] && echo "$$" >>"$GH_PIDFILE"\n'
        'sleep 0.4\nprintf "%%s\\n" "$*" >>"%s/gh.log"\n'
        'case "$*" in *"pr list"*) cat "%s/prs_seed.jsonl" ;; esac\nexit 0\n'
        % (STATE, STATE))
    os.chmod(ghpath, 0o755)
    e = env({"MKTEMP_STUB_DIR": wtmp, "GH_PIDFILE": pids_file})
    e["PATH"] = slowbin + ":" + e["PATH"]
    for f in ("prs.jsonl", "status_pending"):   # age out -> refresh_* run real
        try:                                    # gather work (mktemp + gh calls)
            os.utime(os.path.join(d, f), (0, 0))
        except OSError:
            pass
    p = Pty(24, 80)
    pid = p.spawn('exec "%s" status -w 60' % TOOL, e)
    p.pump(2.0)
    # loud precondition: the signal must land mid-gather — the worker's slow-gh
    # fan-out already logging calls and no data painted yet (the loading frame
    # is fine — it's the async design); otherwise this scenario degrades into
    # s_sigint and passes vacuously
    ok("signal lands mid-gather") \
        if gh_calls() > 0 and b"\xe2\x94\x82 #200" not in p.buf else \
        bad("signal lands mid-gather",
            "gh=%d records=%s — gather window missed" % (gh_calls(), b"\xe2\x94\x82 #200" in p.buf))
    os.killpg(pid, signal.SIGINT)
    rc = p.wait(pid, 10)
    ok("mid-gather SIGINT exits 0") if rc == 0 else \
        bad("mid-gather SIGINT exits 0", "rc=%r" % rc)
    p.pump(0.5)
    ok("mid-gather exit leaves alt-screen") if b"\x1b[?1049l" in p.buf else \
        bad("mid-gather exit leaves alt-screen", "no rmcup")
    left = stub_leftovers(wtmp)
    ok("mid-gather SIGINT leaves no tempfiles") if not left else \
        bad("mid-gather SIGINT leaves no tempfiles", left)
    live = [x for x in open(pids_file).read().split() if alive_pid(x)]
    ok("mid-gather SIGINT reaps worker subtree") if not live else \
        bad("mid-gather SIGINT reaps worker subtree", "orphans %r" % live)
    open(os.path.join(d, "targets"), "w").write(old_targets)
    p.close()


# --- scenario 15: a hung gather never blocks nav, resize, or quit --------------
def s_hung_gather():
    """GH_DELAY=25 execs a 25s sleep inside every gh call — the gather worker
    can never finish inside the window. The watch must still paint the
    loading frame, repaint on keys and resize, and exit fast on q — leaving
    no owned subprocesses and touching no foreign watcher/agent state."""
    wtmp = os.path.join(STATE, "wtmp-hung")
    os.makedirs(wtmp)
    pids_file = os.path.join(STATE, "gh-hung.pids")
    open(pids_file, "w").close()
    d = os.path.join(STATE, "repos", "test__pty")
    # foreign watcher/agent state the dashboard must leave untouched
    agent = subprocess.Popen(["sleep", "30"])     # stands in for a live agent
    open(os.path.join(d, "seen", "7"), "w").write("old\n")
    os.makedirs(os.path.join(d, "locks"), exist_ok=True)
    os.makedirs(os.path.join(d, "locks", "9"))
    os.makedirs(os.path.join(d, "running"), exist_ok=True)
    open(os.path.join(d, "running", "21"), "w").write("%d 1\n" % agent.pid)
    map_before = open(os.path.join(d, "map.json"), "rb").read()
    p = Pty(24, 80)
    pid = p.spawn('exec "%s" status -w 60' % TOOL,
                  env({"MKTEMP_STUB_DIR": wtmp,
                       "GH_DELAY": "25", "GH_PIDFILE": pids_file}))
    for f in ("prs.jsonl", "status_pending"):   # stale caches -> the gather
        try:                                    # reaches a gh call and hangs
            os.utime(os.path.join(d, f), (0, 0))
        except OSError:
            pass
    if not p.pump_until(b"gathering", 8):
        bad("hung gather: loading frame", "no loading paint in 8s")
        p.close(); agent.kill(); return
    ok("hung gather: loading shows no records") \
        if b"#20" not in p.last_frame() else \
        bad("hung gather: loading shows no records", "records in loading frame")
    n0 = p.paints()
    p.send(b"j"); p.pump(1.0)
    ok("hung gather: nav repaints") if p.paints() > n0 else \
        bad("hung gather: nav repaints", "no repaint")
    n1 = p.paints()
    p.resize(18, 60); os.killpg(pid, signal.SIGWINCH); p.pump(1.5)
    ok("hung gather: resize repaints") if p.paints() > n1 else \
        bad("hung gather: resize repaints", "no repaint")
    b = bounded(p.frame_lines(), 18, 60)
    ok("hung gather: resized frame bounded") if b is None else \
        bad("hung gather: resized frame bounded", b)
    p.send(b"q")
    rc = p.wait(pid, 6)
    ok("hung gather: q exits while worker out") if rc == 0 else \
        bad("hung gather: q exits while worker out", "rc=%r" % rc)
    time.sleep(0.4)
    live = [x for x in open(pids_file).read().split() if alive_pid(x)]
    ok("hung gather: no orphan subprocesses") if not live else \
        bad("hung gather: no orphan subprocesses", "orphans %r" % live)
    ok("hung gather: agent process untouched") if alive_pid(agent.pid) else \
        bad("hung gather: agent process untouched", "sleep agent killed")
    ok("hung gather: running marker untouched") \
        if open(os.path.join(d, "running", "21")).read() == ("%d 1\n" % agent.pid) else \
        bad("hung gather: running marker untouched", "marker changed/missing")
    ok("hung gather: seen marker untouched") \
        if open(os.path.join(d, "seen", "7")).read() == "old\n" else \
        bad("hung gather: seen marker untouched", "seen changed/missing")
    ok("hung gather: foreign lock untouched") \
        if os.path.isdir(os.path.join(d, "locks", "9")) else \
        bad("hung gather: foreign lock untouched", "locks/9 removed")
    ok("hung gather: map untouched") \
        if open(os.path.join(d, "map.json"), "rb").read() == map_before else \
        bad("hung gather: map untouched", "map.json changed")
    left = stub_leftovers(wtmp)
    ok("hung gather: no tempfile leaks") if not left else \
        bad("hung gather: no tempfile leaks", left)
    agent.kill()
    p.close()


# --- scenario 16: worker bound-out keeps the last good snapshot -----------------
def s_worker_bound():
    """First gather succeeds, then GH_SLOW_FILE flips gh to hang forever. The
    next worker must be killed at PR_AGENT_GATHER_TIMEOUT while the adopted
    snapshot stays on screen marked stale — then q still exits cleanly and
    the killed worker's gh children are all gone."""
    wtmp = os.path.join(STATE, "wtmp-bound")
    os.makedirs(wtmp)
    slowf = os.path.join(STATE, "gh_slow.flag")
    pids_file = os.path.join(STATE, "gh-bound.pids")
    open(pids_file, "w").close()
    d = os.path.join(STATE, "repos", "test__pty")
    p = Pty(24, 80)
    pid = p.spawn('exec "%s" status -w 4' % TOOL,
                  env({"MKTEMP_STUB_DIR": wtmp,
                       "PR_AGENT_GATHER_TIMEOUT": "8",
                       "GH_SLOW_FILE": slowf, "GH_SLOW_SECS": "30",
                       "GH_PIDFILE": pids_file}))
    refresh_caches()
    if not p.pump_until(b"#20", 15):
        bad("worker bound: initial data", "no records in 15s")
        p.close(); return
    ok("worker bound: initial data renders")
    # age the caches AND flip gh to hang — the next gather's first refresh
    # call sleeps 30s, so the bound must fire while the last snapshot holds
    for f in ("prs.jsonl", "status_pending"):
        try:
            os.utime(os.path.join(d, f), (0, 0))
        except OSError:
            pass
    open(slowf, "w").close()                    # gh now hangs on every call
    ok("worker bound: stale footer after bound-out") \
        if p.pump_until(b"refresh failed", 30) else \
        bad("worker bound: stale footer after bound-out", "never went stale")
    ok("worker bound: last snapshot retained") if b"#20" in p.last_frame() else \
        bad("worker bound: last snapshot retained", "records dropped")
    n0 = p.paints()
    p.send(b"j"); p.pump(1.0)
    ok("worker bound: nav still repaints") if p.paints() > n0 else \
        bad("worker bound: nav still repaints", "no repaint")
    p.send(b"q")
    rc = p.wait(pid, 6)
    ok("worker bound: q exits") if rc == 0 else \
        bad("worker bound: q exits", "rc=%r" % rc)
    time.sleep(0.4)
    live = [x for x in open(pids_file).read().split() if alive_pid(x)]
    ok("worker bound: killed worker left no orphans") if not live else \
        bad("worker bound: killed worker left no orphans", "orphans %r" % live)
    ok("worker bound: no leaked gather locks") \
        if not os.path.isdir(os.path.join(d, "map.lock")) \
           and not os.path.isdir(os.path.join(d, "prs.lock")) else \
        bad("worker bound: no leaked gather locks", "lock dir left behind")
    left = stub_leftovers(wtmp)
    ok("worker bound: no tempfile leaks") if not left else \
        bad("worker bound: no tempfile leaks", left)
    try:
        os.remove(slowf)
    except OSError:
        pass
    p.close()


# --- scenario 17: sustained key traffic must not reset the refresh deadline -----
def s_key_burst():
    """A constant key stream must not postpone next_gather — the deadline is
    absolute, so a refresh worker still spawns mid-burst (the ↻ refreshing
    footer is its signature). Fresh caches mean a completed gather may make
    zero gh calls and adoption may lag behind the burst, so the spawn itself
    is the right observable for 'deadline not postponed'."""
    wtmp = os.path.join(STATE, "wtmp-burst")
    os.makedirs(wtmp)

    p = Pty(24, 80)
    pid = p.spawn('exec "%s" status -w 3' % TOOL,
                  env({"MKTEMP_STUB_DIR": wtmp}))
    refresh_caches()
    if not p.pump_until(b"#20", 15):
        bad("key burst: initial data", "no records in 15s")
        p.close(); return
    # the deadline firing is observed as the ↻ refreshing footer appearing
    # while keys still stream — adoption may lag behind the burst, but the
    # worker must have spawned by interval's end
    saw_refresh = False
    end = time.time() + 6.0                      # > one 3s interval
    while time.time() < end and not saw_refresh:
        p.send(b"jkl")
        p.pump(0.05)
        saw_refresh = b"refreshing" in p.buf
    ok("key burst: deadline still fired") if saw_refresh else \
        bad("key burst: deadline still fired", "no worker spawned during 6s burst")
    p.pump(1.0)                                  # let the queued burst drain
    p.send(b"q")
    rc = finish(p, pid, 25)                      # queued keys repaint in order
    ok("key burst: q exits") if rc == 0 else bad("key burst: q exits", "rc=%r" % rc)
    p.close()


# --- scenario 18: a hung model source can't stall PR data -----------------------
def s_model_hang():
    """PR_AGENT_MODEL_LOOKUP names a probe that execs a 30s sleep — the model
    phase is bounded (PR_AGENT_MODEL_TIMEOUT=2), so records still render
    quickly on plain PR data, and cancelling the watch reaps the probe."""
    wtmp = os.path.join(STATE, "wtmp-model")
    os.makedirs(wtmp)
    mpids = os.path.join(STATE, "model.pids")
    open(mpids, "w").close()
    probe = os.path.join(os.path.dirname(GHBIN), "model-probe")
    p = Pty(24, 80)
    pid = p.spawn('exec "%s" status -w 60' % TOOL,
                  env({"MKTEMP_STUB_DIR": wtmp,
                       "PR_AGENT_MODEL_LOOKUP": probe,
                       "PR_AGENT_MODEL_TIMEOUT": "2",
                       "MODEL_PROBE_SLEEP": "30",
                       "MODEL_PIDFILE": mpids}))
    refresh_caches()
    try:                                        # stale model cache -> collect,
        os.utime(os.path.join(                  # or the probe never runs
            STATE, "repos", "test__pty", "status_models"), (0, 0))
    except OSError:
        pass
    ok("model hang: records still render") if p.pump_until(b"#20", 30) else \
        bad("model hang: records still render", "no data frame in 30s")
    ok("model hang: probe actually ran") if os.path.getsize(mpids) > 0 else \
        bad("model hang: probe actually ran", "no probe pid recorded")
    p.send(b"q")
    rc = p.wait(pid, 6)
    ok("model hang: q exits") if rc == 0 else bad("model hang: q exits", "rc=%r" % rc)
    time.sleep(0.4)
    live = [x for x in open(mpids).read().split() if alive_pid(x)]
    ok("model hang: probe reaped on exit") if not live else \
        bad("model hang: probe reaped on exit", "orphans %r" % live)
    left = stub_leftovers(wtmp)
    ok("model hang: no tempfile leaks") if not left else \
        bad("model hang: no tempfile leaks", left)
    p.close()


s_nav()
s_sigint()
s_resize()
s_small()
s_nocolor()
s_garbage()
s_badinterval()
s_ten_records()
s_saved_caps()
s_sigterm()
s_eof()
s_term_dumb()
s_retry_quit()
s_sigint_mid_gather()
s_hung_gather()
s_worker_bound()
s_key_burst()
s_model_hang()
print("--- status_pty: %d passed, %d failed" % (OKC, FAILC))
sys.exit(1 if FAILC else 0)
