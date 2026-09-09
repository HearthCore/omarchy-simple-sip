// Pure helpers for the Simple SIP panel. No I/O, no QML objects -- everything
// here is a function of its arguments so it can be reasoned about (and, if it
// ever matters, tested) on its own.
//
// Two inputs arrive from `omarchy-sip`:
//   * event lines  -- baresip's own JSON, one object per line (structured)
//   * status/cmd   -- responses whose `data` field is human prose (unstructured)
// classifyEvent() handles the first; parseReginfo() / parseCallCount() do the
// prose-scraping for the second, so that mess lives in exactly one place.

// baresip colours some status text (print_scode emits green "OK ", red "ERR"),
// and those escapes survive into the ctrl_tcp response.
function stripAnsi(text) {
  return String(text || "").replace(/\x1b\[[0-9;]*[A-Za-z]|\[[0-9;]*m/g, "")
}

// ------------------------------------------------------------------- events

// Map a baresip event object onto the panel's vocabulary. Returns null for
// events the panel does not model (RTCP ticks, SDP exchanges, module noise),
// which keeps the caller free of a long switch.
function classifyEvent(ev) {
  var type = String((ev && ev.type) || "")
  var peer = peerLabel((ev && ev.peeruri) || "")

  switch (type) {
  // -- our own synthetic bridge events
  case "CTRL_CONNECTED":
    return { kind: "ctrl", connected: true }
  case "CTRL_DISCONNECTED":
  case "CTRL_FAILED":
    return { kind: "ctrl", connected: false, error: (ev && ev.reason) || "" }

  // -- registration
  case "REGISTERING":
    return { kind: "registration", registration: "pending" }
  case "REGISTER_OK":
    return { kind: "registration", registration: "registered", aor: (ev && ev.accountaor) || "" }
  case "REGISTER_FAIL":
    return { kind: "registration", registration: "failed", error: (ev && ev.param) || "Registration failed" }
  case "UNREGISTERING":
    return { kind: "registration", registration: "none" }

  // -- calls. `id` lets us ignore events for a call we are not showing.
  case "CALL_INCOMING":
    return { kind: "call", callState: "incoming", peer: peer, callId: (ev && ev.id) || "" }
  case "CALL_OUTGOING":
    return { kind: "call", callState: "outgoing", peer: peer, callId: (ev && ev.id) || "" }
  case "CALL_RINGING":
    return { kind: "call", callState: "ringing", peer: peer, callId: (ev && ev.id) || "" }
  case "CALL_ESTABLISHED":
    return { kind: "call", callState: "active", peer: peer, callId: (ev && ev.id) || "", started: true }
  case "CALL_CLOSED":
    return { kind: "call", callState: "idle", peer: "", callId: "",
             closedReason: String((ev && ev.param) || "") }
  }
  return null
}

// ------------------------------------------------------- prose from responses

// `reginfo` prints one line per account: the AOR padded to 42 columns, then
// per-registration " OK  <server>" / " ERR <server>" / " zzz <server>".
// An account with regint=0 has no registration client and so prints nothing,
// which is "none" rather than a failure.
function parseReginfo(data, aor) {
  var text = stripAnsi(data)
  var lines = text.split("\n")
  var wanted = String(aor || "")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.indexOf("sip:") < 0) continue
    if (wanted && line.indexOf(wanted) < 0) continue
    if (/\bOK\b/.test(line)) return "registered"
    if (/\bERR\b/.test(line)) return "failed"
    if (/\bzzz\b/.test(line)) return "pending"
    return "none"
  }
  return "unknown"
}

function parseCallCount(data) {
  var match = stripAnsi(data).match(/Active calls \((\d+)\)/)
  return match ? parseInt(match[1], 10) : 0
}

// `listcalls` renders one call_debug block per call, headed by the call's own
// state -- "===== Call debug (INCOMING) =====" for a call that is ringing and
// has not been answered. Events are still the normal way the panel learns a
// call is ringing; this is how a resync recovers one whose event it missed,
// so it returns the peer too (from the block's own peer_uri line, not the
// first one in the document, which may belong to another call).
// Returns null when nothing is ringing.
function parseIncomingCall(data) {
  var blocks = stripAnsi(data).split("===== Call debug (")
  for (var i = 1; i < blocks.length; i++) {
    var block = blocks[i]
    var close = block.indexOf(")")
    if (close < 0) continue
    if (block.substring(0, close).trim() !== "INCOMING") continue
    var match = block.match(/peer_uri:\s*(.*)/)
    return { peer: match ? peerLabel(match[1]) : "" }
  }
  return null
}

// ------------------------------------------------------------------ dialling

