// Harness for Model.js's pure functions.  Run: node tests/model_test.js
// Model.js deliberately holds no QML objects, which is what makes this possible.
const fs = require("fs");
const src = fs.readFileSync(require("path").join(__dirname, "..", "Model.js"), "utf8");
const M = {};
new Function("exports", src + "\nObject.assign(exports,{stripAnsi,classifyEvent,parseReginfo,parseCallCount,parseIncomingCall,normalizeTarget,peerLabel,peerShort,durationText,formatDuration,barGlyph,heroMeta,callTitle,domainOf,historyGlyph,historyLabel,historyIsMissed,historyMeta,relativeTime});")(M);

let fails = 0;
const ESC = String.fromCharCode(27);
const t = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) fails++;
  console.log((ok ? "ok   " : "FAIL ") + name + "  => " + JSON.stringify(got));
};

t("normalize bare ext", M.normalizeTarget("1001", "sip:alex@pbx.example.com"), "sip:1001@pbx.example.com");
t("normalize user@host", M.normalizeTarget("bob@other.net", "sip:a@x.com"), "sip:bob@other.net");
t("normalize full uri", M.normalizeTarget("sip:bob@x.com:5080", "sip:a@y"), "sip:bob@x.com:5080");
t("normalize sips", M.normalizeTarget("sips:b@x", "sip:a@y"), "sips:b@x");
t("normalize spaces", M.normalizeTarget(" 07700 900 123 ", "sip:a@pbx"), "sip:07700900123@pbx");
t("normalize empty", M.normalizeTarget("   ", "sip:a@pbx"), "");
t("normalize no account", M.normalizeTarget("1001", ""), "sip:1001");

t("peerLabel params", M.peerLabel("sip:bob@192.168.22.10:5080;transport=udp"), "bob@192.168.22.10:5080");
t("peerLabel angle", M.peerLabel('"Bob" <sip:bob@x.com>'), "bob@x.com");
t("peerShort", M.peerShort("sip:1001@pbx"), "1001");
t("domainOf", M.domainOf("sip:alex@pbx.example.com"), "pbx.example.com");

t("reginfo OK", M.parseReginfo("\n--- User Agents (1) ---\nsip:a@x.com                OK  sip:x.com\n", "sip:a@x.com"), "registered");
t("reginfo ERR", M.parseReginfo("sip:a@x.com   ERR sip:x.com", "sip:a@x.com"), "failed");
t("reginfo zzz", M.parseReginfo("sip:a@x.com   zzz sip:x.com", "sip:a@x.com"), "pending");
t("reginfo ansi OK", M.parseReginfo("sip:a@x.com   " + ESC + "[32mOK " + ESC + "[;m sip:x.com", "sip:a@x.com"), "registered");
t("reginfo bare-bracket ansi", M.parseReginfo("sip:a@x.com   [32mOK [;m sip:x.com", "sip:a@x.com"), "registered");
t("reginfo no reg client", M.parseReginfo("\n--- User Agents (1) ---\n0 - sip:a@x.com          \n\n", "sip:a@x.com"), "none");
t("reginfo empty", M.parseReginfo("\n--- User Agents (0) ---\n\n", "sip:a@x.com"), "unknown");
t("reginfo expires form", M.parseReginfo("sip:a@x.com   OK  sip:x.com Expires 300s", "sip:a@x.com"), "registered");

t("callcount 2", M.parseCallCount("\n--- Active calls (2) ---\n"), 2);
t("callcount 0", M.parseCallCount("\n(no active calls)\n"), 0);

// listcalls renders one call_debug block per call, headed by that call's state.
const RINGING = [
  "", "User-Agent: 3077@pbx", "--- Active calls (1) ---",
  "  ===== Call debug (INCOMING) =====",
  " local_uri: 3077 <sip:3077@pbx>",
  ' peer_uri:  "Bob" <sip:27126578500@197.234.132.106>',
  " af=AF_INET id=bfe5ab9c6e3ed168",
  " direction: Incoming", "",
].join("\n");
t("incoming from listcalls", M.parseIncomingCall(RINGING), { peer: "27126578500@197.234.132.106" });
t("incoming none when idle", M.parseIncomingCall("\n--- Active calls (0) ---\n"), null);
t("incoming ignores an established call",
  M.parseIncomingCall("--- Active calls (1) ---\n  ===== Call debug (ESTABLISHED) =====\n peer_uri:  <sip:b@x>\n"), null);
