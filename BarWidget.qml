import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Bar icon and popup. Display and input only: state and actions live in
// Service.qml, shared by every monitor's bar.
Panel {
  id: root
  moduleName: "io.github.dmatthan.omairplay"
  // Scriptable: omarchy-shell io.github.dmatthan.omairplay open|close|toggle.
  ipcTarget: "io.github.dmatthan.omairplay"

  // The bar sizes slots from the implicit size; Ui/Panel has none.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // A third-party plugin can resolve only its own service.
  readonly property var svc: bar && bar.shell ? bar.shell.serviceFor("io.github.dmatthan.omairplay") : null

  // Services get no settings from the host, so push ours down.
  Binding {
    target: root.svc
    property: "settings"
    value: root.effectiveSettings
    when: root.svc !== null
  }

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Commons.Color.accent) : "transparent"

  readonly property string receiverState: svc ? svc.receiverState : "off"
  readonly property bool showArtwork: effectiveSettings.showArtwork !== false
  readonly property bool trackNotifications: effectiveSettings.trackNotifications !== false
  readonly property bool playingShown: svc !== null && svc.setupComplete
                                       && svc.effectiveRunning && svc.playing

  // Nerd Font glyphs above U+FFFF, written as surrogate pairs so a paste cannot
  // silently truncate them; each comment carries the codepoint.
  readonly property string iconPlaying: "\uDB80\uDD19"  // U+F0119 md-cast-connected
  readonly property string iconIdle:    "\uDB81\uDCC3"  // U+F04C3 md-speaker
  readonly property string iconOff:     "\uDB81\uDCC4"  // U+F04C4 md-speaker-off

  readonly property string icon: {
    switch (receiverState) {
      case "playing": return iconPlaying
      case "idle":    return iconIdle
      // "starting" and "failed" use the off glyph: neither is usable yet.
      default:        return iconOff
    }
  }

  readonly property string tooltipText: {
    if (!svc) return "AirPlay"
    if (!svc.setupComplete) return "AirPlay: not set up"
    if (svc.conflicting) return "AirPlay: another receiver is running"
    if (svc.failed) return "AirPlay: could not start"
    if (svc.activating) return "AirPlay: starting"
    if (svc.actionLabel !== "") return "AirPlay: " + svc.actionLabel.toLowerCase()
    // Name the reason: the tooltip is the only diagnosis while the popup is shut.
    if (!svc.firewallOk)
      return (svc.firewallMissing && svc.firewallMissing.length > 0)
        ? "AirPlay: firewall rules missing" : "AirPlay: firewall blocked"
    if (!svc.effectiveRunning) return "AirPlay: off"
    if (svc.clockSyncDown) return "AirPlay: clock sync service down"
    if (svc.notListening) return "AirPlay: receiver not responding"
    if (svc.audioStalled) return "AirPlay: no audio arriving"
    if (svc.playing && svc.hasTrack)
      return svc.artist !== "" ? (svc.title + " — " + svc.artist) : svc.title
    return "AirPlay: ready as " + svc.advertisedName
  }

  // ------------------------------------------------------- keyboard cursor
  property int cursorIndex: 0
  property bool cursorActive: false
  property string nameDraft: ""

  readonly property var rows: {
    var r = []
    if (!svc) return r
    if (!svc.setupComplete) {
      r.push("setup")
      return r
    }
    r.push("power")
    if (firewallAlert) r.push("fixFirewall")
    if (healthAlert) r.push("fixHealth")
    if (svc.configStale && svc.running) r.push("restart")
    r.push("settings")
    if (settingsOpen) {
      r.push("login")
      r.push("name")
      r.push("notify")
      r.push("artwork")
      r.push("repair")
      r.push("remove")
    }
    return r
  }

  // Settings start collapsed each time the popup opens.
  property bool settingsOpen: false

  function toggleSettings() {
    settingsOpen = !settingsOpen
    if (settingsOpen && cursorActive) cursorIndex = rows.indexOf("login")
  }

  readonly property bool firewallAlert: svc !== null && svc.setupComplete && !svc.firewallOk
  readonly property bool healthAlert: svc !== null && svc.setupComplete && svc.firewallOk
                                      && (svc.clockSyncDown || svc.notListening || svc.audioStalled)

  readonly property string cursorRow: {
    if (!cursorActive || rows.length === 0) return ""
    return rows[Math.max(0, Math.min(cursorIndex, rows.length - 1))]
  }

  function hasCursor(name) { return cursorRow === name }

  function moveCursor(delta) {
    if (rows.length === 0) return
    var next = cursorIndex + delta
    cursorIndex = Math.max(0, Math.min(next, rows.length - 1))
  }

  function activateCursor() {
    switch (cursorRow) {
      case "setup":    svc.runSetup(true); root.close(); break
      case "power":    svc.toggle(); break
      case "fixFirewall":
      case "fixHealth": root.repair(); break
      case "settings": toggleSettings(); break
      case "login":    svc.setStartAtLogin(!svc.startAtLogin); break
      case "name":     nameField.forceActiveFocus(); nameField.selectAll(); break
      case "notify":   toggleSetting("trackNotifications"); break
      case "artwork":  toggleSetting("showArtwork"); break
      case "restart":  svc.restart(); break
      case "repair":   root.repair(); break
      case "remove":   removeConfirm.opened = true; break
    }
  }

  // Hand the keyboard back to the panel, or j/k keep typing into the field.
  function leaveNameField() {
    var i = rows.indexOf("name")
    if (i >= 0) cursorIndex = i
    cursorActive = true
    keyCatcher.forceActiveFocus()
  }

  function revertName() {
    var current = svc ? (svc.advertisedName || svc.speakerName) : ""
    nameDraft = current
    nameField.text = current
  }

  // A rename restarts a running receiver, so ask first if something plays.
  function submitName() {
    if (!svc) return
    var wanted = nameDraft.trim()
    if (wanted === "" || wanted === svc.advertisedName) return
    if (svc.playing) renameConfirm.opened = true
    else commitName()
  }

  function commitName() {
    if (!svc) return
    var wanted = nameDraft.trim().substring(0, 50)
    if (wanted === "") return
    saveSettings({ speakerName: wanted })
    // Hand it over directly: the persisted copy lags a settings reload.
    svc.applyName(wanted, true)
  }

  // ------------------------------------------------------------- settings
  //
  // updateEntryInline replaces our entry with exactly the keys given, so every
  // write sends the full known set. A written value is held until the reload
  // brings `settings` into agreement, or a toggle would flick back.
  readonly property var knownSettings: ["speakerName", "showArtwork", "trackNotifications"]
  property var _pendingSettings: ({})

  readonly property var effectiveSettings: {
    var out = {}
    for (var key in settings) out[key] = settings[key]
    for (var p in _pendingSettings) out[p] = _pendingSettings[p]
    return out
  }

  onSettingsChanged: {
    var left = {}
    for (var key in _pendingSettings)
      if (!settings || settings[key] !== _pendingSettings[key]) left[key] = _pendingSettings[key]
    _pendingSettings = left
  }

  function saveSettings(patch) {
    var pending = {}
    for (var p in _pendingSettings) pending[p] = _pendingSettings[p]
    for (var k in patch) pending[k] = patch[k]
    _pendingSettings = pending
    if (!bar || !bar.shell) return
    var merged = {}
    for (var i = 0; i < knownSettings.length; i++) {
      var key = knownSettings[i]
      if (effectiveSettings[key] !== undefined) merged[key] = effectiveSettings[key]
    }
    bar.shell.updateEntryInline(root.moduleName, merged)
  }

  function toggleSetting(name) {
    saveSettings({ [name]: effectiveSettings[name] === false })
  }

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      cursorIndex = 0
      settingsOpen = false
      var current = svc ? (svc.advertisedName || svc.speakerName) : ""
      nameDraft = current
      nameField.text = current
      if (svc) { svc.refresh(); svc.refreshFirewall() }
    }
  }

  // Follow a rename once it lands, unless the field is being typed in.
  Connections {
    target: root.svc
    function onAdvertisedNameChanged() {
      if (!root.svc || nameField.activeFocus) return
      var current = root.svc.advertisedName
      if (current === "") return
      root.nameDraft = current
      nameField.text = current
    }
  }

  // Repair restarts the receiver, so ask first if something is playing.
  function repair() {
    if (!svc) return
    if (svc.playing) { repairConfirm.opened = true; return }
    svc.runRepair()
    root.close()
  }

  readonly property var openDialog: renameConfirm.opened ? renameConfirm
    : (repairConfirm.opened ? repairConfirm
    : (removeConfirm.opened ? removeConfirm : null))

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    // Dim when off or not set up; urgent on failure or anything Repair fixes.
    foreground: (root.receiverState === "playing" || root.receiverState === "idle")
      ? barForeground : Qt.darker(barForeground, 1.55)
    active: root.svc !== null && (root.svc.failed || root.svc.needsRepair || root.svc.conflicting)
    // WidgetButton shows and hides the tooltip itself from this property.
    tooltipText: root.tooltipText
    onPressed: function(buttonCode) {
      // Right-click flips the receiver, like the network and bluetooth widgets.
      if (buttonCode === Qt.RightButton) {
        if (root.svc && root.svc.setupComplete) root.svc.toggle()
      } else {
        root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    // fittedContentHeight still clamps this to the space the bar leaves.
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the name field has focus, every key belongs to it.
      blocked: nameField.activeFocus

      onMoveRequested: function(dx, dy) {
        if (root.openDialog) {
          root.openDialog.selectedIndex = root.openDialog.selectedIndex === 0 ? 1 : 0
          return
        }
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dy !== 0 ? dy : dx)
      }
      onActivateRequested: {
        if (root.openDialog) {
          if (root.openDialog.selectedIndex === 0) root.openDialog.canceled()
          else root.openDialog.confirmed()
          return
        }
        if (root.cursorActive) root.activateCursor()
      }
      onCloseRequested: {
        if (root.openDialog) { root.openDialog.canceled(); return }
        root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }

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
          spacing: Style.space(9)

          PanelHero {
            id: hero
            width: parent.width
            foreground: root.foreground
            fontFamily: root.fontFamily
            // The speaker's name stays the prominent line; the track has its own block.
            title: root.svc ? (root.svc.advertisedName || root.svc.speakerName) : "AirPlay"
            // Rendered in small caps by PanelHero, so a short label only.
            meta: root.svc ? root.svc.statusText : ""
            // A pill sharing the title row, so anything here squeezes the title out.
            detail: ""
            // A plain Text: OpticalGlyph has no implicit size and collapsed to 0x0.
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.icon
                color: (root.receiverState === "failed"
                        || (root.svc && (root.svc.needsRepair || root.svc.conflicting)))
                  ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                renderType: Text.NativeRendering
              }
            }
            // The on/off switch only makes sense once setup has happened.
            trailingControl: root.svc && root.svc.setupComplete ? powerSwitch : null
          }

          // ---------------------------------------------------- now playing
          NowPlaying {
            width: parent.width
            visible: root.playingShown
            svc: root.svc
            showArtwork: root.showArtwork
            meterActive: root.opened && root.playingShown
            foreground: root.foreground
            accent: Commons.Color.accent
            fontFamily: root.fontFamily
          }

          // A line for the states where there is nothing playing to show.
          // Silent while an alert names the problem.
          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: root.svc !== null && !root.playingShown && text !== ""
            text: {
              if (!root.svc) return ""
              if (!root.svc.setupComplete) return "shairport-sync is not set up yet"
              if (root.svc.failed) return "The receiver could not start"
              if (root.svc.activating) return "Starting up"
              if (!root.svc.effectiveRunning) return "The receiver is off"
              if (root.svc.needsRepair) return ""
              return "Ready - waiting for a device"
            }
            color: root.dim
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Component {
            id: powerSwitch
            ToggleSwitch {
              checked: root.svc ? root.svc.effectiveRunning : false
              busy: root.svc ? root.svc.busy : false
              foreground: root.foreground
              hasCursor: root.hasCursor("power")
              onToggled: if (root.svc) root.svc.toggle()
            }
          }

          // --------------------------------------------------------- alerts
          AlertRow {
            width: parent.width
            visible: root.svc !== null && root.svc.conflicting
            urgent: true
            foreground: root.foreground
            urgentColor: root.urgent
            fontFamily: root.fontFamily
            text: {
              if (!root.svc) return ""
              // Name the exact command that frees the slot.
              if (root.svc.systemUnitBusy)
                return "Another AirPlay receiver is already running on this machine. Turn it off with:\n    sudo systemctl disable --now shairport-sync.service"
              return "Another AirPlay receiver is already running on this machine. Turn it off with:\n    systemctl --user disable --now shairport-sync.service"
            }
          }

          // Discovery passes through ufw but the connection does not, so the phone
          // sees the speaker and then cannot connect.
          AlertRow {
            width: parent.width
            visible: root.firewallAlert
            urgent: false
            foreground: root.foreground
            urgentColor: root.urgent
            fontFamily: root.fontFamily
            actionText: "Repair"
            hasCursor: root.hasCursor("fixFirewall")
            onActionClicked: root.repair()
            text: {
              if (!root.svc) return ""
              // Lead with the count when known: it shows the check ran.
              var n = root.svc.firewallMissing ? root.svc.firewallMissing.length : 0
              var lead = n > 0
                ? (n + (n === 1 ? " firewall rule is" : " firewall rules are") + " missing on this network. ")
                : ""
              return lead + "Your phone sees the speaker but can't play to it."
            }
          }

          // Up, but something it needs is not; only Repair fixes these.
          AlertRow {
            width: parent.width
            visible: root.healthAlert
            urgent: false
            foreground: root.foreground
            urgentColor: root.urgent
            fontFamily: root.fontFamily
            actionText: "Repair"
            hasCursor: root.hasCursor("fixHealth")
            onActionClicked: root.repair()
            text: {
              if (!root.svc) return ""
              if (root.svc.clockSyncDown)
                return "The clock-sync service AirPlay 2 needs is not running."
              if (root.svc.notListening)
                return "The receiver is running but not accepting connections."
              return "The track is showing but no audio is reaching this machine."
            }
          }

          // A config change that has not taken effect yet.
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.svc !== null && root.svc.configStale && root.svc.running

            AlertRow {
              width: parent.width
              urgent: false
              foreground: root.foreground
              urgentColor: root.urgent
              fontFamily: root.fontFamily
              text: "Your changes need a restart to take effect."
            }

            Button {
              width: parent.width
              text: "Restart"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              hasCursor: root.hasCursor("restart")
              onClicked: if (root.svc) root.svc.restart()
            }
          }

          AlertRow {
            width: parent.width
            visible: root.svc !== null && root.svc.lastError !== ""
            urgent: true
            foreground: root.foreground
            urgentColor: root.urgent
            fontFamily: root.fontFamily
            text: root.svc ? root.svc.lastError : ""
          }

          // ---------------------------------------------------- first run
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.svc !== null && !root.svc.setupComplete

            PanelSectionHeader {
              width: parent.width
              text: "Setup"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              wrapMode: Text.WordWrap
              text: "Installs what the receiver needs and opens your firewall to your local network only. Runs in a terminal so you can see each step."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Button {
              width: parent.width
              text: "Run setup"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              hasCursor: root.hasCursor("setup")
              onClicked: { root.svc.runSetup(true); root.close() }
            }
          }

          // ------------------------------------------------------- settings
          SettingsRow {
            width: parent.width
            visible: root.svc !== null && root.svc.setupComplete
            expanded: root.settingsOpen
            foreground: root.foreground
            fontFamily: root.fontFamily
            hasCursor: root.hasCursor("settings")
            onClicked: root.toggleSettings()
          }

          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.svc !== null && root.svc.setupComplete && root.settingsOpen
            opacity: visible ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutQuad } }

            Toggle {
              width: parent.width
              label: "Start at login"
              description: "Bring the receiver up with the session"
              checked: root.svc ? root.svc.startAtLogin : false
              foreground: root.foreground
              fontFamily: root.fontFamily
              hasCursor: root.hasCursor("login")
              onClicked: if (root.svc) root.svc.setStartAtLogin(!root.svc.startAtLogin)
            }

            PanelSectionHeader {
              width: parent.width
              text: "Speaker name"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            // Not a TextField, which reads the clipboard: see NameField.qml.
            NameField {
              id: nameField
              width: parent.width
              // Not bound to nameDraft: seeded on open, so typing never fights a binding.
              foreground: root.foreground
              placeholderText: "Omarchy Speaker"
              fontFamily: root.fontFamily
              hasCursor: root.hasCursor("name")
              // shairport-sync caps the advertised name at 50 characters.
              maximumLength: 50
              onTextChanged: root.nameDraft = text
              // The field takes these keys itself, so the submitting press cannot also
              // confirm the dialog it opens.
              onSubmitted: { root.leaveNameField(); root.submitName() }
              onCancelled: { root.revertName(); root.leaveNameField() }
              onNavigated: function(delta) { root.leaveNameField(); root.moveCursor(delta) }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              wrapMode: Text.WordWrap
              visible: root.svc !== null && root.nameDraft.trim() !== ""
                       && root.nameDraft.trim() !== root.svc.advertisedName
              text: root.svc && root.svc.playing
                ? "Enter to rename, Esc to cancel. Something is playing, so this will interrupt it."
                : "Enter to rename, Esc to cancel."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Toggle {
              width: parent.width
              label: "Track notifications"
              description: "Announce each new song"
              checked: root.trackNotifications
              foreground: root.foreground
              fontFamily: root.fontFamily
              hasCursor: root.hasCursor("notify")
              onClicked: root.toggleSetting("trackNotifications")
            }

            Toggle {
              width: parent.width
              label: "Cover art"
              description: "Show the cover in this popup"
              checked: root.showArtwork
              foreground: root.foreground
              fontFamily: root.fontFamily
              hasCursor: root.hasCursor("artwork")
              onClicked: root.toggleSetting("showArtwork")
            }

            PanelSeparator { width: parent.width; foreground: root.foreground }

            // Repair also sits on any alert it fixes; Uninstall lives only here.
            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                width: (parent.width - parent.spacing) / 2
                text: "Repair"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                hasCursor: root.hasCursor("repair")
                onClicked: root.repair()
              }

              Button {
                width: (parent.width - parent.spacing) / 2
                text: "Uninstall"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                hasCursor: root.hasCursor("remove")
                onClicked: removeConfirm.opened = true
              }
            }
          }
        }
      }

      ConfirmDialog {
        id: renameConfirm
        anchors.fill: parent
        z: 100
        message: "Renaming restarts the receiver, so this will stop what is playing now."
        confirmText: "Rename"
        cancelText: "Cancel"
        fontFamily: root.fontFamily
        onConfirmed: { opened = false; root.commitName() }
        onCanceled: opened = false
      }

      ConfirmDialog {
        id: repairConfirm
        anchors.fill: parent
        z: 100
        message: "Repair reverts the receiver and sets it up again, so this will stop what is playing now."
        confirmText: "Repair"
        cancelText: "Cancel"
        fontFamily: root.fontFamily
        onConfirmed: { opened = false; root.svc.runRepair(); root.close() }
        onCanceled: opened = false
      }

      ConfirmDialog {
        id: removeConfirm
        anchors.fill: parent
        z: 100
        message: "This turns the receiver off and undoes its setup, including the firewall rules. The installed packages are left alone."
        confirmText: "Uninstall"
        cancelText: "Cancel"
        fontFamily: root.fontFamily
        onConfirmed: { opened = false; root.svc.runRemove(); root.close() }
        onCanceled: opened = false
      }
    }
  }
}
