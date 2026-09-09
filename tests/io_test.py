"""Exercise the file/descriptor discipline the daemon and CLI depend on.

Every case here is a substitution attack in miniature: swap a symlink, a FIFO,
an intermediate directory or a hard link in for something the plugin expects to
own, and check that it fails, clips, or lands on the pinned object instead of
following, blocking, or buffering without limit.

Run: python3 tests/io_test.py
"""
import contextlib, importlib.machinery, importlib.util, io, json, os, socket, stat, struct, subprocess, sys, tempfile, time, wave

spec = importlib.util.spec_from_loader(
    "omarchy_sip",
    importlib.machinery.SourceFileLoader(
        "omarchy_sip", os.path.join(os.path.dirname(__file__), "..", "bin", "omarchy-sip")
    ),
)
mod = importlib.util.module_from_spec(spec)
sys.modules["omarchy_sip"] = mod
spec.loader.exec_module(mod)

tmp = tempfile.mkdtemp()
fails = 0


def check(label, ok):
    global fails
    fails += 0 if ok else 1
    print(("ok   " if ok else "FAIL ") + label)


def dies(fn, *args, **kwargs):
    """True when fn() exits via die() -- stderr swallowed, it is expected."""
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            fn(*args, **kwargs)
    except SystemExit:
        return True
    return False


def path(name):
    return os.path.join(tmp, name)


# ------------------------------------------------------------------- pin_dir

os.mkdir(path("real"), 0o700)
os.symlink(path("real"), path("link"))
check("pin_dir refuses a symlinked leaf", dies(mod.pin_dir, path("link")))

os.mkdir(path("chain"), 0o755)
os.mkdir(path("chain/mid"), 0o755)
os.mkdir(path("chain/mid/leaf"), 0o700)
os.symlink(path("chain/mid"), path("chain/vialink"))
check("pin_dir refuses a symlinked intermediate component",
      dies(mod.pin_dir, path("chain/vialink/leaf")))

os.mkdir(path("loose"), 0o755)
os.close(mod.pin_dir(path("loose")))
check("pin_dir tightens a group/other-readable leaf",
      stat.S_IMODE(os.stat(path("loose")).st_mode) == 0o700)

os.close(mod.pin_dir(path("fresh/nested")))
check("pin_dir creates a missing leaf at 0700",
      stat.S_IMODE(os.stat(path("fresh/nested")).st_mode) == 0o700)

# A directory we merely drop a file into -- ~/.config/systemd/user -- is not
# ours to re-mode. Forcing 0755 on it would silently widen a user who keeps
# their unit directory private, on every `status` poll.
os.mkdir(path("borrowed"), 0o700)
os.close(mod.pin_dir(path("borrowed"), 0o755, owned=False))
check("pin_dir leaves an unowned existing leaf's mode alone",
      stat.S_IMODE(os.stat(path("borrowed")).st_mode) == 0o700)

os.close(mod.pin_dir(path("borrowed2"), 0o755, owned=False))
check("pin_dir still creates a missing unowned leaf at its mode",
      stat.S_IMODE(os.stat(path("borrowed2")).st_mode) == 0o755)

mod.write_private("notadir", "", mod.dir_fd_for(path("real")))
check("pin_dir refuses a plain file", dies(mod.pin_dir, path("real/notadir")))


# ------------------------- the finding: same-UID intermediate component swap

# a/b/c pinned, then `b` replaced wholesale by an attacker-controlled directory
# holding a decoy. A pinned descriptor must keep resolving to the real leaf.
os.makedirs(path("swap/b/c"), 0o700)
pinned = mod.pin_dir(path("swap/b/c"))
mod.write_private("accounts", "real-secret\n", pinned)
real_ino = os.stat(path("swap/b/c/accounts")).st_ino

os.makedirs(path("evil/c"), 0o700)
with open(path("evil/c/accounts"), "w") as fh:
    fh.write("decoy\n")
os.rename(path("swap/b"), path("swap/b-old"))
os.rename(path("evil"), path("swap/b"))

got = mod.read_bounded("accounts", pinned)
check("pinned dir survives an intermediate component swap", got == "real-secret\n")
check("swapped-in decoy is never read", "decoy" not in got)
check("reads still land on the original inode",
      os.fstat(mod.open_checked("accounts", os.O_RDONLY, dir_fd=pinned)).st_ino == real_ino)