t("incoming ignores an outgoing call",
  M.parseIncomingCall("  ===== Call debug (OUTGOING) =====\n peer_uri:  <sip:b@x>\n"), null);
t("incoming takes the ringing call's own peer, not the first in the document",
  M.parseIncomingCall("  ===== Call debug (ESTABLISHED) =====\n peer_uri:  <sip:first@x>\n"
                    + "  ===== Call debug (INCOMING) =====\n peer_uri:  <sip:second@x>\n"),
  { peer: "second@x" });
t("incoming with no peer_uri still reports the ring",
  M.parseIncomingCall("  ===== Call debug (INCOMING) =====\n"), { peer: "" });

t("classify incoming", M.classifyEvent({ type: "CALL_INCOMING", peeruri: "sip:bob@x", id: "a1" }),
  { kind: "call", callState: "incoming", peer: "bob@x", callId: "a1" });
t("classify rtcp ignored", M.classifyEvent({ type: "CALL_RTCP" }), null);
t("classify sdp ignored", M.classifyEvent({ type: "CALL_LOCAL_SDP" }), null);
t("classify closed", M.classifyEvent({ type: "CALL_CLOSED", param: "Rejected by user" }),
  { kind: "call", callState: "idle", peer: "", callId: "", closedReason: "Rejected by user" });
t("classify reg ok", M.classifyEvent({ type: "REGISTER_OK", accountaor: "sip:a@x" }),
  { kind: "registration", registration: "registered", aor: "sip:a@x" });
t("classify ctrl up", M.classifyEvent({ type: "CTRL_CONNECTED" }), { kind: "ctrl", connected: true });

t("duration 95s", M.durationText(1000, 1000 + 95000), "01:35");
t("duration hours", M.durationText(1, 1 + 3725000), "1:02:05");
t("duration unset", M.durationText(0, 5000), "");

t("glyph idle is a phone", M.barGlyph("idle"), "\uf095");
t("glyph in-call is filled", M.barGlyph("active"), "\uf098");
t("glyph ringing is a phone", M.barGlyph("incoming"), "\uf095");
t("hero no daemon", M.heroMeta({ daemonUp: false }), "Daemon stopped");
t("hero no account", M.heroMeta({ daemonUp: true, configured: false }), "No account configured");
t("hero registered", M.heroMeta({ daemonUp: true, configured: true, registration: "registered", aor: "sip:a@x" }), "sip:a@x");

const NOW = 1787900000000;
const mk = (o) => Object.assign({ ts: NOW / 1000, direction: "out", peer: "sip:1001@pbx", missed: false, duration: 0 }, o);
t("hist glyph out", M.historyGlyph(mk({})), "\u2197");
t("hist glyph in", M.historyGlyph(mk({ direction: "in" })), "\u2199");
t("hist label", M.historyLabel(mk({ peer: "sip:1001@pbx.example.com" })), "1001");
t("hist label empty", M.historyLabel(mk({ peer: "" })), "unknown");
t("hist missed", M.historyIsMissed(mk({ missed: true })), true);
t("meta answered", M.historyMeta(mk({ duration: 72 }), NOW), "just now \u00b7 01:12");
t("meta missed", M.historyMeta(mk({ direction: "in", missed: true }), NOW), "just now \u00b7 Missed");
t("meta no answer", M.historyMeta(mk({ duration: 0 }), NOW), "just now \u00b7 No answer");
t("rel just now", M.relativeTime(NOW / 1000, NOW), "just now");
t("rel minutes", M.relativeTime(NOW / 1000 - 300, NOW), "5m ago");
t("rel hours", M.relativeTime(NOW / 1000 - 7200, NOW), "2h ago");
t("rel days", M.relativeTime(NOW / 1000 - 86400 * 3, NOW), "3d ago");
t("rel old is a date", /^\d{1,2} [A-Z][a-z]{2}$/.test(M.relativeTime(NOW / 1000 - 86400 * 30, NOW)), true);
t("rel unset", M.relativeTime(0, NOW), "");
t("fmt duration 0", M.formatDuration(0), "00:00");
t("fmt duration 72", M.formatDuration(72), "01:12");
t("fmt duration 3725", M.formatDuration(3725), "1:02:05");

console.log(fails === 0 ? "\nall passed" : `\n${fails} FAILED`);
process.exit(fails ? 1 : 0);
