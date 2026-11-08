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
    if extra:
        e.update(extra)
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
    pid = p.spawn('trap ":" INT; stty -g >"%s/tty.before"; "%s" status -w 60; '
                  'echo "rc=$?" >"%s/watch.rc"; stty -g >"%s/tty.after"'
                  % (STATE, TOOL, STATE, STATE), env({"MKTEMP_STUB_DIR": wtmp}))
    refresh_caches()
    if not p.pump_until(b"\x1b[H", 25):
        bad("first paint", "no frame in 12s, %d bytes" % len(p.buf))
        p.close()
        return
    p.pump(1.0)
    ok("alt-screen entered") if b"\x1b[?1049h" in p.buf else bad("alt-screen entered", "no smcup")
    ok("cursor hidden") if b"\x1b[?25l" in p.buf else bad("cursor hidden", "no civis")
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
    pid = p.spawn('trap ":" INT; stty -g >"%s/tty.before"; "%s" status -w 60; '
                  'echo "rc=$?" >"%s/watch.rc"; stty -g >"%s/tty.after"'
                  % (STATE, TOOL, STATE, STATE), env({"MKTEMP_STUB_DIR": wtmp}))
    refresh_caches()
    if not p.pump_until(b"\x1b[H", 25):
        bad("sigint first paint", "no frame")
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
    if not p.pump_until(b"\x1b[H", 25):
        bad("resize initial paint", "no frame")
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
        ok("interval %s no hot re-gather" % arg) if p.paints() == n0 else \
            bad("interval %s no hot re-gather" % arg,
                "+%d paints in 3s" % (p.paints() - n0))
        p.send(b"q")
        rc = p.wait(pid, 6)
        ok("interval %s q exits 0" % arg) if rc == 0 else \
            bad("interval %s q exits 0" % arg, "rc=%r" % rc)
        p.pump(0.5)
        left = stub_leftovers(wtmp)
        ok("interval %s no tempfile leak" % arg) if not left else \
            bad("interval %s no tempfile leak" % arg, left)
        p.close()


# --- scenario 8: persistent gather failure still honors q/EOF ------------------
def s_retry_quit():
    """Broken jq -> status_gather emits nothing and the watch retries; the
    retry loop must poll input so q still exits (sleep-only loops hung)."""
    wtmp = os.path.join(STATE, "wtmp-retry")
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
    rc = p.wait(pid, 6)
    ok("q exits while gather fails") if rc == 0 else \
        bad("q exits while gather fails", "rc=%r" % rc)
    p.pump(0.5)
    ok("retry exit leaves alt-screen") if b"\x1b[?1049l" in p.buf else \
        bad("retry exit leaves alt-screen", "no rmcup")
    left = stub_leftovers(wtmp)
    ok("retry exit leaves no tempfile") if not left else \
        bad("retry exit leaves no tempfile", left)
    p.close()


s_nav()
s_sigint()
s_resize()
s_small()
s_nocolor()
s_garbage()
s_badinterval()
s_retry_quit()
print("--- status_pty: %d passed, %d failed" % (OKC, FAILC))
sys.exit(1 if FAILC else 0)
