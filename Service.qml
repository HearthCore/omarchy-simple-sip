import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Owns everything stateful about the SIP account and the current call.
//
// The `omarchy-sip` daemon holds baresip's single control connection; this
// service reads its JSON journal (one object per line) and pushes commands
// back. Call state is driven by *events*, never by polling -- the status
// snapshot exists only to resync after a shell restart, when the last
// registration event may be minutes in the past.
Item {
  id: root

  property var settings: ({})

  // ------------------------------------------------------------------ limits
  //
  // The CLI bounds what it prints, but this side must bound what it retains:
  // StdioCollector holds an entire stream, so anything whose full text we do
  // not actually need is consumed a line at a time and clipped as it arrives.
  readonly property int maxLineChars: 65536    // matches MAX_LINE in the CLI
  readonly property int maxJsonChars: 262144   // a status/history document
  readonly property int maxErrorChars: 240     // what lastError can ever hold

  // Qt.resolvedUrl(".") may or may not carry a trailing slash depending on the
  // loader, so normalise before appending.
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "").replace(/\/+$/, "")
  readonly property string cli: pluginDir + "/bin/omarchy-sip"

  // Every child this file launches gets an explicit, minimal environment
  // rather than the shell's. `bin/omarchy-sip` is `#!/usr/bin/python3 -I`, so
  // the interpreter is absolute and isolated already, but the loader still
  // reads LD_PRELOAD/LD_LIBRARY_PATH from whatever omarchy-shell happens to
  // have inherited, and a writable PATH entry would decide which `systemctl`
  // the CLI finds. `clearEnvironment: true` plus these four keys is the whole
  // surface: HOME and XDG_RUNTIME_DIR locate the config and runtime
  // directories, DBUS_SESSION_BUS_ADDRESS lets `systemctl --user` reach the
  // user manager, and PATH is fixed rather than inherited.
  readonly property string cleanPath: "/usr/local/bin:/usr/bin:/bin"

  // The OMARCHY_SIP_* keys are this plugin's own documented overrides and have
  // to be forwarded: the daemon runs under `systemd --user`, which still sees
  // them, so dropping them here would leave the panel reading
  // ~/.config/omarchy-sip while the daemon reads OMARCHY_SIP_CONF -- the panel
  // would report "no account", write credentials to the wrong directory, and
  // restart a daemon that never sees them. They select configuration, not code:
  // the directory they name is still pinned and ownership-checked like any
  // other, so forwarding them costs nothing the execution-trust rule protects.
  function cleanEnv() {
    var env = { "PATH": cleanPath }
    var keys = ["HOME", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS", "LANG",
                "OMARCHY_SIP_CONF", "OMARCHY_SIP_LISTEN", "OMARCHY_SIP_INTERFACE"]
    for (var i = 0; i < keys.length; i++) {
      var value = Quickshell.env(keys[i])
      if (value) env[keys[i]] = String(value)
    }
    return env
  }

  // Events and commands both go through the CLI as a subprocess rather than a
  // QML Socket connected to the control path directly. Two things Quickshell
  // does not give QML a way to do itself: SplitParser has no byte ceiling, so
  // a peer that never sends a newline grows its buffer in this long-lived
  // shell process without bound; and a plain `path` string is resolved fresh
  // on connect, so it does not benefit from the pinned-descriptor resolution
  // the daemon uses for everything else. `read_lines()` in the CLI already
  // enforces MAX_LINE per record before anything is printed, and it resolves
  // the socket through the same pinned runtime-directory descriptor the
  // daemon itself walks -- so routing through it closes both gaps at once,
  // at the cost of one always-running child process instead of none.

  // ------------------------------------------------------------------ state
  property bool installed: false
  property bool unitActive: false
  property bool daemonUp: false
  property bool configured: false
  property string aor: ""
  // unknown | none | pending | registered | failed
  property string registration: "unknown"
  // idle | incoming | outgoing | ringing | active
  property string callState: "idle"
  property string peer: ""
  property string callId: ""
  property double callStartedAt: 0
  property string lastError: ""
  property string lastClosedReason: ""
  // Which of the two sources spoke last. A status snapshot is a request/reply
  // round trip, so its answer can predate a call event that arrived while it
  // was in flight -- comparing these is what keeps applyStatus from clearing a
  // call that started after it asked.
  property double lastCallEventAt: 0
  property double statusRequestedAt: 0
  // Recent calls, newest first, as recorded by the daemon.
  property var history: []

  readonly property bool ready: daemonUp && configured && registration === "registered"
  readonly property bool busy: actionProcess.running
  readonly property bool ringing: callState === "incoming"
  readonly property bool onCall: Model.inCall(callState)

  // Bundled for Model.heroMeta so the panel doesn't hand-assemble it.
  readonly property var snapshot: ({
    daemonUp: daemonUp,
    configured: configured,
    registration: registration,
    aor: aor,
    callState: callState,
    lastError: lastError
  })

  signal incomingCall(string peerUri)

  readonly property int statusRefreshSec: intSetting("statusRefreshSec", 60, 10, 600)
  readonly property int historyLimit: intSetting("historyLimit", 5, 0, 20)

  // Backoff for respawning the `events` subprocess while the daemon is
  // unreachable -- each retry is a Python interpreter start, not a syscall.
  readonly property int eventsRetryMinMs: 3000
  readonly property int eventsRetryMaxMs: 30000
  property int eventsRetryMs: eventsRetryMinMs

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function boolSetting(name, fallback) {
    var value = setting(name, fallback)
    return value === true || value === "true"
  }

  // ---------------------------------------------------------------- commands

  function refresh() {
    refreshHistory()
    if (statusProcess.running) return
    statusRequestedAt = Date.now()
    statusProcess.command = [cli, "status"]
    statusProcess.running = true
    statusWatchdog.restart()
  }

  function refreshHistory() {
    if (historyProcess.running || historyLimit === 0) return
    historyProcess.command = [cli, "history", "--limit", String(historyLimit)]
    historyProcess.running = true
    historyWatchdog.restart()
  }

  // Returns false when another action is already in flight, so a caller that
  // needs to know whether its command actually went out (dial's optimistic UI)
  // can fall back to a resync instead of assuming it did.
  function run(args) {
    if (actionProcess.running) return false
    lastError = ""
    actionProcess.errText = ""
    actionProcess.command = [cli].concat(args)
    actionProcess.running = true
    actionWatchdog.restart()
    return true
  }

  // `omarchy-sip send` -- fire-and-forget, one line down the control socket --
  // as a short subprocess rather than a direct QML Socket write. The CLI
  // resolves the socket through the daemon's own pinned directory descriptor
  // instead of a bare path string, and the existing action watchdog and
  // bounded error buffer come for free.
  function command(name, params) {
    return run(params ? ["send", name, params] : ["send", name])
  }

  // Keeps a bounded prefix of a process's diagnostic output. Called per line,
  // so nothing larger than one line is ever held, let alone the whole stream.
  function appendBounded(buf, line) {
    if (buf.length >= maxErrorChars) return buf
    var text = String(line || "").replace(/\s+/g, " ")
    return (buf === "" ? text : buf + " " + text).substring(0, maxErrorChars)
  }

  function dial(input) {
    var target = Model.normalizeTarget(input, aor)
    if (target === "") return
    // Optimistic: the panel switches to "calling" immediately and the real
    // CALL_OUTGOING / CALL_CLOSED event corrects it a moment later.
    callState = "outgoing"
    peer = Model.peerLabel(target)
    callStartedAt = 0
    if (!command("dial", target)) refresh()
  }

  // Mirrors dial(): a caller that fires while another action is still in
  // flight (a double press on answer/hangup, or two calls to the IpcHandler
  // back to back) must not have its command silently dropped with the UI
  // left showing a call state that no longer matches what actually happened.
  function answer() {
    if (callState !== "incoming") return
    if (!command("accept")) refresh()
  }

  function hangup() {
    if (callState === "idle") return
    if (!command("hangup")) refresh()
  }

  function startDaemon() { run(["start"]) }

  // Password goes over stdin so it never appears in a process listing.
  // Returns false if a save is already in flight, so the caller knows not to
  // clear the form -- dropping the typed password on the floor is worse than
  // making the user press Save again.
  function setAccount(uri, authUser, displayName, transport, password) {
    if (accountProcess.running) return false
    var args = [cli, "account", "set", uri]
    if (authUser) args = args.concat(["--auth-user", authUser])
    if (displayName) args = args.concat(["--display-name", displayName])
    if (transport) args = args.concat(["--transport", transport])
    lastError = ""
    accountProcess.errText = ""
    accountProcess.command = args
    accountProcess.running = true
    accountWatchdog.restart()
    accountProcess.write(String(password || "") + "\n")
    accountProcess.stdinEnabled = false
    return true
  }

  // ------------------------------------------------------------------ events

  function handleLine(line) {
    var text = String(line || "")
    // The journal caps its own records, but this listener runs for the whole
    // shell session: refuse an oversized line before it reaches JSON.parse.
    if (text.length > maxLineChars) return
    text = text.trim()
    if (text === "") return
    var event
    try {
      event = JSON.parse(text)
    } catch (e) {
      return   // not ours; the journal only ever holds JSON, so ignore quietly
    }

    var update = Model.classifyEvent(event)
    if (!update) return

    if (update.kind === "ctrl") {
      daemonUp = update.connected
      if (update.connected) {
        eventsRetryMs = eventsRetryMinMs   // a real connection means the daemon is back
      }
      if (!update.connected) {
        callState = "idle"
        peer = ""
        callId = ""
        callStartedAt = 0
        if (update.error) lastError = update.error
      } else {
        refresh()
      }
      return
    }

    if (update.kind === "registration") {
      registration = update.registration
      if (update.aor) aor = update.aor
      lastError = update.registration === "failed" ? (update.error || "Registration failed") : ""
      return
    }

    if (update.kind === "call") {
      lastCallEventAt = Date.now()
      var wasRinging = callState === "incoming"
      callState = update.callState
      if (update.callState === "idle") {
        peer = ""
        callId = ""
        callStartedAt = 0
        lastClosedReason = update.closedReason || ""
        // The daemon writes the log row as it handles this same event, so give
        // it a beat before reading the file back.
        historySettleTimer.restart()
      } else {
        if (update.peer) peer = update.peer
        if (update.callId) callId = update.callId
        if (update.started && callStartedAt === 0) callStartedAt = Date.now()
      }
      if (update.callState === "incoming" && !wasRinging) announceIncoming()
    }
  }

  // Ringing is the one state the panel must never miss, so both the event
  // stream and a status resync funnel through here.
  function announceIncoming() {
    notifyIncoming(peer)
    root.incomingCall(peer)
  }

  function notifyIncoming(peerUri) {
    if (!boolSetting("ringNotifications", true)) return
    // Critical urgency so it survives Do Not Disturb -- a missed call is worse
    // than an interruption, and the notification is the only cue when the
    // panel is closed.
    Quickshell.execDetached({
      command: [
        "/usr/bin/notify-send", "-u", "critical", "-a", "Simple SIP",
        "-i", "call-start-symbolic",
        "Incoming call", peerUri || "unknown caller"
      ],
      environment: root.cleanEnv(),
      clearEnvironment: true
    })
  }

  function applyStatus(text) {
    var raw = String(text || "")
    if (raw.length > maxJsonChars) return
    var status
    try {
      status = JSON.parse(raw)
    } catch (e) {
      return
    }
    installed = status.installed === true
    unitActive = status.unitActive === true
    daemonUp = status.daemonUp === true
    configured = status.configured === true
    if (status.aor) aor = String(status.aor)

    // reginfo is authoritative on startup; events take over from there.
    if (status.reginfo && status.reginfo.data !== undefined) {
      registration = Model.parseReginfo(status.reginfo.data, aor)
    } else if (!daemonUp) {
      registration = "unknown"
    }

    // Events carry the truth; this is the resync that repairs what they missed.
    if (status.calls && status.calls.data !== undefined) {
      var incoming = Model.parseIncomingCall(status.calls.data)
      if (incoming && callState !== "incoming") {
        // A call is ringing right now and no CALL_INCOMING ever reached us --
        // the listener was between reconnects. Adopt it: without this the
        // panel offers no Answer for the whole life of the call, and no
        // poll can ever recover it.
        callState = "incoming"
        peer = incoming.peer
        callId = ""
        callStartedAt = 0
        announceIncoming()
      } else if (Model.parseCallCount(status.calls.data) === 0
                 && (callState !== "incoming" || statusRequestedAt > lastCallEventAt)) {
        // A call that ended while the shell was restarting leaves stale UI
        // state. Clearing a ringing call is only safe when this snapshot was
        // asked for after the last call event we saw -- otherwise it is a
        // reply that predates a call which is still coming up.
        callState = "idle"
        peer = ""
        callId = ""
        callStartedAt = 0
      }
    }
  }

  // ----------------------------------------------------------------- process

  // Long-lived: a bar widget is loaded for the whole shell session, so this is
  // the always-on listener that makes an inbound call ring even with the panel
  // closed. `omarchy-sip events` connects to the control socket and prints one
  // bounded, newline-terminated JSON line per record (or nothing at all for an
  // oversized one) -- see read_lines() in the CLI -- so SplitParser here only
  // ever sees data our own bounded reader already produced.
  Process {
    id: eventsProcess
    running: false
    command: []
    clearEnvironment: true
    environment: root.cleanEnv()
    stdinEnabled: false
    stdout: SplitParser { onRead: function(line) { root.handleLine(line) } }
    onRunningChanged: if (running) root.refresh()
    onExited: function(exitCode) {
      root.daemonUp = false
      // Each retry is a Python interpreter start, not a syscall the way the
      // old raw-socket reconnect was, so a daemon that stays down (not
      // installed yet, stopped for troubleshooting) must not keep spawning
      // one every few seconds indefinitely. Back off, capped, and reset the
      // moment a connection actually succeeds -- see the "ctrl" branch above.
      eventsRetryMs = Math.min(eventsRetryMs * 2, eventsRetryMaxMs)
      eventsRestartTimer.interval = eventsRetryMs
      eventsRestartTimer.restart()
    }
  }

  function startEvents() {
    if (eventsProcess.running) return
    eventsProcess.command = [cli, "events"]
    eventsProcess.running = true
  }

  // The socket only exists while the daemon runs, and `events` exits as soon
  // as it does (or immediately, if nothing is listening yet). Retry with
  // backoff rather than hammering a spawn every 3s for as long as it is down.
  Timer {
    id: eventsRestartTimer
    interval: eventsRetryMinMs
    onTriggered: root.startEvents()
  }

  // The one place a whole document is needed, so StdioCollector stays -- but
  // the CLI clamps --limit and clips every field, and the watchdog below bounds
  // how long this can run at all.
  Process {
    id: historyProcess
    running: false
    command: []
    clearEnvironment: true
    environment: root.cleanEnv()
    stdout: StdioCollector { id: historyOut; waitForEnd: true }
    onExited: function(exitCode) {
      historyWatchdog.stop()
      if (exitCode !== 0) return
      var raw = String(historyOut.text || "[]")
      if (raw.length > root.maxJsonChars) return
      try {
        var parsed = JSON.parse(raw)
        root.history = Array.isArray(parsed) ? parsed : []
      } catch (e) {
        root.history = []
      }
    }
  }

  Timer {
    id: historySettleTimer
    interval: 400
    onTriggered: root.refreshHistory()
  }

  Process {
    id: statusProcess
    running: false
    command: []
    clearEnvironment: true
    environment: root.cleanEnv()
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    // No stderr parser: with none set Quickshell discards the stream, which is
    // what we want here -- nothing read it, and collecting it only retained it.
    onExited: function(exitCode) {
      statusWatchdog.stop()
      if (exitCode === 0) root.applyStatus(statusOut.text)
      else root.daemonUp = false
    }
  }

  // Only ever needs an error message, so both streams feed one bounded buffer
  // instead of two StdioCollectors retaining everything the CLI ever printed.
  Process {
    id: actionProcess
    property string errText: ""
    running: false
    command: []
    clearEnvironment: true
    environment: root.cleanEnv()
    stdout: SplitParser {
      onRead: function(line) { actionProcess.errText = root.appendBounded(actionProcess.errText, line) }
    }
    stderr: SplitParser {
      onRead: function(line) { actionProcess.errText = root.appendBounded(actionProcess.errText, line) }
    }
    onExited: function(exitCode) {
      actionWatchdog.stop()
      if (exitCode !== 0) {
        root.lastError = elide(actionProcess.errText || "Command failed")
        // The optimistic dial never happened -- fall back to what is real.
        root.refresh()
      }
    }
  }

  Process {
    id: accountProcess
    property string errText: ""
    running: false
    command: []
    clearEnvironment: true
    environment: root.cleanEnv()
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(line) { accountProcess.errText = root.appendBounded(accountProcess.errText, line) }
    }
    stderr: SplitParser {
      onRead: function(line) { accountProcess.errText = root.appendBounded(accountProcess.errText, line) }
    }
    onExited: function(exitCode) {
      accountWatchdog.stop()
      if (exitCode !== 0) root.lastError = elide(accountProcess.errText || "Could not save account")
      else root.lastError = ""
      accountProcess.stdinEnabled = true
      // The daemon restarts on an account change; give it a moment to register.
      accountSettleTimer.restart()
    }
  }

  function elide(text) {
    var value = String(text || "").replace(/\s+/g, " ").trim()
    return value.length > 160 ? value.substring(0, 157) + "…" : value
  }

  // ------------------------------------------------------------- watchdogs
  //
  // Every finite CLI call gets a whole-process deadline. Setting running to
  // false terminates the child, so a helper wedged on a substituted file or a
  // registrar that never answers cannot hold a slot (or its output buffer)
  // open for the rest of the shell session. The control socket is deliberately
  // exempt: it is the long-lived listener, and is bounded instead by the
  // per-record cap the daemon and handleLine both enforce.
  Timer {
    id: statusWatchdog
    interval: 15000
    onTriggered: if (statusProcess.running) { statusProcess.running = false; root.daemonUp = false }
  }

  Timer {
    id: historyWatchdog
    interval: 10000
    onTriggered: if (historyProcess.running) historyProcess.running = false
  }

  Timer {
    id: actionWatchdog
    interval: 15000
    onTriggered: {
      if (!actionProcess.running) return
      actionProcess.running = false
      root.lastError = "Command timed out"
      root.refresh()
    }
  }

  // An account change restarts the daemon, so this one is allowed to be slower.
  Timer {
    id: accountWatchdog
    interval: 20000
    onTriggered: {
      if (!accountProcess.running) return
      accountProcess.running = false
      root.lastError = "Saving the account timed out"
    }
  }

  Timer {
    id: accountSettleTimer
    interval: 2500
    onTriggered: root.refresh()
  }

  // Cheap safety net: events carry the truth, this catches a daemon that died
  // and came back while nothing was happening.
  Timer {
    interval: root.statusRefreshSec * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: {
    startEvents()
    refresh()
  }
}