# ...and the leaf itself being replaced changes nothing for a held descriptor.
os.rename(path("swap/b/c"), path("swap/b/c-gone"))
os.mkdir(path("swap/b/c"), 0o700)
with open(path("swap/b/c/accounts"), "w") as fh:
    fh.write("decoy2\n")
check("pinned dir survives the leaf directory being replaced",
      mod.read_bounded("accounts", pinned) == "real-secret\n")
os.close(pinned)


# -------------------------------------------------------- open_checked reads

conf = mod.dir_fd_for(path("conf"))
mod.write_private("plain", "hello\n", conf)
os.symlink(path("conf/plain"), path("conf/plain.link"))

try:
    os.close(mod.open_checked("plain.link", os.O_RDONLY, dir_fd=conf))
    check("open_checked refuses a symlink", False)
except OSError:
    check("open_checked refuses a symlink", True)

check("read_bounded returns nothing for a symlink",
      mod.read_bounded("plain.link", conf) == "")
check("read_bounded reads a real file", mod.read_bounded("plain", conf) == "hello\n")

# A FIFO standing in for a regular file must fail fast, never park us in open().
os.mkfifo(path("conf/fifo-as-file"), 0o600)
started = time.monotonic()
got = mod.read_bounded("fifo-as-file", conf)
check("read_bounded refuses a FIFO without blocking",
      got == "" and time.monotonic() - started < 1.0)

mod.write_private("big", "x" * 5000, conf)
check("read_bounded stops at its limit", len(mod.read_bounded("big", conf, 100)) == 100)


# ------------------------------------------------- replace, never truncate

mod.write_private("secret", "shh", conf)
check("write_private creates a 0600 file",
      stat.S_IMODE(os.stat(path("conf/secret")).st_mode) == 0o600)

os.chmod(path("conf/secret"), 0o644)
mod.write_private("secret", "shh again", conf)
check("write_private narrows a widened mode back to 0600",
      stat.S_IMODE(os.stat(path("conf/secret")).st_mode) == 0o600)

# O_NOFOLLOW stops a symlink but not a same-owner HARD LINK. Truncating in
# place would push the new password into a file somebody else already holds.
mod.write_private("creds", "old-password\n", conf)
os.link(path("conf/creds"), path("conf/creds.planted"))
mod.write_private("creds", "new-password\n", conf)
check("hard link keeps the old bytes (replace, not truncate)",
      open(path("conf/creds.planted")).read() == "old-password\n")
check("the real file has the new bytes",
      open(path("conf/creds")).read() == "new-password\n")
check("planted link count drops back to 1",
      os.stat(path("conf/creds.planted")).st_nlink == 1)

# A symlink planted at the destination is replaced, and its target untouched.
mod.write_private("target", "untouched\n", conf)
os.symlink(path("conf/target"), path("conf/dest"))
mod.write_private("dest", "written\n", conf)
check("symlink at the destination is replaced, not written through",
      not os.path.islink(path("conf/dest"))
      and open(path("conf/target")).read() == "untouched\n"
      and open(path("conf/dest")).read() == "written\n")


# -------------------------------------------------------------- record bounds

hist = mod.dir_fd_for(path("hist"))
oversized = '{"peer":"' + "y" * (mod.MAX_LINE + 10) + '"}'
mod.write_private(mod.HISTORY, oversized + '\n{"ts":1,"direction":"in","peer":"sip:1@pbx"}\n', hist)
check("read_lines drops an oversized record", len(mod.CallTracker(hist).read_lines()) == 1)

record = mod.history_record({
    "ts": 1, "direction": "in", "peer": "sip:" + "z" * 10000,
    "missed": True, "duration": 10 ** 12, "reason": "w" * 10000,
})
check("history_record clips overlong fields",
      len(record["peer"]) == mod.MAX_FIELD and len(record["reason"]) == mod.MAX_FIELD)
check("history_record clamps an absurd duration", record["duration"] == 7 * 86400)

reply = mod.clip_reply({"data": "d" * (mod.MAX_REPLY_CHARS * 2), "ok": True})
check("clip_reply caps baresip prose",
      len(reply["data"]) == mod.MAX_REPLY_CHARS and reply["ok"] is True)
