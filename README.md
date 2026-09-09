# Simple SIP

A minimal SIP softphone for the Omarchy bar. One account, one call at a time:
register, dial out, answer what comes in. [baresip](https://github.com/baresip/baresip)
does all the SIP, RTP and audio work.

![Simple SIP panel](preview.png)

```
  registered, idle            ringing (blinking, urgent colour)
  in a call                   dimmed: no account / daemon stopped
```

## Requirements

Two packages, both in the official Arch repos:

```bash
omarchy pkg add baresip python-jeepney
```

- **`baresip`** — does all the SIP, RTP and audio work.
- **`python-jeepney`** — 450 KiB, pure Python, and its only dependency is `python`
  itself. The control helper drives baresip over D-Bus; jeepney is the client
  library. Install it from the repos, not `pip install --user`: the helper runs
  as `#!/usr/bin/python3 -I`, and isolated mode deliberately ignores the user
  site directory, so a `--user` install would not be importable.

Already present on any Omarchy install, listed for completeness: PipeWire's
PulseAudio interface (`pipewire-pulse`) and `python3`. The control helper is
stdlib plus jeepney — no pip packages, no build step, no compiled binary.

## Install

```bash
omarchy plugin add https://github.com/<you>/omarchy-simple-sip --enable
~/.config/omarchy/plugins/io.github.17xande.simple-sip/bin/omarchy-sip install
```

`install` generates the baresip config, writes a `systemd --user` unit and starts it.
The daemon holds the SIP registration continuously, so calls arrive even when the
panel is closed and across shell restarts.

Then set your account — either in the panel (the setup form appears until an account
exists) or from a terminal, which keeps the password out of your shell history:

![Account setup](docs/account-setup.png)

```bash
read -rs PASSWORD
printf '%s' "$PASSWORD" | omarchy-sip account set sip:you@pbx.example.com \
    --auth-user you --transport tls
unset PASSWORD
```

## Using it

| Action | Panel | Keyboard | IPC |
|---|---|---|---|
| Call | type an extension or `sip:user@host`, press Enter | — | `omarchy-shell io.github.17xande.simple-sip dial sip:1001@pbx` |
| Answer | click **Answer** | `a` | `omarchy-shell io.github.17xande.simple-sip answer` |
| Reject / hang up | click **Reject** / **Hang up** | `d` / `b` | `omarchy-shell io.github.17xande.simple-sip hangup` |
| Account settings | click the gear row | `s` | — |

A bare extension or phone number is completed with your account's domain, so `1001`
dials `sip:1001@pbx.example.com`. Incoming calls raise a critical-urgency
notification and (by default) open the panel.

The ring itself is a generated 400+450 Hz double-ring, written to
`~/.config/omarchy-sip/ring.wav` on daemon start. baresip's bundled `ring.wav` is a
recording of a voice announcing that the phone is ringing, which is not what a phone
sounds like; the cadence and level are the `RING_*` constants in `bin/omarchy-sip`.

### Recent calls

The panel keeps a short log of calls made, received and missed. An inbound call that
never reached "established" is a **miss** (shown in the urgent colour); an outbound one
that was never picked up is just "No answer". Selecting a row redials it, with the
mouse or the keyboard.

The log is written by the daemon, not the panel, so a call that starts and ends while
the shell is restarting is still recorded. It lives in
`~/.config/omarchy-sip/history.jsonl` (mode `0600`, last 50 calls), and
`historyLimit: 0` in the widget settings hides the section entirely.

### Keybindings

Omarchy plugins cannot ship keybindings — the manifest has no such field, and
installing a plugin never writes to your Hyprland config. Add what you want to
`~/.config/hypr/bindings.conf`:

```
bindd = SUPER SHIFT, T, SIP dialer, exec, omarchy-shell io.github.17xande.simple-sip toggle
bindd = SUPER, F9, Answer SIP call, exec, omarchy-shell io.github.17xande.simple-sip answer
bindd = SUPER SHIFT, F9, Hang up SIP call, exec, omarchy-shell io.github.17xande.simple-sip hangup
```

`SUPER+SHIFT+T` is unbound in a default Omarchy install. Note that `SUPER+SHIFT+P`
is **not** free — Omarchy binds it to Google Photos.

## How it works

The daemon drives baresip over the **session D-Bus** (baresip's `ctrl_dbus` module,
`com.github.Baresip` at `/baresip`) and re-exports that control surface on one unix
socket, which is what everything else talks to:

```
$XDG_RUNTIME_DIR/omarchy-sip/control   one JSON object per line, both directions
```

Clients connect, write commands, and read the event stream back. Every baresip
event and every command response is broadcast to every connected client, so any
number of readers see the whole picture. The panel drives its state from *events*
(structured); the `status` snapshot exists only to resync after a shell restart,
when the last registration event may be minutes old.

D-Bus rather than baresip's `ctrl_tcp` is a deliberate security choice, covered
under [Security notes](#the-control-plane). A socket rather than a FIFO plus an
on-disk journal is another: nothing persistent has to be reopened by name to move a
message, which
removes the substitution and truncation races that come with re-resolving a
pathname in a directory other local processes can write to.

```
Panel.qml ── omarchy-sip events (subprocess) ── control socket ── omarchy-sip daemon
                                                                          │ session D-Bus
                                                                       baresip ── SIP/RTP/audio
```

The panel talks to that socket through `omarchy-sip` as a subprocess rather than
connecting to it directly — `events` for the long-lived stream, `send` for
dial/accept/hangup — which is covered under
[Security notes](#the-control-plane) alongside why.

`Model.js` holds every pure function (event mapping, URI completion, duration
formatting, and the one place that scrapes baresip's prose output). `Service.qml`
owns state and processes. `Panel.qml` is a view with no call state of its own.

**Swapping the engine.** The QML only ever calls
`omarchy-sip {events,status,dial,answer,hangup,account}` with JSON in and out.
Replacing baresip with something else means reimplementing that contract; the QML
does not change.

## CLI

```
omarchy-sip install | uninstall            set up or remove the user service
omarchy-sip start | stop | restart         control the daemon
omarchy-sip status                         JSON: unit, account and baresip state
omarchy-sip events                         stream the JSON event feed
omarchy-sip dial <uri> | answer | hangup   call control
omarchy-sip send <cmd> [params]            any baresip command, fire-and-forget
omarchy-sip cmd  <cmd> [params]            ... and print the response
omarchy-sip history [--limit N]            recent calls as JSON
omarchy-sip account show | set | clear     account management
```

`send`/`cmd` reach every baresip command, which is handy for things the panel does
not surface: `omarchy-sip cmd callstat`, `omarchy-sip cmd reginfo`,
`omarchy-sip cmd listcalls`.

Environment overrides:

| Variable | Default | What it does |
|---|---|---|
| `OMARCHY_SIP_CONF` | `~/.config/omarchy-sip` | Config directory |
| `OMARCHY_SIP_LISTEN` | `0.0.0.0:0` | SIP bind address; set a fixed port only if your PBX requires one |
| `OMARCHY_SIP_INTERFACE` | *(unset)* | Bind SIP to one interface, e.g. `wlp4s0`. Cuts the listener count substantially — see [The SIP listener](#the-sip-listener) — but defeats roaming, so it is off by default |

Set them in the unit with `systemctl --user edit omarchy-sip`.

## Security notes

- Credentials live in `~/.config/omarchy-sip/accounts`, mode `0600`. baresip's
  accounts format is `;`-delimited, so a password containing `;` is rejected rather
  than silently truncated.
- Passwords are passed to the CLI on **stdin**, never as an argument, so they never
  appear in a process listing.

### The control plane

baresip is driven over the **session D-Bus**, and `ctrl_tcp` is deliberately not
loaded. `ctrl_tcp` is an unauthenticated TCP listener on loopback, which means it is
reachable by every *other user* on the machine, not just you — and its connect
handler drops the existing client whenever a new one arrives, so any local process
could evict this daemon and take over the registered SIP account without racing
anything. There is no way to authenticate it.

The session bus has the properties ctrl_tcp lacks. Its socket lives in
`$XDG_RUNTIME_DIR`, mode 0700, so it is unreachable across uids at the filesystem
layer, and `dbus-daemon` authenticates every client with `SO_PEERCRED` (EXTERNAL
auth) rather than trusting whoever connects. The daemon refuses to start if
`com.github.Baresip` is already owned, rather than driving somebody else's baresip.

The plugin's own control socket is checked the same way: it is 0600 inside a 0700
pinned directory, and `accept()` additionally reads `SO_PEERCRED` and refuses any
client that is not this uid — asking the kernel who is on the other end rather than
inferring it from the permissions of a pathname.

Within your own session, any process you run can still place calls, exactly as it
can read your files. That is the same boundary every other Omarchy plugin has.
- Like all Omarchy plugins, this runs unsandboxed inside the long-lived
  `omarchy-shell` process, with your user's permissions.

### What gets executed

Everything this plugin spawns runs inside a long-lived shell process whose
environment it does not control, so nothing it executes is chosen by that
environment. Binaries are resolved from a fixed list of root-owned system
directories (`/usr/local/bin`, `/usr/bin`, `/bin`) and never from `$PATH`. The
helper's shebang is `#!/usr/bin/python3 -I` — absolute, so no version-manager shim
or writable `PATH` entry picks the interpreter, and isolated, so `PYTHONPATH`,
`PYTHONHOME` and the user site directory cannot inject code into it.

Every process the panel launches sets `clearEnvironment: true` and receives only
`HOME`, `XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS`, `LANG`, a fixed `PATH`, and
this plugin's own `OMARCHY_SIP_*` overrides. baresip — the process that holds the
SIP credentials — gets a six-variable allowlist rather than the ~185 it would
inherit. The `systemd --user` unit runs the interpreter isolated, pins `PATH`, and
carries `UnsetEnvironment=PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONUSERBASE
LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT`, because a user unit otherwise inherits the
user manager's environment, which the user can add to via `environment.d`. An
already-installed unit is content-compared against the generated one on every
`start`/`restart` and rewritten if it has drifted, so this reaches existing
installs rather than only new ones.

### The SIP listener

A registered softphone has to be reachable for inbound calls — that is the job, and
it is a different thing from the control plane above. What arrives on the SIP port
is an INVITE, which at worst makes the phone ring with a caller ID of the sender's
choosing. It cannot place calls *from* your account, cannot read your credentials,
and cannot drive the daemon; those all require the control socket, which is
peer-credential checked. This is not the ctrl_tcp problem wearing a different hat.

It is still more surface than it needs to be. baresip's default opens a listener for
**every transport on every address it can see** — on a typical laptop that means
udp, tcp *and* tls across wifi, `docker0`, bridges, veths and `tailscale0`, none of
which have any business carrying SIP. On this machine that was 35 listeners.

Two things narrow it:

- **Automatic.** `sip_transports` is generated from the account, so only the
  transport actually registering gets a listener — the registrar answers on the one
  we registered over, so the other two are pure surface. 35 listeners → 13.
- **Opt-in.** `OMARCHY_SIP_INTERFACE=wlp4s0` sets baresip's `net_interface`, binding
  SIP to one interface. 13 → 4. This is *not* the default because it defeats
  `netroam`: move between wifi and ethernet, or onto a different network, and calls
  stop arriving until you change it. Set it if this machine does not roam.

What remains — one transport on the interfaces you actually use — is the irreducible
part. A phone that cannot be rung is not a phone.

### Directories and descriptors

Both directories the plugin owns — `~/.config/omarchy-sip` and
`$XDG_RUNTIME_DIR/omarchy-sip` — are *pinned*. The path is walked from `/` one
component at a time, each component opened with `O_DIRECTORY | O_NOFOLLOW` relative
to the descriptor of the one above it and checked for ownership, and the leaf
descriptor is then held for the life of the process. Everything afterwards is
opened relative to that descriptor by basename.

This matters because validating a *name* and reopening it later is not enough: a
process running as you can replace an intermediate directory in between, and a
final-component `O_NOFOLLOW` will not notice that the directory underneath changed.
A held descriptor refers to the directory *inode*, so it keeps resolving to the same
place no matter what happens to the names above it.

Each file is then opened with `O_NOFOLLOW | O_NONBLOCK | O_NOCTTY` and validated with
`fstat` **on the descriptor that will actually be used**, for type and owner.
Checking the descriptor rather than the pathname is what makes the check unraceable,
and `O_NONBLOCK` is what stops a FIFO substituted for a regular file from parking a
helper inside `open()`.

`~/.config/systemd/user` gets the same treatment — the unit file is created and
removed relative to a pinned descriptor, never by pathname. Its *mode*, though, is
left exactly as found: that directory is systemd's, not this plugin's, and forcing a
mode on it would silently widen a private one. Only the two directories the plugin
owns have their mode enforced, and only downwards.

### Writes replace, they never truncate

`O_NOFOLLOW` refuses a symlink but not a same-owner **hard link**. Opening
`accounts` with `O_TRUNC` would push your SIP password straight into whatever a
planted link points at, before any check could reject it. So a destination is never
opened for writing. Instead a fresh file is created under the pinned directory
descriptor with `O_CREAT | O_EXCL` and an unpredictable name — `O_EXCL` guarantees a
brand-new inode with no pre-existing links — written, `fsync`ed, revalidated on the
still-open write descriptor, and moved into place with `renameat`. A planted hard
link keeps the old bytes; a planted symlink is replaced and its target untouched.

### Ceilings

Nothing is read without one: whole-file reads cap at 1 MiB, one event record or
command line at 64 KiB, one history field at 512 bytes, 200 history records, and
baresip's prose replies at 8 KiB before they are spliced into `omarchy-sip status`.
An oversized record is dropped and the stream resynchronises at the next newline
rather than buffering. A client that never sends a newline cannot grow the daemon's
memory, and one that stops reading is disconnected rather than buffered forever.

### Processes

The QML side consumes each helper's diagnostic output a line at a time into a
240-character buffer instead of retaining whole streams, and every finite CLI call
has a whole-process deadline (10–20 s) after which the child is terminated. The
control socket is the one long-lived connection, and it is bounded by the per-record
cap rather than by a deadline.

### Limits of all this

A process already running as your user can do anything you can do; none of the above
is a boundary against *you*. What it defends is the narrower and more realistic case
of a confused deputy — something that can create a file or a link in one of these
directories persuading the daemon to read, write, or block on the wrong object.

The panel does not connect to the control socket directly. Quickshell's `Socket`
takes a `path`, not a descriptor, so a direct connection would resolve the pathname
fresh every time and could not pin the directory the way the daemon does — and its
`SplitParser` has no byte ceiling, so a peer that never sends a newline would grow
its buffer inside the long-lived shell process without bound. Both close if the
panel instead talks through `omarchy-sip` as a subprocess: `events` for the
long-lived stream, `send` for dial/accept/hangup. The CLI resolves the socket
through the same pinned runtime-directory descriptor the daemon walks, and
`read_lines()` bounds every record before anything is handed to QML, exactly as it
already did for `omarchy-sip status`/`history`. The cost is one always-running child
process where a raw socket would have needed none.

### Privileges

The plugin never invokes `sudo` and never calls a package manager, and it has no
install hook — the `omarchy pkg add` line in [Requirements](#requirements) is an
instruction for you to run, not something this code executes. (Underneath, that
wrapper is `sudo pacman -S --needed`; naming it here rather than hiding it, since
installing the two dependencies genuinely does need root.) `systemctl` is only
ever called as `systemctl --user` and only ever names this plugin's own unit,
`omarchy-sip.service`.

## Not in this version

- No mute — baresip's `menu` module exposes no mute command, so it would mean
  muting the system input device instead of just the call.
- No DTMF keypad, no multiple accounts, no call transfer or hold.
- Direct IP-to-IP calls need a reachable interface; baresip refuses loopback
  destinations with `no laddr for 127.0.0.1`.

## Troubleshooting

```bash
systemctl --user status omarchy-sip      # is the daemon up?
omarchy-sip status                       # what does it think is going on?
omarchy-sip events                       # watch calls happen live
cat $XDG_RUNTIME_DIR/omarchy-sip/baresip.log
qs log -p /usr/share/omarchy/shell --tail 100    # QML errors
```

If the daemon refuses to start with *"com.github.Baresip is already owned"*,
another baresip is running and exporting the control interface; the daemon
deliberately will not adopt it. Find it with
`busctl --user status com.github.Baresip`.

## Hacking on it

`.qml` edits hot-reload *into new instances*, but a bar widget already on the bar
keeps running the code it was created with — `omarchy-shell shell rescanPlugins`
will happily report "reloading" while the live widget carries on unchanged. Run
`omarchy-restart-shell` after touching `Service.qml` or `Panel.qml` if the change
does not seem to take. **`Model.js` edits never hot-reload** — the QML engine caches JS
imports for the life of the shell process, and neither `omarchy-shell shell
rescanPlugins` nor disabling/re-enabling the plugin clears them. Run
`omarchy-restart-shell` after touching `Model.js` (not `omarchy-refresh-shell`,
which also resets `shell.json` to defaults).

`Model.js` is deliberately free of QML objects, so its logic can be exercised
straight from node:

```bash
node -e 'const s=require("fs").readFileSync("Model.js","utf8");const M={};
new Function("exports",s+"\nObject.assign(exports,{normalizeTarget,parseReginfo});")(M);
console.log(M.normalizeTarget("1001","sip:you@pbx.example.com"));'
```

### Tests

```bash
./tests/run
```

Three dependency-free suites: `tests/model_test.js` covers every pure function in
`Model.js` (event mapping, URI completion, the registration-status scraping, relative
times), `tests/tracker_test.py` covers the call log's made / received / missed
classification, interleaved calls, the size cap and file permissions, and
`tests/io_test.py` covers the file/descriptor discipline described under
[Security notes](#directories-and-descriptors) — each case swaps a symlink, a FIFO,
an intermediate directory or a hard link in for something the plugin expects to own,
and asserts it fails, clips, or lands on the pinned object rather than following,
blocking, or buffering without limit.

`qmllint` cannot resolve the shell's `Panel` type and exits 255 with no output on
this plugin *and* on the first-party ones, so it is not a useful gate here.

## License

MIT