// Accept what a person would actually type. A bare extension or phone number
// is completed with the account's domain; anything already URI-shaped is left
// alone so `sips:` and explicit ports survive untouched.
function normalizeTarget(input, aor) {
  var target = String(input || "").trim().replace(/\s+/g, "")
  if (target === "") return ""
  if (/^sips?:/.test(target)) return target
  if (target.indexOf("@") > 0) return "sip:" + target

  var domain = domainOf(aor)
  if (!domain) return "sip:" + target
  return "sip:" + target + "@" + domain
}

function domainOf(aor) {
  var value = String(aor || "").replace(/^sips?:/, "")
  var at = value.indexOf("@")
  if (at < 0) return ""
  return value.substring(at + 1).split(";")[0]
}

// "sip:1001@pbx.example.com;transport=tcp" -> "1001@pbx.example.com"
function peerLabel(uri) {
  var value = String(uri || "").trim()
  if (value === "") return ""
  value = value.replace(/^[^<]*</, "").replace(/>.*$/, "")
  value = value.replace(/^sips?:/, "").split(";")[0]
  return value
}

// Just the user part, for the big line in the panel.
function peerShort(uri) {
  var label = peerLabel(uri)
  var at = label.indexOf("@")
  return at > 0 ? label.substring(0, at) : label
}

// ------------------------------------------------------------- presentation

// Live timer: empty until a call actually starts.
function durationText(startedAtMs, nowMs) {
  if (!startedAtMs) return ""
  return formatDuration(Math.floor((nowMs - startedAtMs) / 1000))
}

// mm:ss, or h:mm:ss past the hour.
function formatDuration(totalSeconds) {
  var total = Math.max(0, Math.floor(Number(totalSeconds) || 0))
  var minutes = Math.floor(total / 60)
  var seconds = total % 60
  if (minutes >= 60) {
    var hours = Math.floor(minutes / 60)
    return hours + ":" + pad2(minutes % 60) + ":" + pad2(seconds)
  }
  return pad2(minutes) + ":" + pad2(seconds)
}

function pad2(n) {
  return n < 10 ? "0" + n : String(n)
}

function isRinging(callState) {
  return callState === "incoming"
}

function inCall(callState) {
  return callState === "active" || callState === "outgoing" || callState === "ringing"
}

// Telephone glyphs from the Nerd Font FontAwesome range -- the bold handset
// stays legible at bar size, where the thinner Material phone variants blur
// together. State is carried by colour and the ringing blink, not by shape,
// except for in-call which gets the filled square so a glance tells you the
// line is busy.
function barGlyph(callState) {
  if (callState === "active") return "\uf098"   // nf-fa-phone_square
  return "\uf095"                             // nf-fa-phone
}

// ---------------------------------------------------------------- call log

// Direction arrows rather than phone glyphs: they read at row size and say
// "out" / "in" without colour. A missed call keeps the inbound arrow (it was
// an inbound call) and is distinguished by the urgent tint plus its meta text,
// so the meaning does not rest on colour alone.
function historyGlyph(entry) {
  return (entry && entry.direction === "out") ? "↗" : "↙"
}

function historyIsMissed(entry) {
  return !!(entry && entry.missed)
}

function historyLabel(entry) {
  return peerShort((entry && entry.peer) || "") || "unknown"
}

// "3m ago · 01:12" / "just now · Missed" / "2d ago · No answer"
function historyMeta(entry, nowMs) {
  var e = entry || {}
  var when = relativeTime(e.ts, nowMs)
  var what
  if (e.missed) what = "Missed"
  else if (!e.duration) what = "No answer"
  else what = formatDuration(e.duration)
  return when + " · " + what
}

// Coarse on purpose: a call log wants "when-ish", not a timestamp.
function relativeTime(tsSeconds, nowMs) {
  var ts = Number(tsSeconds || 0)
  if (!ts) return ""
  var seconds = Math.max(0, Math.floor((nowMs - ts * 1000) / 1000))
  if (seconds < 45) return "just now"
  var minutes = Math.floor(seconds / 60)
  if (minutes < 60) return Math.max(1, minutes) + "m ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h ago"
  var days = Math.floor(hours / 24)
  if (days < 7) return days + "d ago"
  // Deliberately not Qt.locale(): keeping this file free of QML globals is
  // what lets the whole module be exercised from plain node.
  var d = new Date(ts * 1000)
  var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  return d.getDate() + " " + months[d.getMonth()]
}

function heroMeta(state) {
  var s = state || {}
  if (!s.daemonUp) return "Daemon stopped"
  if (!s.configured) return "No account configured"
  switch (s.registration) {
  case "registered": return s.aor
  case "pending":    return "Registering…"
  case "failed":     return s.lastError || "Registration failed"
  case "none":       return s.aor + " · not registering"
  }
  return s.aor || "Starting…"
}

function callTitle(state) {
  var s = state || {}
  switch (s.callState) {
  case "incoming": return "Incoming call"
  case "outgoing": return "Calling…"
  case "ringing":  return "Ringing…"
  case "active":   return "In call"
  }
  return ""
}