check("clip_reply passes a non-dict through as None", mod.clip_reply("nope") is None)


# ------------------------------------------------------------ execution trust

# The CLI runs inside a long-lived shell process whose environment it does not
# control. Nothing it executes may be chosen by that environment: not the
# interpreter, not systemctl, not baresip.

CLI = os.path.join(os.path.dirname(__file__), "..", "bin", "omarchy-sip")

with open(CLI, "rb") as fh:
    shebang = fh.readline().decode().strip()
check("the shebang names an absolute interpreter", shebang.startswith("#!/usr/bin/python3"))
check("the shebang runs Python isolated (-I)", shebang.endswith(" -I"))
check("no bare-name execution of the distro binaries",
      mod.SYSTEMCTL == "/usr/bin/systemctl" and mod.BARESIP == "/usr/bin/baresip"
      and mod.PYTHON == "/usr/bin/python3")
check("the unit bakes in the absolute interpreter", mod.unit_python() == "/usr/bin/python3")

# trusted_bin resolves from a fixed list of root-owned directories, so a
# source-built binary in /usr/local/bin still works while $PATH never decides.
check("trusted_bin finds a real binary", mod.trusted_bin("sh") in ("/usr/bin/sh", "/bin/sh"))
check("trusted_bin returns None for a binary that is not there",
      mod.trusted_bin("definitely-not-a-real-binary-xyz") is None)
check("trusted_bin ignores $PATH entirely",
      mod.TRUSTED_BIN_DIRS == ("/usr/local/bin", "/usr/bin", "/bin"))

# sync_unit repairs an installed unit that predates a template change --
# otherwise hardening only ever reaches a fresh install.
unit_dir = path("unitsync")
saved_unit_dir, mod.UNIT_DIR = mod.UNIT_DIR, unit_dir
# Stub systemctl: write_unit() daemon-reloads, and these suites must stay
# dependency-free (no running user manager, e.g. in a container).
saved_systemctl, mod.systemctl = mod.systemctl, lambda *a: 0
mod._DIR_FDS.pop(saved_unit_dir, None)
try:
    ufd = mod.unit_fd()
    check("sync_unit does nothing when no unit is installed", mod.sync_unit() is False)
    mod.write_file(mod.UNIT, "[Service]\nExecStart=/usr/bin/python3 /old daemon\n", ufd, 0o644)
    check("sync_unit rewrites a stale unit", mod.sync_unit() is True)
    check("... to exactly the generated content",
          mod.read_bounded(mod.UNIT, ufd) == mod.unit_text())
    check("sync_unit is a no-op once the unit already matches", mod.sync_unit() is False)
finally:
    mod._DIR_FDS.pop(unit_dir, None)
    mod.UNIT_DIR = saved_unit_dir
    mod.systemctl = saved_systemctl

unit = mod.UNIT_TEMPLATE.format(self="/x/omarchy-sip", python=mod.PYTHON, path=mod.CHILD_PATH)
check("the unit runs the interpreter isolated",
      "ExecStart=/usr/bin/python3 -I /x/omarchy-sip daemon" in unit)
check("the unit pins PATH", f"Environment=PATH={mod.CHILD_PATH}" in unit)
for var in ("PYTHONPATH", "PYTHONHOME", "LD_PRELOAD", "LD_LIBRARY_PATH", "LD_AUDIT"):
    check(f"the unit clears {var}", var in unit.split("UnsetEnvironment=")[1].split("\n")[0])

# child_env(): an allowlist, so a hostile variable is dropped rather than
# forwarded into the process that holds the SIP credentials.
hostile = {
    "PYTHONPATH": "/tmp/evil", "PYTHONHOME": "/tmp/evil", "LD_PRELOAD": "/tmp/evil.so",
    "LD_LIBRARY_PATH": "/tmp/evil", "LD_AUDIT": "/tmp/evil.so", "PATH": "/tmp/evil",
    "HOME": "/home/real", "XDG_RUNTIME_DIR": "/run/user/1000",
}
saved = dict(os.environ)
try:
    os.environ.clear()
    os.environ.update(hostile)
    env = mod.child_env()
finally:
    os.environ.clear()
    os.environ.update(saved)

