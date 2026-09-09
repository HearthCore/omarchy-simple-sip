import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Simple SIP -- bar widget + panel. One account, one call at a time.
//
// The panel is a view over Service.qml's state; it holds no call state of its
// own. Which controls are on screen is decided entirely by the service:
// no daemon -> Start, no account -> setup form, ringing -> Answer/Reject,
// on a call -> timer + Hang up, otherwise -> dial field.
Panel {
  id: root
  moduleName: "io.github.17xande.simple-sip"
  ipcTarget: "io.github.17xande.simple-sip"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Keyboard cursor over whichever action rows are currently visible.
  property bool cursorActive: false
  property int cursorIndex: 0
  property bool setupOpen: false
  property string dialText: ""

  // A text field owns the keyboard whenever one is on screen, so letter
  // shortcuts (a / d / b) only apply in the states that have no input.
  readonly property bool textInputActive: dialRow.visible || setupForm.visible

  // ...and when the last one leaves the screen, the keyboard has to come back.
  // Nothing else claims it: dialField takes focus when it appears and no one
  // hands it back when it goes, so a call arriving while the panel was already
  // open left Answer on screen with focus stranded on a hidden field -- no
  // 'a', no cursor keys, no Enter. Only reopening the panel recovered it.
  onTextInputActiveChanged: if (!textInputActive && opened) {
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  readonly property var actions: buildActions()
  readonly property var primaryActions: actions.filter(function(a) { return a.section !== "history" })
  readonly property var historyActions: actions.filter(function(a) { return a.section === "history" })

  // Cursor indices are assigned here, once, so the two Repeaters below can
  // render different sections while sharing a single keyboard cursor.
  function buildActions() {
    var built = buildRows()
    for (var i = 0; i < built.length; i++) {
      built[i].index = i
      if (!built[i].section) built[i].section = "primary"
    }
    return built
  }

  function buildRows() {
    if (!sip.daemonUp) return [{ id: "start", label: "Start SIP daemon", glyph: "\uf04b" }]
    if (setupForm.visible) return []
    if (sip.callState === "incoming") return [
      { id: "answer", label: "Answer", glyph: "\uf095" },
      { id: "reject", label: "Reject", glyph: "\uf00d" }
    ]
    if (sip.onCall) return [{ id: "hangup", label: "Hang up", glyph: "\uf00d" }]
    var rows = [{ id: "setup", label: "Account settings", glyph: "\uf013", section: "primary" }]
    // Recent calls are actions too: they share the cursor model, so Enter on a
    // row redials it and the keyboard behaves the same everywhere.
    for (var i = 0; i < sip.history.length; i++) {
      var entry = sip.history[i]
      rows.push({
        id: "redial:" + (entry.peer || ""),
        label: Model.historyLabel(entry),
        glyph: Model.historyGlyph(entry),
        meta: Model.historyMeta(entry, clock.now),
        urgent: Model.historyIsMissed(entry),
        section: "history"
      })
    }
    return rows
  }

  function activate(id) {
    switch (id) {
    case "start":  sip.startDaemon(); break
    case "answer": sip.answer(); break
    case "reject": sip.hangup(); break
    case "hangup": sip.hangup(); break
    case "setup":  setupOpen = true; break
    default:
      if (id.indexOf("redial:") === 0) sip.dial(id.substring(7))
    }
  }

  function moveCursor(dy) {
    cursorActive = true
    if (actions.length === 0) return
    cursorIndex = Math.max(0, Math.min(actions.length - 1, cursorIndex + dy))
  }

  function close() {
    root.controller.hide()
    setupOpen = false
  }

  function placeCall() {
    if (dialText.trim() === "") return
    sip.dial(dialText)
    dialText = ""
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursorIndex = 0
    if (panelFlick) panelFlick.contentY = 0
    // The clock only ticks during a call, so stamp it on open to keep the
    // call log's relative times honest.
    clock.now = Date.now()
    sip.refresh()
    Qt.callLater(function() {
      if (dialField.visible) dialField.forceActiveFocus()
      else keyCatcher.forceActiveFocus()
    })
  }

  Service {
    id: sip
    settings: root.settings

    // Ringing is the one thing worth interrupting for: surface the panel so
    // Answer is one click away rather than buried behind the bar icon.
    onIncomingCall: function(peerUri) {
      if (sip.boolSetting("autoOpenOnIncoming", true) && !root.opened) root.open()
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function dial(uri: string): string { sip.dial(uri); return "ok" }
    function answer(): string { sip.answer(); return "ok" }
    function hangup(): string { sip.hangup(); return "ok" }
    function status(): string {
      return sip.callState + " " + (sip.peer || "-") + " " + sip.registration
    }
  }

  // ------------------------------------------------------------- bar button

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        Text {
          textFormat: Text.PlainText
          anchors.centerIn: parent
          text: Model.barGlyph(sip.callState)
          color: sip.ringing ? (root.bar ? root.bar.urgent : Color.urgent)
                             : (sip.onCall || sip.ready ? root.barForeground
                                                        : Qt.darker(root.barForeground, 1.55))
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon

          // Only while ringing -- a permanently animated bar icon is noise.
          SequentialAnimation on opacity {
            running: sip.ringing
            loops: Animation.Infinite
            NumberAnimation { to: 0.35; duration: 500; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 1.0; duration: 500; easing.type: Easing.InOutQuad }
          }
          onVisibleChanged: if (!sip.ringing) opacity = 1.0
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton && sip.callState === "incoming") sip.answer()
      else if (buttonCode === Qt.RightButton && sip.onCall) sip.hangup()
      else root.toggle()
    }
  }

  // ------------------------------------------------------------------ panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Freeze cursor navigation while a text field is on screen so typing an
      // extension does not trigger shortcuts.
      blocked: root.textInputActive

      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: {
        if (root.cursorActive && root.actions.length > 0) {
          root.activate(root.actions[Math.min(root.cursorIndex, root.actions.length - 1)].id)
        }
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var key = String(t || "").toLowerCase()
        if (key === "a" && sip.callState === "incoming") sip.answer()
        else if ((key === "d" || key === "r") && sip.callState === "incoming") sip.hangup()
        else if ((key === "b" || key === "h") && sip.onCall) sip.hangup()
        else if (key === "s") root.setupOpen = !root.setupOpen
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- hero ----------
          PanelHero {
            id: hero
            width: parent.width
            title: "SIP"
            meta: Model.heroMeta(sip.snapshot)
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: sip.ready || sip.onCall ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: Model.barGlyph(sip.callState)
                color: sip.ringing ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // ---------- error / last outcome ----------
          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            text: sip.lastError !== "" ? sip.lastError
                                       : (sip.callState === "idle" && sip.lastClosedReason !== ""
                                          ? "Last call: " + sip.lastClosedReason : "")
            color: sip.lastError !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ---------- live call ----------
          Column {
            id: callBlock
            visible: sip.onCall || sip.callState === "incoming"
            width: parent.width
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: Model.callTitle(sip.snapshot)
              color: sip.ringing ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: Model.peerShort(sip.peer) || "unknown"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: text !== ""
              text: {
                var full = Model.peerLabel(sip.peer)
                var short = Model.peerShort(sip.peer)
                return full !== short ? full : ""
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: sip.callState === "active"
              text: Model.durationText(sip.callStartedAt, clock.now)
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          // ---------- dial ----------
          RowLayout {
            id: dialRow
            visible: sip.daemonUp && sip.configured && !sip.onCall
                     && sip.callState !== "incoming" && !setupForm.visible
            width: parent.width
            spacing: Style.space(6)

            TextField {
              id: dialField
              Layout.fillWidth: true
              placeholderText: "Extension or sip:user@host"
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              text: root.dialText
              enabled: !sip.busy

              onTextChanged: if (text !== root.dialText) root.dialText = text
              onAccepted: root.placeCall()
              Keys.onEscapePressed: root.close()
              onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)
            }

            PanelActionButton {
              iconText: "\uf095"
              tooltipText: "Call"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: root.dialText.trim() !== "" && !sip.busy
              Layout.alignment: Qt.AlignVCenter
              onClicked: root.placeCall()
            }
          }

          // ---------- action rows ----------
          Column {
            id: actionColumn
            visible: root.primaryActions.length > 0
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.primaryActions
              ActionRow {
                required property var modelData
                width: actionColumn.width
                action: modelData
              }
            }
          }

          // ---------- call log ----------
          PanelSectionHeader {
            visible: root.historyActions.length > 0
            text: "RECENT CALLS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Column {
            id: historyColumn
            visible: root.historyActions.length > 0
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.historyActions
              ActionRow {
                required property var modelData
                width: historyColumn.width
                action: modelData
              }
            }
          }

          // ---------- account setup ----------
          PanelSeparator {
            visible: setupForm.visible
            foreground: root.foreground
          }

          Column {
            id: setupForm
            visible: sip.daemonUp && (!sip.configured || root.setupOpen)
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: sip.configured ? "CHANGE ACCOUNT" : "SET UP ACCOUNT"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Credentials are written to ~/.config/omarchy-sip/accounts (0600)."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            TextField {
              id: uriField
              width: parent.width
              placeholderText: "sip:you@pbx.example.com"
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              Keys.onEscapePressed: root.setupOpen = false
            }

            TextField {
              id: authField
              width: parent.width
              placeholderText: "Auth username (optional)"
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              Keys.onEscapePressed: root.setupOpen = false
            }

            TextField {
              id: passwordField
              width: parent.width
              placeholderText: "Password"
              password: true
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              onAccepted: root.saveAccount()
              Keys.onEscapePressed: root.setupOpen = false
            }

            Dropdown {
              id: transportField
              width: parent.width
              label: "Transport"
              value: "udp"
              options: ["udp", "tcp", "tls"]
              foreground: root.foreground
              fontFamily: root.fontFamily
              onChanged: function(v) { transportField.value = v }
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(6)

              Button {
                text: "Save"
                enabled: uriField.text.trim() !== ""
                onClicked: root.saveAccount()
              }

              Button {
                text: "Cancel"
                visible: sip.configured
                onClicked: root.setupOpen = false
              }
            }
          }
        }
      }
    }
  }

  function saveAccount() {
    var uri = uriField.text.trim()
    if (uri === "") return
    if (uri.indexOf("sip:") !== 0) uri = "sip:" + uri
    // A save already in flight refuses this one; keep the form (and the typed
    // password) on screen rather than silently dropping it.
    if (!sip.setAccount(uri, authField.text.trim(), "", transportField.value, passwordField.text))
      return
    // Never keep the password in a live QML property.
    passwordField.text = ""
    setupOpen = false
  }

  // Drives the in-call timer; stopped otherwise so an idle panel costs nothing.
  Timer {
    id: clock
    property double now: Date.now()
    interval: 1000
    running: root.opened && sip.callState === "active"
    repeat: true
    onTriggered: now = Date.now()
    onRunningChanged: if (running) now = Date.now()
  }

  component ActionRow: CursorSurface {
    id: actionRow
    property var action: null
    readonly property int rowIndex: action && action.index !== undefined ? action.index : -1

    hasCursor: root.cursorActive && root.cursorIndex === rowIndex
    foreground: root.foreground
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    // Destructive actions and missed calls carry the urgent colour; everything
    // else is plain foreground.
    readonly property color tint: {
      if (!action) return root.foreground
      if (action.id === "reject" || action.id === "hangup" || action.urgent) return root.urgent
      return root.foreground
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: {
        root.cursorActive = true
        root.cursorIndex = actionRow.rowIndex
      }
      onClicked: root.activate(actionRow.action.id)
    }

    RowLayout {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: actionRow.action ? actionRow.action.glyph : ""
        color: actionRow.tint
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: actionRow.action ? actionRow.action.label : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          visible: text !== ""
          text: actionRow.action && actionRow.action.meta ? actionRow.action.meta : ""
          color: actionRow.action && actionRow.action.urgent ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}
