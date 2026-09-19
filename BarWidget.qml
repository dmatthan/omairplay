import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui

// Bar icon plus popup for the AirPlay receiver. Display and input only: every
// piece of state and every action lives in Service.qml, so one receiver is
// shared by however many monitors the bar is drawn on.
Panel {
  id: root
  moduleName: "io.github.dmatthan.omairplay"
  // Register our own IPC target so the popup is scriptable:
  //   omarchy-shell io.github.dmatthan.omairplay toggle
  // The host does not register one for a third-party bar widget, so unlike the
  // first-party panels this keeps manageIpc at its default of true and lets
  // Ui/Panel's own IpcHandler own the target.
  ipcTarget: "io.github.dmatthan.omairplay"

  // The bar sizes each slot from its item's implicit size
  // (Bar.qml reads slot.activeItem.implicitWidth), and Ui/Panel is a plain
  // Item with no implicit size of its own. Without these the widget loads
  // cleanly, reports zero width, and is simply never visible -- which is
  // exactly what happened the first time. Every first-party bar widget does
  // the same thing.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Our own service. A third-party plugin gets a capability-scoped facade
  // whose serviceFor() resolves only its own id (shell.qml pluginOwnsTarget),
  // which is exactly what we need. firstPartyServiceFor() returns null for an
  // ordinary third-party plugin, so omarchy.media's live data is off limits --
  // Service.qml reads MPRIS itself instead.
  readonly property var svc: bar && bar.shell ? bar.shell.serviceFor("io.github.dmatthan.omairplay") : null

  // The host hands a bar widget its inline shell.json entry but hands a
  // service nothing, so push ours down and let the service own the parsing.
  Binding {
    target: root.svc
    property: "settings"
    value: root.settings
    when: root.svc !== null
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"

  readonly property string receiverState: svc ? svc.receiverState : "off"
  readonly property bool showArtwork: setting("showArtwork", true) !== false

  // Nerd Font glyphs, each confirmed present in JetBrainsMono Nerd Font by
  // checking the font's charset with fc-query. Written as explicit UTF-16
  // surrogate pairs rather than pasted literally: these live in a Private Use
  // *plane* above U+FFFF, and a literal paste is easy to truncate silently
  // into the wrong glyph. The comment carries the real codepoint.
  readonly property string iconPlaying: "\uDB80\uDD19"  // U+F0119 md-cast-connected
  readonly property string iconIdle:    "\uDB81\uDCC3"  // U+F04C3 md-speaker
  readonly property string iconOff:     "\uDB81\uDCC4"  // U+F04C4 md-speaker-off

  readonly property string icon: {
    switch (receiverState) {
      case "playing": return iconPlaying
      case "idle":    return iconIdle
      // "starting" and "failed" both fall through to the off glyph: neither is
      // usable yet, and claiming otherwise is how this was wrong before.
      default:        return iconOff
    }
  }

  readonly property color barIconColor: {
    if (receiverState === "failed") return root.urgent
    if (receiverState === "playing" || receiverState === "idle") return barForeground
    return Qt.darker(barForeground, 1.55)
  }

  readonly property string tooltipText: {
    if (!svc) return "AirPlay"
    if (!svc.setupComplete) return "AirPlay: not set up"
    if (svc.failed) return "AirPlay: could not start"
    if (svc.activating) return "AirPlay: starting"
    if (svc.actionLabel !== "") return "AirPlay: " + svc.actionLabel.toLowerCase()
    if (!svc.effectiveRunning) return "AirPlay: off"
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
    r.push("login")
    r.push("name")
    if (svc.configStale && svc.running) r.push("restart")
    if (!svc.firewallOk) r.push("firewall")
    r.push("repair")
    r.push("remove")
    return r
  }

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
      case "login":    svc.setStartAtLogin(!svc.startAtLogin); break
      case "name":     nameField.forceActiveFocus(); nameField.selectAll(); break
      case "restart":  svc.restart(); break
      case "firewall": root.repair(); break
      case "repair":   root.repair(); break
      case "remove":   removeConfirm.opened = true; break
    }
  }

  // Hand the keyboard back to the panel. The key catcher is blocked while the
  // field has focus, so without this j/k keep typing into the field after
  // Enter, and the rename confirmation cannot be answered from the keyboard.
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

  // Changing the name rewrites the config, and the receiver only reads its
  // config at startup -- so a running receiver has to restart, which drops
  // whatever is playing. Ask first in that case rather than doing it and
  // explaining afterwards.
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
    // Persist into our own shell.json entry, or the new name is forgotten the
    // moment the widget reloads. updateEntryInline is scoped to our own id by
    // the host (shell.qml _updateSettings -> pluginOwnsTarget), which is all
    // we need. Without this the field reverted on reopen.
    //
    // Send every setting, not just the changed one: updateEntryInline
    // *replaces* the entry with {id} plus exactly the keys it is given
    // (shell.qml:1092), so passing only speakerName would quietly drop
    // refreshIntervalSec and showArtwork back to their defaults.
    if (bar && bar.shell) {
      var merged = {}
      for (var key in root.settings)
        if (key !== "id") merged[key] = root.settings[key]
      merged.speakerName = wanted
      bar.shell.updateEntryInline(root.moduleName, merged)
    }
    // And hand it to the service directly rather than waiting for that write
    // to come back round through the config reload -- otherwise the config
    // gets rewritten with the previous name.
    svc.applyName(wanted, true)
  }

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      cursorIndex = 0
      var current = svc ? (svc.advertisedName || svc.speakerName) : ""
      nameDraft = current
      nameField.text = current
      if (svc) { svc.refresh(); svc.refreshFirewall() }
    }
  }

  // Once a rename actually takes effect the receiver reports its new name, so
  // follow it -- unless the field is being typed in right now.
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

  // Reverts and reinstalls the receiver, which is the fix for the states the
  // popup cannot repair in place -- firewall rules for an address the machine
  // no longer has, a wedged receiver, ownership of nqptp. It restarts the
  // receiver as part of the round trip, so ask first when something is playing.
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
    // WidgetButton shows and hides the tooltip itself from this property.
    tooltipText: root.tooltipText
    onPressed: function(buttonCode) {
      // Right-click flips the receiver without opening anything, matching how
      // the first-party network and bluetooth widgets behave.
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
    // Was Style.space(560), which cut the bottom off and forced a small
    // scroll for no good reason. fittedContentHeight still clamps to the space
    // the bar actually leaves, so a taller cap costs nothing on a short screen.
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the name field has focus every letter belongs to it, or typing a
      // speaker name would drive the cursor instead.
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
            // The speaker's own name stays the prominent line: it is the
            // stable identity of the thing this popup controls, and it is what
            // Daniel looks for on the phone. The track gets its own block
            // below, where it can be long and wrap.
            title: root.svc ? (root.svc.advertisedName || root.svc.speakerName) : "AirPlay"
            // Rendered in small caps by PanelHero, so a short label only.
            meta: root.svc ? root.svc.statusText : ""
            // `detail` is a pill sharing one row with the title, so anything
            // long here squeezes the title out entirely. Left empty.
            detail: ""
            // A plain Text, not an OpticalGlyph. OpticalGlyph is an Item with
            // no implicit size and its glyph is anchors.centerIn: parent, so
            // used here it collapsed to 0x0 and drew the icon centred on a
            // zero-size box -- which is why half of it was cut off. PanelHero
            // sizes its icon slot from the component's implicit size, so the
            // component has to have one. Text gets that from font metrics.
            // (The bar button still benefits from OpticalGlyph's optical
            // centring, where lining up with neighbouring glyphs matters;
            // BarIconButton handles that itself.)
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.icon
                color: root.receiverState === "failed" ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                renderType: Text.NativeRendering
              }
            }
            // The on/off switch only makes sense once setup has happened.
            trailingControl: root.svc && root.svc.setupComplete ? powerSwitch : null
          }

          // ---------------------------------------------------- now playing
          Column {
            width: parent.width
            spacing: Style.space(2)
            visible: root.svc !== null && root.svc.setupComplete && root.svc.effectiveRunning
                     && root.svc.playing && root.svc.hasTrack

            Text {
              width: parent.width
              text: root.svc ? root.svc.title : ""
              color: root.foreground
              wrapMode: Text.WordWrap
              maximumLineCount: 2
              elide: Text.ElideRight
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }

            Text {
              width: parent.width
              visible: text !== ""
              text: {
                if (!root.svc) return ""
                var bits = []
                if (root.svc.artist !== "") bits.push(root.svc.artist)
                if (root.svc.album !== "" && root.svc.album !== root.svc.title)
                  bits.push(root.svc.album)
                return bits.join("  \u00b7  ")
              }
              color: root.dim
              wrapMode: Text.WordWrap
              maximumLineCount: 2
              elide: Text.ElideRight
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // A line for the states where there is nothing playing to show.
          Text {
            width: parent.width
            visible: root.svc !== null && !(root.svc.setupComplete && root.svc.effectiveRunning
                     && root.svc.playing && root.svc.hasTrack)
            text: {
              if (!root.svc) return ""
              if (!root.svc.setupComplete) return "shairport-sync is not set up yet"
              if (root.svc.failed) return "The receiver could not start"
              if (root.svc.activating) return "Starting up"
              if (!root.svc.effectiveRunning) return "The receiver is off"
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

          // ------------------------------------------------------ cover art
          Item {
            width: parent.width
            visible: root.showArtwork && root.svc !== null && root.svc.setupComplete
                     && root.svc.effectiveRunning && root.svc.playing && root.svc.artUrl !== ""
            implicitHeight: visible ? Style.space(132) : 0

            Image {
              id: art
              anchors.centerIn: parent
              width: Math.min(parent.width, Style.space(132))
              height: width
              source: root.svc && root.svc.artUrl !== "" ? root.svc.artUrl : ""
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              cache: false
              smooth: true
              // shairport-sync writes the art into the cache directory the
              // generated config names, under $HOME, so this is a plain
              // file:// read with nothing to fetch over the network.
              onStatusChanged: if (status === Image.Error) visible = false
            }
          }

          // The phone's volume, which is readable but not settable from here.
          Text {
            width: parent.width
            visible: root.svc !== null && root.svc.setupComplete && root.svc.effectiveRunning
                     && root.svc.playing && root.svc.senderVolume >= 0
            text: "Device volume " + Math.round((root.svc ? root.svc.senderVolume : 0) * 100) + "%"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }

          // A small aesthetic flourish, driven by the receiver's real output
          // level. Alive only while this popup is open -- see LevelMeter.qml.
          LevelMeter {
            width: parent.width
            active: root.opened && root.svc !== null && root.svc.setupComplete
                    && root.svc.effectiveRunning && root.svc.playing
            foreground: root.foreground
            accent: Color.accent
          }

          // --------------------------------------------------------- alerts
          //
          // Safety rule 4: another shairport-sync holding the AirPlay 2 slot
          // is the sort of thing that makes this plugin look broken, so name
          // it instead of leaving Daniel to guess.
          AlertRow {
            width: parent.width
            visible: root.svc !== null && root.svc.conflicting
            urgent: true
            foreground: root.foreground
            urgentColor: root.urgent
            fontFamily: root.fontFamily
            text: {
              if (!root.svc) return ""
              // Another shairport-sync is holding the one AirPlay slot this
              // machine has. Name the fix; the reasoning lives in NOTES.md.
              if (root.svc.systemUnitBusy)
                return "Another AirPlay receiver is already running on this machine. Turn it off with:\n    sudo systemctl disable --now shairport-sync.service"
              return "Another AirPlay receiver is already running on this machine. Turn it off with:\n    systemctl --user disable --now shairport-sync.service"
            }
          }

          // The firewall trap: discovery passes through ufw, so the phone sees
          // the speaker and then cannot connect. This reads the real rules
          // rather than a marker file, so it also catches the IPv6 prefix
          // changing underneath us.
          AlertRow {
            width: parent.width
            visible: root.svc !== null && root.svc.setupComplete && !root.svc.firewallOk
            urgent: false
            foreground: root.foreground
            urgentColor: root.urgent
            fontFamily: root.fontFamily
            text: {
              if (!root.svc) return ""
              // Discovery passes through ufw but the connection does not, so
              // the speaker shows up on the phone and then refuses to connect.
              // Lead with the count when the checker has it: "3 rules missing"
              // is more trustworthy than a generic sentence, and it tells the
              // user the check actually ran. Point at Repair rather than at
              // re-running setup, which has no action of its own in the popup.
              var n = root.svc.firewallMissing ? root.svc.firewallMissing.length : 0
              var lead = n > 0
                ? (n + (n === 1 ? " firewall rule is" : " firewall rules are") + " missing for your current network. ")
                : ""
              return lead + "Your phone may see this speaker but won't play through it. Press Repair below to fix it."
            }
          }

          // A config change that has not taken effect yet. This is the state
          // that made renaming look broken: the popup said one name while the
          // receiver kept broadcasting another.
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
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.svc !== null && root.svc.setupComplete

            PanelSeparator { width: parent.width; foreground: root.foreground }

            PanelSectionHeader {
              width: parent.width
              text: "Receiver"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

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

            TextField {
              id: nameField
              width: parent.width
              // Deliberately not bound to nameDraft: the value is seeded when
              // the popup opens and after a rename lands, so that typing is
              // never fighting a binding for the field's contents.
              foreground: root.foreground
              placeholderText: "Omarchy Speaker"
              // TextField sets font.family itself; follow the bar's font
              // rather than the global default so themes carry through.
              font.family: root.fontFamily
              hasCursor: root.hasCursor("name")
              // shairport-sync caps the advertised name at 50 characters, so
              // stop at the limit rather than silently truncating later.
              maximumLength: 50
              onTextChanged: root.nameDraft = text
              // Handled here and accepted, not in onAccepted: TextInput passes
              // Return on to its parents after emitting accepted, and once focus
              // has moved the panel would take that same press as confirming
              // the rename dialog it just opened.
              Keys.onReturnPressed: function(event) {
                event.accepted = true; root.leaveNameField(); root.submitName()
              }
              Keys.onEnterPressed: function(event) {
                event.accepted = true; root.leaveNameField(); root.submitName()
              }
              Keys.onEscapePressed: function(event) {
                root.revertName(); root.leaveNameField(); event.accepted = true
              }
              Keys.onUpPressed: function(event) {
                root.leaveNameField(); root.moveCursor(-1); event.accepted = true
              }
              Keys.onDownPressed: function(event) {
                root.leaveNameField(); root.moveCursor(1); event.accepted = true
              }
            }

            Text {
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

            PanelSeparator { width: parent.width; foreground: root.foreground }

            // What the popup deliberately does not have: play, pause and skip.
            // shairport-sync claims CanPause and CanGoNext over MPRIS, but in
            // AirPlay 2 mode they do nothing at all -- see NOTES.md. Controls
            // belong on the phone, so say so once instead of drawing buttons
            // that lie.
            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: "Use your phone to play, pause and skip."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            // Repair and removal share one row, so the extra action costs no
            // height. Repair is the front door for everything the popup cannot
            // fix in place; removal stays the deliberate, destructive one.
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
                text: "Remove receiver"
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
        confirmText: "Remove"
        cancelText: "Cancel"
        fontFamily: root.fontFamily
        onConfirmed: { opened = false; root.svc.runRemove(); root.close() }
        onCanceled: opened = false
      }
    }
  }
}