for var in ("PYTHONPATH", "PYTHONHOME", "LD_PRELOAD", "LD_LIBRARY_PATH", "LD_AUDIT"):
    check(f"child_env drops a hostile {var}", var not in env)
check("child_env replaces a hostile PATH with the fixed one", env["PATH"] == mod.CHILD_PATH)
check("child_env keeps the variables baresip genuinely needs",
      env["HOME"] == "/home/real" and env["XDG_RUNTIME_DIR"] == "/run/user/1000")

# End to end: run the real CLI with a hostile environment and a PATH whose
# first entry shadows systemctl and baresip with a saboteur, and check that
# neither the interpreter nor those binaries were taken from it.
evil = tempfile.mkdtemp(dir=tmp)   # under tmp so it is cleaned up with everything else
marker = os.path.join(evil, "fired")
for name in ("systemctl", "baresip", "python3"):
    shim = os.path.join(evil, name)
    with open(shim, "w") as fh:
        fh.write(f"#!/bin/sh\necho {name} >> {marker}\nexit 0\n")
    os.chmod(shim, 0o755)

# `status` is the right probe: it is the one subcommand that shells out to
# systemctl, so a shim on PATH would actually be reached if PATH were trusted.
# Its runtime dir is redirected too, so this never touches a live daemon.
probe = subprocess.run(
    [CLI, "status"],
    env={"PATH": evil, "PYTHONPATH": evil, "PYTHONHOME": evil, "LD_PRELOAD": "/nonexistent.so",
         "HOME": os.environ.get("HOME", "/tmp"), "OMARCHY_SIP_CONF": path("envtest"),
         "XDG_RUNTIME_DIR": path("envrun")},
    capture_output=True, text=True, timeout=30,
)
check("the CLI still runs under a hostile PATH/PYTHONPATH/LD_PRELOAD", probe.returncode == 0)
check("... and produced real output, not a shim's",
      probe.stdout.startswith("{") and '"installed"' in probe.stdout)
check("... and never executed a shadowed systemctl from that PATH",
      not os.path.exists(marker))

# Positive control. "the marker file was not written" is only evidence if the
# shims are reachable in the first place -- otherwise it passes for any reason
# at all, including a typo in the shim path. Run something that *does* resolve
# through PATH under the identical environment and assert the shim fires.
control = subprocess.run(
    ["/bin/sh", "-c", "systemctl --user is-active nothing.service"],
    env={"PATH": evil}, capture_output=True, text=True, timeout=30,
)
check("positive control: a bare name under that PATH really does hit the shim",
      os.path.exists(marker) and "systemctl" in open(marker).read())


# ---------------------------------------------------------- baresip log cap

# subprocess.Popen(stdout=log_fd) dup2s our fd into baresip, so the two share
# one open file description -- including the offset. ftruncate+lseek on our
# copy must therefore rotate the file baresip is still writing to, in place,
# with no reopen by either side.

