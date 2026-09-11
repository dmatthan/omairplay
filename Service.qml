import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Commons

// Session-wide state for the AirPlay receiver.
//
// systemd owns the receiver, not this plugin, so a plugin reload or a shell
// restart never cuts off playback. Everything here is either a read of that
// state or a `systemctl --user` call against it; nothing in this file needs
// root, and nothing writes outside $HOME.
Item {
  id: root

  // Host injection for a third-party service, from shell.qml ensureService().
  // `shell` is a capability-scoped facade, not the real shell object.
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  // Bar widgets are handed their inline shell.json entry; services are not --
  // ensureService() injects shell/manifest/omarchyPath and the registries, and
  // stops there. Widget.qml pushes its settings down with a Binding so this
  // stays the single source of truth for both halves of the plugin.
  property var settings: ({})

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string pluginDir: home + "/.config/omarchy/plugins/io.github.dmatthan.omairplay"
  readonly property string unit: "omarchy-airplay.service"

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // shairport-sync caps the advertised name at 50 characters.
  readonly property string speakerName: {
    var wanted = String(setting("speakerName", "")).trim()
    return (wanted === "" ? "Omarchy Speaker" : wanted).substring(0, 50)
  }
  readonly property bool trackNotifications: setting("trackNotifications", true) !== false
  readonly property int refreshIntervalSec: {
    var n = parseInt(String(setting("refreshIntervalSec", 5)), 10)
    if (!isFinite(n)) n = 5
    return Math.max(2, Math.min(60, n))
  }

  // ------------------------------------------------------------------ state
  property bool probed: false
  property bool binaryPresent: false
  property bool unitPresent: false
  property bool configPresent: false
  readonly property bool setupComplete: binaryPresent && unitPresent && configPresent

  property string activeState: ""
  property string unitFileState: ""
  // "activating" deliberately does NOT count as running. With Restart=on-failure
  // and a deliberately generous StartLimit, a receiver that cannot start spends
  // up to two minutes cycling through "activating" before systemd finally marks
  // it "failed" -- so treating that as running made the popup report
  // "Ready - waiting for a device" while it was in fact crash-looping, and the
  // genuine failed state was nearly unreachable. Caught by inducing a start
  // failure on purpose.
  readonly property bool running: activeState === "active"
  readonly property bool activating: activeState === "activating"
  readonly property bool failed: activeState === "failed"
  readonly property bool startAtLogin: unitFileState === "enabled"

  // The name the config actually advertises, read back from the generated file
  // rather than from settings, so the popup shows what the receiver really
  // answers to. (An earlier `nameDirty` property compared this against the
  // settings value and was never used; the settings copy can lag a rename,
  // so it would have reported drift that was not there. `configStale` below
  // is the honest signal.)
  property string advertisedName: ""

  // The receiver reads its config only at startup, so a config written after
  // it started has not taken effect. Without surfacing this, the popup shows
  // the new name while the receiver still broadcasts the old one.
  property bool configStale: false

  // Safety rule 4. Two receivers would fight over port 7000 and over the
  // machine's single AirPlay 2 slot, so say so plainly rather than let the
  // thing fail for no visible reason. There are two candidates: the packaged
  // system unit, and the packaged *user* unit, whose preset is "enabled".
  property bool systemUnitBusy: false
  property bool packagedUnitBusy: false
  readonly property bool conflicting: systemUnitBusy || packagedUnitBusy

  // Read from /etc/ufw/user.rules and user6.rules, which are world-readable,
  // so this is the real firewall state rather than a marker file's guess. It
  // also catches the ISP re-delegating the IPv6 prefix, which silently stops
  // the old PTP rule from matching.
  property bool firewallOk: true
  property string firewallReason: ""
  property var firewallMissing: []

  property string pendingAction: ""
  readonly property bool busy: pendingAction !== ""
  property string lastError: ""

  // Optimistic on/off, so the switch answers the click instead of waiting for
  // the next poll. Ui/ToggleSwitch expects `checked` to already be optimistic
  // and it swallows clicks while `busy` *without changing appearance*, so
  // feeding it the real polled state made a slow stop look like a dead
  // control -- which is exactly how a 90-second wedged shutdown presented.
  // -1 means "follow reality", 0 and 1 mean "a toggle is still catching up".
  property int desiredRunning: -1
  readonly property bool effectiveRunning: desiredRunning === -1
    ? running : (desiredRunning === 1)

  onRunningChanged: {
    // Reality caught up; stop overriding it.
    if (desiredRunning !== -1 && running === (desiredRunning === 1))
      desiredRunning = -1
  }

  // What is in flight, for the popup to say so rather than appear stuck.
  readonly property string actionLabel: {
    switch (pendingAction) {
      case "start":   return "Starting"
      case "stop":    return "Stopping"
      case "restart": return "Restarting"
      case "enable":  return "Enabling at login"
      case "disable": return "Disabling at login"
      case "name":    return "Renaming"
      default:        return ""
    }
  }

  // ------------------------------------------------------------ now playing
  //
  // Display only, deliberately. shairport-sync's MPRIS interface advertises
  // CanPause, CanPlay, CanGoNext and CanGoPrevious as true, and in AirPlay 2
  // mode all of them are no-ops: Pause returns success and playback carries
  // on, and Volume is not writable at all. Remote control travels over DACP
  // and AirPlay 2 senders expose no DACP port, so there is nothing to send to.
  // Verified live on this machine -- see NOTES.md.
  //
  // So this service exposes no transport actions. A skip button that silently
  // does nothing is worse than no skip button.
  readonly property var players: Mpris.players ? Mpris.players.values : []
  readonly property var player: findPlayer()
  readonly property bool playing: !!(player && player.isPlaying)
  readonly property string title: player ? String(player.trackTitle || "") : ""
  readonly property string artist: player ? String(player.trackArtist || "") : ""
  readonly property string album: player ? String(player.trackAlbum || "") : ""
  readonly property string artUrl: player ? String(player.trackArtUrl || "") : ""
  readonly property bool hasTrack: title !== "" || artist !== ""

  // The phone's own volume: readable, and not settable from here.
  readonly property real senderVolume: {
    if (!player) return -1
    var v = player.volume
    return (v === undefined || v === null || v < 0) ? -1 : v
  }

  function findPlayer() {
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!p) continue
      if (String(p.dbusName || "").indexOf("ShairportSync") !== -1) return p
      if (String(p.desktopEntry || "") === "shairport-sync") return p
    }
    return null
  }

  // "missing" | "off" | "failed" | "idle" | "playing".
  // Not named `state`: Item already has one, and shadowing it breaks QML states.
  readonly property string receiverState: {
    if (!probed) return "off"
    if (!setupComplete) return "missing"
    if (failed) return "failed"
    if (activating) return "starting"
    if (!effectiveRunning) return "off"
    return playing ? "playing" : "idle"
  }

  // A short label, not a sentence: the popup renders this in small caps and
  // the bar tooltip appends its own detail. The track line is separate.
  readonly property string statusText: {
    if (actionLabel !== "") return actionLabel + "\u2026"
    switch (receiverState) {
      case "missing":  return "Not set up"
      case "failed":   return "Failed"
      case "off":      return "Off"
      case "starting": return "Starting"
      case "playing":  return "Playing"
      default:        return "Ready"
    }
  }

  // ---------------------------------------------------- track notifications
  //
  // Omarchy's own track OSD cannot be used for this. `omarchy.media` does have
  // one, but it only fires from user-initiated actions through its widget
  // (Service.qml:429) -- nothing there watches for a track changing on its
  // own, which is the only way a track ever changes here. And the OSD belongs
  // to `omarchy.osd`, which a third-party plugin cannot summon: the host
  // scopes summon() to the plugin's own id (shell.qml pluginOwnsTarget).
  //
  // So use a desktop notification. Omarchy's shell owns
  // org.freedesktop.Notifications, so notify-send produces a native, themed
  // notification with the cover art as its image.
  readonly property string trackKey: playing && hasTrack
    ? (title + "\u001f" + artist + "\u001f" + album) : ""

  property string _notifiedTrack: ""
  property double _serviceLoadedAt: 0

  onTrackKeyChanged: if (trackNotifications && trackKey !== "") notifyDebounce.restart()

  // shairport-sync delivers metadata in pieces -- title first, then artist,
  // then cover art -- so reacting to each change would fire three times for one
  // song. Wait for it to settle. (The freedesktop "synchronous" hint that would
  // otherwise replace a notification in place is not honoured here; tested, and
  // three rapid notifications stacked.)
  Timer {
    id: notifyDebounce
    interval: 900
    repeat: false
    onTriggered: root.notifyTrackChange()
  }

  function notifyTrackChange() {
    if (!trackNotifications || !playing || !hasTrack) return
    if (trackKey === _notifiedTrack) return
    _notifiedTrack = trackKey

    // Don't announce whatever was already playing when this service loaded --
    // a shell restart mid-song should be silent. A grace period rather than a
    // "first one" flag, so a song that starts later is still announced.
    if (Date.now() - _serviceLoadedAt < 5000) return

    var args = ["notify-send", "-a", "OmairPlay"]
    var art = String(artUrl || "")
    if (art.indexOf("file://") === 0)
      args.push("-i", decodeURIComponent(art.substring(7)))
    args.push(title !== "" ? title : "AirPlay")

    var sub = []
    if (artist !== "") sub.push(artist)
    if (album !== "" && album !== title) sub.push(album)
    args.push(sub.join("  \u00b7  "))

    Quickshell.execDetached(args)
  }

  Component.onCompleted: _serviceLoadedAt = Date.now()

  // "Title - Artist", or as much of it as there is.
  readonly property string trackLine: {
    if (!hasTrack) return ""
    if (title !== "" && artist !== "") return title + "  -  " + artist
    return title !== "" ? title : artist
  }

  // --------------------------------------------------------------- actions
  function refresh() {
    if (!statusProcess.running) statusProcess.running = true
  }

  function refreshFirewall() {
    if (!firewallProcess.running) firewallProcess.running = true
  }

  function start() {
    if (busy || !setupComplete) return
    desiredRunning = 1
    runAction("start", ["systemctl", "--user", "start", unit])
  }

  function stop() {
    if (busy) return
    desiredRunning = 0
    runAction("stop", ["systemctl", "--user", "stop", unit])
  }

  function toggle() {
    if (busy) return
    effectiveRunning ? stop() : start()
  }

  // Applies a config written while the receiver was already up. Interrupts
  // playback, so the popup only offers it rather than doing it automatically.
  function restart() {
    if (busy || !setupComplete) return
    runAction("restart", ["systemctl", "--user", "restart", unit])
  }

  function setStartAtLogin(enabled) {
    if (busy || !setupComplete) return
    runAction(enabled ? "enable" : "disable",
              ["systemctl", "--user", enabled ? "enable" : "disable", unit])
  }

  // Regenerates the whole config from the plugin's settings. The receiver only
  // reads its config at startup, so a running receiver has to be restarted for
  // a new name to take -- which interrupts playback. The caller decides
  // whether that is acceptable; the popup asks first when something is playing.
  // Takes the name as an argument rather than reading `speakerName`. That
  // property comes from the persisted shell.json entry, and a rename has to
  // travel widget -> shell.json -> config reload -> Binding before it lands
  // here. Reading it directly meant rewriting the config with the *old* name
  // every time, which is exactly what happened: the receiver kept advertising
  // the previous name while the field appeared to change.
  function applyName(name, restartIfRunning) {
    if (busy) return
    var wanted = String(name || "").trim().substring(0, 50)
    if (wanted === "") return
    var script = "set -e; " + Util.shellQuote(pluginDir + "/bin/airplay-write-config")
      + " --name " + Util.shellQuote(wanted)
    if (restartIfRunning && running)
      script += "; systemctl --user restart " + Util.shellQuote(unit)
    runAction("name", ["bash", "-c", script])
  }

  // Privileged setup runs visibly in Omarchy's floating terminal, which is
  // where a password prompt belongs. Never pkexec: the plugin folder is
  // user-writable, so running a script from it as root would be a way to
  // escalate.
  function runSetup(wide) {
    var cmd = Util.shellQuote(pluginDir + "/bin/airplay-setup")
    if (wide) cmd += " --wide"
    launchInTerminal(cmd)
  }

  function runRemove() {
    launchInTerminal(Util.shellQuote(pluginDir + "/bin/airplay-remove") + " --firewall")
  }

  function launchInTerminal(command) {
    Quickshell.execDetached([
      "omarchy-launch-floating-terminal-with-presentation", command
    ])
    // The terminal changes state behind our back, so start watching for it
    // rather than waiting for the next scheduled poll.
    catchUpTimer.restart()
  }

  function runAction(name, command) {
    lastError = ""
    pendingAction = name
    actionProcess.command = command
    actionProcess.running = true
  }

  // ------------------------------------------------------------- processes
  Process {
    id: statusProcess
    command: [root.pluginDir + "/bin/airplay-status"]
    running: false
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    stderr: StdioCollector { id: statusErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.probed = true
      if (exitCode !== 0) {
        root.lastError = String(statusErr.text || "").trim() || "Could not read receiver status"
        return
      }
      try {
        var s = JSON.parse(String(statusOut.text || "{}"))
        root.binaryPresent = !!s.binary
        root.unitPresent = !!s.unit
        root.configPresent = !!s.config
        root.activeState = String(s.active || "")
        root.unitFileState = String(s.unit_file || "")
        root.systemUnitBusy = !!s.system_unit_busy
        root.packagedUnitBusy = !!s.packaged_unit_busy
        root.advertisedName = String(s.advertised_name || "")
        root.configStale = !!s.config_stale
      } catch (e) {
        root.lastError = "Could not parse receiver status"
      }
    }
  }

  Process {
    id: firewallProcess
    command: [root.pluginDir + "/bin/airplay-check-firewall"]
    running: false
    stdout: StdioCollector { id: firewallOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      try {
        var f = JSON.parse(String(firewallOut.text || "{}"))
        root.firewallOk = !!f.ok
        root.firewallReason = String(f.reason || "")
        root.firewallMissing = f.missing instanceof Array ? f.missing : []
      } catch (e) {
        // Leave the last known answer alone rather than claim a problem.
      }
    }
  }

  Process {
    id: actionProcess
    command: []
    running: false
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      var failedAction = root.pendingAction
      root.pendingAction = ""
      if (exitCode !== 0) {
        var err = String(actionErr.text || "").trim()
        root.lastError = err !== "" ? err : ("Could not " + failedAction + " the receiver")
        // Do not keep claiming a state the action failed to reach.
        root.desiredRunning = -1
      }
      root.refresh()
      if (failedAction === "name") root.refreshFirewall()
    }
  }

  // --------------------------------------------------------------- timers
  Timer {
    id: pollTimer
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // The firewall answer changes rarely, but it does change on its own -- a new
  // network, or the ISP handing out a different IPv6 prefix. Slow poll rather
  // than never.
  Timer {
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshFirewall()
  }

  // After launching the setup or remove terminal, poll briefly so the popup
  // reflects the outcome as soon as it happens.
  Timer {
    id: catchUpTimer
    interval: 2000
    repeat: true
    triggeredOnStart: false
    property int ticks: 0
    onRunningChanged: if (running) ticks = 0
    onTriggered: {
      root.refresh()
      root.refreshFirewall()
      if (++ticks >= 45) stop()   // give up after about 90 seconds
    }
  }
}