def logcap(path_, before, limit):
    fd = os.open(path_, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.write(fd, before)
    mod.cap_baresip_log(fd, limit=limit)
    size_after_cap = os.fstat(fd).st_size
    os.write(fd, b"next")   # simulates baresip's next write via the shared fd
    os.close(fd)
    return size_after_cap, open(path_, "rb").read()


logp = path("baresip.log")
check("cap_baresip_log leaves a file under the limit alone",
      logcap(logp, b"x" * 50, 100) == (50, b"x" * 50 + b"next"))
after, content = logcap(logp, b"x" * 500, 100)
check("cap_baresip_log truncates a file over the limit", after == 0)
check("... and the next write lands at the front of the now-empty file",
      content == b"next")


# ------------------------------------------------------------ account fields

# baresip's accounts file is ';'-delimited, one line per account. A field that
# reached it unbounded or carrying a newline, ';' or '"' could grow the file
# without limit or splice a second, attacker-chosen account line into it.

check("account_field accepts an ordinary value",
      mod.account_field("x", "sip:you@pbx.example.com") == "sip:you@pbx.example.com")
check("account_field rejects a value over its limit",
      dies(mod.account_field, "x", "a" * 300))
check("account_field accepts exactly the limit", mod.account_field("x", "a" * 256) == "a" * 256)
for bad in ("\n", "\r", ";", '"'):
    check(f"account_field rejects an embedded {bad!r}", dies(mod.account_field, "x", f"a{bad}b"))

# read_password_from_stdin: bounded by bytes, not only by the wall-clock
# deadline -- a writer that keeps the pipe open and keeps sending must not be
# able to grow the buffer past the limit no matter how long it writes for.

def password_from(data, limit=64):
    r, w = os.pipe()
    os.write(w, data)
    os.close(w)
    old_stdin = sys.stdin
    try:
        sys.stdin = os.fdopen(r)
        return mod.read_password_from_stdin(timeout=1.0, limit=limit)
    finally:
        sys.stdin = old_stdin


check("read_password_from_stdin reads an ordinary password",
      password_from(b"hunter2\n") == "hunter2")
check("read_password_from_stdin caps a password with no newline at all",
      len(password_from(b"a" * 500)) == 64)
check("read_password_from_stdin caps a password past the limit even with a newline",
      len(password_from(b"a" * 500 + b"\n")) == 64)


# ------------------------------------------------------- account transport

# sip_transports is derived from the account so baresip only opens a listener
# for the transport actually in use, instead of udp+tcp+tls on every address.

acct = mod.dir_fd_for(path("acct"))
orig_conf, mod.CONF_DIR = mod.CONF_DIR, path("acct")


def transport_for(line):
    mod.write_private(mod.ACCOUNTS, line, acct)
    return mod.account_transport()


check("transport defaults to udp when unset",
      transport_for('<sip:a@b>;regint=600\n') == "udp")
check("transport is read from the account", transport_for('<sip:a@b>;transport=tls\n') == "tls")
check("transport tcp is read", transport_for('<sip:a@b>;transport=tcp\n') == "tcp")
check("an unknown transport falls back to udp",
      transport_for('<sip:a@b>;transport=sctp\n') == "udp")
check("a comment line is skipped", transport_for('# note\n<sip:a@b>;transport=tcp\n') == "tcp")
check("an empty accounts file is udp", transport_for("") == "udp")

mod.CONF_DIR = orig_conf


# --------------------------------------------------------- command dispatch

# The client wire protocol is unchanged from the ctrl_tcp days, but it is now
# flattened into a single ctrl_dbus command string that runs through baresip's
# own command-line grammar. A command name outside the fixed allowlist, or a
# parameter that does not match that command's own grammar, must be refused
# rather than forwarded -- including a parameter that tries to smuggle a
# second command past the join with a newline or a ';'.

class FakeBus:
    def __init__(self):
        self.calls = []

    def invoke(self, line, token):
        self.calls.append((line, token))


class FakeHub:
    def __init__(self):
        self.rejections = []

    def broadcast(self, text):
        self.rejections.append(json.loads(text))


def dispatched(raw):
    bus, hub = FakeBus(), FakeHub()
    mod.dispatch(bus, hub, raw)
    return bus.calls, hub.rejections


check("dispatch joins a dial command and its target",
      dispatched(b'{"command":"dial","params":"sip:a@b","token":"t"}')
      == ([("dial sip:a@b", "t")], []))
check("dispatch handles a no-parameter command",
      dispatched(b'{"command":"hangup"}') == ([("hangup", "")], []))
check("dispatch allows every command this plugin actually issues",
      all(dispatched(('{"command":"%s"}' % c).encode())[0] == [(c, "")]
          for c in ("accept", "hangup", "reginfo", "listcalls")))

calls, rejections = dispatched(b'{"command":"quit","token":"t"}')
check("dispatch refuses a command outside the allowlist", calls == [])
check("... and tells the caller so", rejections == [
    {"response": True, "ok": False, "data": "command not permitted", "token": "t"}])

check("dispatch refuses a newline smuggled into dial's target",
      dispatched(b'{"command":"dial","params":"sip:a@b\nquit","token":"t"}')[0] == [])
check("dispatch refuses a target with no sip(s): scheme",
      dispatched(b'{"command":"dial","params":"a@b","token":"t"}')[0] == [])
check("dispatch refuses a semicolon smuggled into dial's target",
      dispatched(b'{"command":"dial","params":"sip:a@b;quit","token":"t"}')[0] == [])
check("dispatch refuses a quote smuggled into dial's target",
      dispatched(b'{"command":"dial","params":"sip:a@b' + b'"' + b'quit","token":"t"}')[0] == [])
check("dispatch refuses a space in dial's target",
      dispatched(b'{"command":"dial","params":"sip:a@b quit","token":"t"}')[0] == [])
check("dispatch allows a feature code",
      dispatched(b'{"command":"dial","params":"sip:*43@pbx","token":"t"}')[0]
      == [("dial sip:*43@pbx", "t")])
check("dispatch allows an explicit port",
      dispatched(b'{"command":"dial","params":"sip:b@x.com:5080","token":"t"}')[0]
      == [("dial sip:b@x.com:5080", "t")])
check("dispatch refuses a no-parameter command that was given one anyway",
      dispatched(b'{"command":"hangup","params":"sip:a@b","token":"t"}')[0] == [])
check("dispatch ignores malformed JSON", dispatched(b"not json") == ([], []))
check("dispatch ignores a non-object", dispatched(b'["dial"]') == ([], []))
check("dispatch clips an overlong token on the accepted path",
      len(dispatched(b'{"command":"hangup","token":"' + b"z" * 500 + b'"}')[0][0][1]) == 128)
check("dispatch clips an overlong token on the rejected path",
      len(dispatched(b'{"command":"quit","token":"' + b"z" * 500 + b'"}')[1][0]["token"]) == 128)


# ----------------------------------------------------------------- ringtone

ring = mod.ringtone_wav()
wav = wave.open(io.BytesIO(ring))
check("the ringtone is a WAV the stdlib can parse", wav.getnframes() > 0)
check("...mono 16-bit PCM at the alert rate, which is what aufile_open accepts",
      (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) == (1, 2, mod.RING_RATE))
check("...its declared length matches the cadence",
      wav.getnframes() == int(sum(sec for sec, _ in mod.RING_CADENCE) * mod.RING_RATE))
check("...and its header sizes agree with the payload",
      struct.unpack("<I", ring[4:8])[0] == len(ring) - 8
      and struct.unpack("<I", ring[40:44])[0] == len(ring) - 44)

pcm = struct.unpack(f"<{wav.getnframes()}h", wav.readframes(wav.getnframes()))


def loudness(start, end):
    seg = pcm[int(start * mod.RING_RATE):int(end * mod.RING_RATE)]
    return max(abs(v) for v in seg)


# Two bursts with a gap, then a long pause -- a ring, not a continuous tone.
check("the ringtone actually rings twice", loudness(0.05, 0.35) > 3000
      and loudness(0.45, 0.55) == 0 and loudness(0.65, 0.95) > 3000)
check("...then pauses before repeating", loudness(1.2, 2.9) == 0)
check("...without clipping", max(abs(v) for v in pcm) < 32767)
check("...and starts and ends at silence, so a loop has no click in it",
      pcm[0] == 0 and pcm[-1] == 0)

# It is written as bytes through the same 0600 create-and-rename path as the
# rest of the config directory, so the text-only assumption cannot creep back.
ring_dir = mod.dir_fd_for(path("run"))
mod.write_private("ring.wav", ring, ring_dir)
check("the ringtone is written byte-exact and 0600",
      open(path("run/ring.wav"), "rb").read() == ring
      and stat.S_IMODE(os.stat(path("run/ring.wav")).st_mode) == 0o600)


# ------------------------------------------------------------- socket bounds

a, b = socket.socketpair()
b.sendall(b'{"a":1}\n' + b"z" * (mod.MAX_LINE + 10) + b'\n{"a":2}\n')
b.close()
lines = list(mod.read_lines(a, time.monotonic() + 2))
a.close()
check("stream drops an oversized record and resynchronises",
      lines == ['{"a":1}', '{"a":2}'])

# The regression this whole class of bug came from: connect_control() leaves a
# 5s timeout on the socket for the connect, and the event stream then reads
# from it forever. A read_lines() with no deadline must clear that timeout, or
# `omarchy-sip events` returns after the first quiet five seconds and the panel
# loses the only path an incoming call has to reach it.
a, b = socket.socketpair()
a.settimeout(0.2)                       # stands in for the connect timeout
stream = mod.read_lines(a)              # no deadline: the always-on listener
b.sendall(b'{"a":1}\n')
check("a deadline-less stream keeps its first record", next(stream) == '{"a":1}')
check("... and does not inherit the connect timeout", a.gettimeout() is None)
b.sendall(b'{"a":2}\n')                 # arrives well after any 0.2s timeout
check("... so a quiet stream is not mistaken for the end of it",
      next(stream) == '{"a":2}')
stream.close()
a.close()
b.close()

# A bounded reader still gets its deadline back.
a, b = socket.socketpair()
b.sendall(b'{"a":1}\n')
started = time.monotonic()
check("a deadline-carrying read still stops on its own",
      list(mod.read_lines(a, time.monotonic() + 0.3)) == ['{"a":1}']
      and time.monotonic() - started < 2.0)
a.close()
b.close()

# A client that never sends a newline must not grow the daemon's buffer.
srv_dir = mod.dir_fd_for(path("run"))
hub = mod.ControlHub(srv_dir)
check("control socket is created 0600",
      stat.S_IMODE(os.stat(path("run/control")).st_mode) == 0o600)
client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.connect(f"/proc/self/fd/{srv_dir}/control")
conn = hub.accept()
client.sendall(b"x" * (mod.MAX_LINE + 4096))
time.sleep(0.05)
hub.read_commands(conn)
check("a newline-less client cannot grow the daemon buffer",
      len(hub.clients[conn]["buf"]) <= mod.MAX_LINE)
client.sendall(b"tail\n" + b'{"command":"ok"}\n')
time.sleep(0.05)
check("the stream resynchronises at the next newline",
      hub.read_commands(conn) == [b'{"command":"ok"}'])
client.close()

# CTRL_CONNECTED is broadcast once, when baresip comes up, but the panel's
# listener reconnects for as long as the daemon lives -- so a client that
# connects later must still be told the daemon is up, or it never resets its
# reconnect backoff and never learns it can stop retrying.
hub.greet('{"type":"CTRL_CONNECTED"}')
late = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
late.connect(f"/proc/self/fd/{srv_dir}/control")
late_conn = hub.accept()
hub.flush_all()
late.settimeout(1.0)
check("a client connecting after the daemon is greeted on connect",
      late.recv(4096) == b'{"type":"CTRL_CONNECTED"}\n')
check("... and is a normal client afterwards", late_conn in hub.clients)
late.close()

# Greeting a client must never cost us its command. `omarchy-sip send` is
# fire-and-forget: it writes one line and closes, so it is already gone when
# the daemon accepts it and the greeting write fails. Dropping the client on
# that write threw away the command sitting in its receive buffer -- every
# dial, accept and hangup the panel issued, silently.
for attempt in range(3):
    oneshot = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    oneshot.connect(f"/proc/self/fd/{srv_dir}/control")
    oneshot.sendall(b'{"command":"accept","token":"panel"}\n')
    oneshot.close()
    time.sleep(0.05)
    one_conn = hub.accept()
    check(f"a fire-and-forget command survives the greeting ({attempt + 1}/3)",
          one_conn is not None
          and hub.read_commands(one_conn) == [b'{"command":"accept","token":"panel"}'])

# A write that fails leaves the client readable rather than dropped, and its
# outbox emptied so a peer that cannot be written to cannot grow the daemon.
dead = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
dead.connect(f"/proc/self/fd/{srv_dir}/control")
dead_conn = hub.accept()
dead.close()
for _ in range(3):
    hub.broadcast('{"type":"CALL_INCOMING"}')
check("a write error marks the client write-dead instead of dropping it",
      dead_conn in hub.clients and hub.clients[dead_conn]["wdead"] is True
      and hub.clients[dead_conn]["out"] == b"")
check("... and the closed peer is reaped by the read side",
      hub.read_commands(dead_conn) == [] and dead_conn not in hub.clients)
hub.close()
check("closing the hub removes the socket", not os.path.exists(path("run/control")))


# ------------------------------------------------------- connect, don't hang

mod.RUN_DIR = path("empty-run")
mod._DIR_FDS.pop(mod.RUN_DIR, None)
started = time.monotonic()
check("daemon_up is false with nothing listening", mod.daemon_up() is False)
check("connect_control fails fast rather than hanging",
      dies(mod.connect_control) and time.monotonic() - started < 2.0)

print("\nall passed" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
