import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import qs.Commons

// Session-wide state for the AirPlay receiver. systemd owns the receiver, so
// a shell restart never cuts playback; nothing here needs root.
Item {
  id: root

  // Host injection for a third-party service, from shell.qml ensureService().
  // `shell` is a capability-scoped facade, not the real shell object.
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  // Services get no settings from the host; BarWidget pushes them in.
  property var settings: ({})

  readonly property string home: Quickshell.env("HOME") || ""

  // From the QML engine, not $HOME: this decides which files get executed.
  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    if (u.indexOf("file://") === 0) {
      u = decodeURIComponent(u.substring(7)).replace(/\/+$/, "")
      if (u !== "") return u
    }
    return home + "/.config/omarchy/plugins/io.github.dmatthan.omairplay"
  }
  readonly property string unit: "omarchy-airplay.service"

  // Absolute paths: the inherited PATH puts user-writable directories first.
  readonly property string binSystemctl: "/usr/bin/systemctl"
  readonly property string binNotifySend: "/usr/bin/notify-send"
  readonly property string binTerminal:
    "/usr/bin/omarchy-launch-floating-terminal-with-presentation"
  readonly property string binTimeout: "/usr/bin/timeout"
  readonly property string binSetsid: "/usr/bin/setsid"

  // Closed environment for every child. timeout, systemctl and notify-send have
  // nothing to re-exec into, and LD_PRELOAD alone would run code inside them.
  readonly property var sealedEnv: {
    var e = {
      "PATH": "/usr/bin",
      "OMARCHY_PATH": "/usr/share/omarchy",
      "LC_ALL": "C",
      "HOME": home
    }
    var runtime = Quickshell.env("XDG_RUNTIME_DIR")
    if (runtime) e["XDG_RUNTIME_DIR"] = runtime
    var bus = Quickshell.env("DBUS_SESSION_BUS_ADDRESS")
    if (bus) e["DBUS_SESSION_BUS_ADDRESS"] = bus
    return e
  }

  // The terminal also needs the session's display variables. No LC_ALL=C: it
  // would mangle Omarchy's UTF-8 logo, and airplay-setup re-pins it itself.
  readonly property var sealedTerminalEnv: {
    var e = {
      "PATH": "/usr/bin",
      "OMARCHY_PATH": "/usr/share/omarchy",
      "HOME": home,
      "TERM": "xterm-256color"
    }
    var user = Quickshell.env("USER")
    if (user) { e["USER"] = user; e["LOGNAME"] = user }
    var pass = ["XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS",
                "WAYLAND_DISPLAY", "DISPLAY",
                "XDG_CURRENT_DESKTOP", "XDG_SESSION_TYPE",
                "XDG_DATA_DIRS", "XDG_CONFIG_DIRS",
                "HYPRLAND_INSTANCE_SIGNATURE", "LANG"]
    for (var i = 0; i < pass.length; i++) {
      var v = Quickshell.env(pass[i])
      if (v) e[pass[i]] = v
    }
    return e
  }

  // Without --kill-after, timeout(1) waits forever on a child ignoring SIGTERM.
  readonly property string launcherKillAfter: "--kill-after=5s"
  // The spawn returns in under a second; this only fires if setsid hangs.
  readonly property string launcherDeadlineSec: "15"
  // Ceiling on child output, checked as it arrives (waitForEnd: false). The
  // probes emit about 200 bytes.
  readonly property int maxChildBytes: 65536
  property bool _statusCapped: false
  property bool _firewallCapped: false
  property bool _actionCapped: false
  property bool _coverCapped: false

  readonly property string probeKillAfter: "--kill-after=5s"
  readonly property string actionKillAfter: "--kill-after=10s"

  // Every child gets a hard deadline; timeout exits 124. Probes take 40-130 ms.
  readonly property string probeDeadlineSec: "10"

  // Starting can wait 45 s on the audio gate, plus systemd's own timeouts; 150 s
  // never pre-empts a legitimate action.
  readonly property string actionDeadlineSec: "150"

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
  readonly property int refreshIntervalSec: 5

  // ------------------------------------------------------------------ state
  property bool probed: false
  property bool binaryPresent: false
  property bool unitPresent: false
  property bool configPresent: false
  readonly property bool setupComplete: binaryPresent && unitPresent && configPresent

  property string activeState: ""
  property string unitFileState: ""
  // "activating" is not running: a crash-looping unit sits in it for up to two
  // minutes, and the popup must not call that ready.
  readonly property bool running: activeState === "active"
  readonly property bool activating: activeState === "activating"
  readonly property bool failed: activeState === "failed"
  readonly property bool startAtLogin: unitFileState === "enabled"

  // Read back from the generated config: what the receiver actually answers to.
  property string advertisedName: ""

  // The receiver reads its config only at startup.
  property bool configStale: false

  // airplay-write-config's template version; an older config is regenerated
  // once per session, keeping its name, so a plugin update reaches it.
  readonly property int configTemplate: 2
  property int configTemplateFound: configTemplate
  property bool _configMigrated: false

  // Another shairport-sync (system or user unit) holding the one AirPlay 2 slot.
  property bool systemUnitBusy: false
  property bool packagedUnitBusy: false
  readonly property bool conflicting: systemUnitBusy || packagedUnitBusy

  // From the live ufw rules, so a changed IPv6 prefix shows up too.
  property bool firewallOk: true
  property string firewallReason: ""
  property var firewallMissing: []
  readonly property string firewallCheckFailed: "Could not check the firewall rules"

  // True until a poll says otherwise, so a first poll never flashes a warning.
  property bool nqptpActive: true
  property bool listening: true

  // Only Repair fixes these; never raised while the receiver is off.
  readonly property bool clockSyncDown: probed && setupComplete
    && effectiveRunning && !nqptpActive
  readonly property bool notListening: probed && setupComplete
    && effectiveRunning && !listening

  // Anything only Repair fixes. Not before setup: no rules yet is not a fault.
  readonly property bool needsRepair: setupComplete
    && (!firewallOk
        || (probed && effectiveRunning
            && (!nqptpActive || !listening || audioStalled)))

  property string pendingAction: ""
  readonly property bool busy: pendingAction !== ""
  property string lastError: ""

  // Optimistic on/off, so the switch answers at once: ToggleSwitch swallows
  // clicks while busy without looking busy. -1 follows reality.
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
      case "update":  return "Updating"
      default:        return ""
    }
  }

  // ------------------------------------------------------------ now playing
  //
  // Display only: in AirPlay 2 mode shairport-sync's MPRIS transport methods
  // are no-ops, so no controls are offered.
  readonly property var players: Mpris.players ? Mpris.players.values : []
  readonly property var player: findPlayer()
  readonly property bool playing: !!(player && player.isPlaying)
  readonly property string title: player ? trackText(player.trackTitle) : ""
  readonly property string artist: player ? trackText(player.trackArtist) : ""
  readonly property string album: player ? trackText(player.trackAlbum) : ""
  readonly property string artUrl: player ? String(player.trackArtUrl || "") : ""
  readonly property bool hasTrack: title !== "" || artist !== ""

  // Sender text arrives at any length, and Qt lays out the whole string even
  // when elided. Every reader goes through these three properties.
  readonly property int maxTrackChars: 512
  function trackText(value) {
    var s = String(value || "")
    if (s.length <= maxTrackChars) return s
    var end = maxTrackChars
    // Do not leave half a surrogate pair at the cut.
    var c = s.charCodeAt(end - 1)
    if (c >= 0xd800 && c <= 0xdbff) end--
    return s.slice(0, end) + "…"
  }

  // Only bin/airplay-cover-art's rebuilt copy is loaded, never artUrl itself.
  // The last cover stays up while the next is rebuilt.
  property string coverArt: ""
  readonly property string coverArtUrl: coverArt === "" ? ""
    : "file://" + coverArt.split("/").map(encodeURIComponent).join("/")
  // The artUrl the running rebuild was given, so a stale answer is dropped.
  property string _coverArtFor: ""

  onArtUrlChanged: refreshCoverArt()

  Timer {
    id: coverClearTimer
    interval: 3000
    onTriggered: if (root.artUrl === "") {
      coverSettleTimer.stop()
      root.coverArt = ""
      root._coverArtFor = ""
    }
  }

  // A phone may send a placeholder cover just before the real one, so a new
  // cover waits a moment before it is shown.
  property string _coverCandidate: ""
  Timer {
    id: coverSettleTimer
    interval: 800
    onTriggered: root.coverArt = root._coverCandidate
  }

  // Whether the cover for the current art is still to come.
  readonly property bool coverArtPending: coverProcess.running || coverSettleTimer.running
    || coverClearTimer.running || (artUrl !== "" && _coverArtFor !== artUrl)

  function refreshCoverArt() {
    // shairport-sync blanks the art URL for a moment and resends it, in bursts
    // around a track change and now and then mid-track. Clear the cover only
    // if it stays blank, and never rebuild the one already shown.
    if (artUrl === "") { coverClearTimer.restart(); return }
    coverClearTimer.stop()
    if (artUrl === _coverArtFor && !coverProcess.running) return
    // One rebuild at a time; onExited starts the next if the art moved on.
    if (coverProcess.running) return
    _coverArtFor = artUrl
    coverProcess.command = [binTimeout, probeKillAfter, probeDeadlineSec,
                            pluginDir + "/bin/airplay-cover-art", artUrl]
    coverProcess.running = true
  }

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

  // The sending device's name, from airplay-status (sanitised there).
  property string clientName: ""
  readonly property string sender: clientName.length > 40
    ? clientName.substring(0, 40).replace(/[\ud800-\udbff]$/, "") + "…" : clientName

  // Short: PanelHero renders it in small caps and elides it.
  readonly property string statusText: {
    if (actionLabel !== "") return actionLabel + "\u2026"
    if (needsRepair) return "Needs repair"
    switch (receiverState) {
      case "missing":  return "Not set up"
      case "failed":   return "Failed"
      case "off":      return "Off"
      case "starting": return "Starting"
      case "playing":  return sender !== "" ? "Playing from " + sender : "Playing"
      default:        return "Ready"
    }
  }

  // ---------------------------------------------------- track notifications
  //
  // A desktop notification, because Omarchy's track OSD only fires on user
  // actions and a third-party plugin cannot summon it.
  readonly property string trackKey: playing && hasTrack
    ? (title + "\u001f" + artist + "\u001f" + album) : ""

  property string _notifiedTrack: ""
  property double _serviceLoadedAt: 0

  onTrackKeyChanged: if (trackNotifications && trackKey !== "") notifyDebounce.restart()

  // Metadata arrives in pieces (title, artist, cover); wait for it to settle.
  Timer {
    id: notifyDebounce
    interval: 900
    repeat: false
    onTriggered: root.notifyTrackChange()
  }

  function notifyTrackChange() {
    if (!trackNotifications || !playing || !hasTrack) return
    if (trackKey === _notifiedTrack) return
    // Wait for a cover still being rebuilt rather than announce without it.
    if (coverArtPending) { notifyDebounce.restart(); return }
    _notifiedTrack = trackKey

    // Silent for a song already playing when the shell (re)started.
    if (Date.now() - _serviceLoadedAt < 5000) return

    var args = [binTimeout, probeKillAfter, probeDeadlineSec,
                binNotifySend, "-a", "OmairPlay"]
    // The rebuilt copy only: the shell's notification server decodes it too.
    if (coverArt !== "")
      args.push("-i", coverArt)
    // `--` ends option parsing: a title such as `--icon=<path>` was otherwise
    // read as an option and swapped in a file of the sender's choosing.
    args.push("--")
    args.push(title !== "" ? title : "AirPlay")

    // The body is markup to the notification server; escape the sender's text.
    var sub = []
    if (artist !== "") sub.push(artist)
    if (album !== "" && album !== title) sub.push(album)
    args.push(escapeMarkup(sub.join(" | ")))

    Quickshell.execDetached({
      command: args,
      clearEnvironment: true,
      environment: sealedEnv
    })
  }

  function escapeMarkup(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }

  Component.onCompleted: {
    _serviceLoadedAt = Date.now()
    // A shell restart mid-song: the art is already there and will not change.
    refreshCoverArt()
  }

  // Whether audio actually reaches PipeWire: the control channel can be up
  // while the audio path is dead. Same match as LevelMeter.qml.
  readonly property var streamNode: findStreamNode()
  readonly property bool audioStreamUp: streamNode !== null

  function findStreamNode() {
    var nodes = Pipewire.nodes ? Pipewire.nodes.values : []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || !n.isStream || !n.audio || n.isSink !== true) continue
      var candidates = [n.name, n.nickname, n.description]
      var props = n.properties
      if (props) candidates.push(props["application.name"],
                                props["application.process.binary"],
                                props["node.name"], props["media.name"])
      for (var j = 0; j < candidates.length; j++) {
        if (String(candidates[j] || "").toLowerCase().indexOf("shairport") !== -1)
          return n
      }
    }
    return null
  }

  // Without this the node's properties are not kept live.
  PwObjectTracker { objects: root.streamNode ? [root.streamNode] : [] }

  // Longer than shairport-sync's 10 s active_state_timeout, so a pause or a
  // track change never trips it.
  property bool audioStalled: false
  Timer {
    id: audioStallTimer
    interval: 12000
    repeat: false
    running: root.probed && root.setupComplete && root.effectiveRunning
             && root.playing && root.hasTrack && !root.audioStreamUp
    onTriggered: root.audioStalled = true
  }
  onAudioStreamUpChanged: if (audioStreamUp) audioStalled = false
  // A new session: fetch the sender's name now, not at the next poll.
  onPlayingChanged: if (!playing) audioStalled = false; else refresh()
  onEffectiveRunningChanged: if (!effectiveRunning) audioStalled = false

  // ------------------------------------------------------------ self-healing
  //
  // A wedged or half-up receiver is already silent, so restarting costs nothing.
  // Twice per 15 minutes, then the alert. Clock-sync and firewall faults are
  // left alone: a restart cannot fix them.
  property int _autoRepairs: 0
  property double _autoRepairWindowStart: 0
  readonly property bool restartableStall: notListening || audioStalled

  function autoRepair() {
    var now = Date.now()
    if (now - _autoRepairWindowStart > 15 * 60 * 1000) {
      _autoRepairWindowStart = now
      _autoRepairs = 0
    }
    if (_autoRepairs >= 2) return
    _autoRepairs++
    restart()
  }

  // The stall must last 15 s first, whatever the poll interval.
  Timer {
    id: autoRepairTimer
    interval: 15000
    repeat: false
    running: root.probed && root.setupComplete && !root.busy
             && root.restartableStall
    onTriggered: root.autoRepair()
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
    runAction("start", [binSystemctl, "--user", "start", unit])
  }

  function stop() {
    if (busy) return
    desiredRunning = 0
    runAction("stop", [binSystemctl, "--user", "stop", unit])
  }

  function toggle() {
    if (busy) return
    effectiveRunning ? stop() : start()
  }

  // Interrupts playback, so it is only ever offered, never automatic.
  function restart() {
    if (busy || !setupComplete) return
    runAction("restart", [binSystemctl, "--user", "restart", unit])
  }

  function setStartAtLogin(enabled) {
    if (busy || !setupComplete) return
    runAction(enabled ? "enable" : "disable",
              [binSystemctl, "--user", enabled ? "enable" : "disable", unit])
  }

  // Rewrites the config; a running receiver needs a restart to take it. Takes
  // the name directly, because speakerName lags a rename by a settings reload.
  function applyName(name, restartIfRunning) {
    if (busy) return
    var wanted = String(name || "").trim().substring(0, 50)
    if (wanted === "") return
    // Two argv steps, not a shell string built around a typed name.
    var steps = [[pluginDir + "/bin/airplay-write-config", "--name", wanted]]
    if (restartIfRunning && running)
      steps.push([binSystemctl, "--user", "restart", unit])
    runSteps("name", steps)
  }

  // Restarts only while nothing plays; otherwise the stale-config alert offers it.
  function migrateConfig() {
    if (busy || _configMigrated || !setupComplete) return
    var name = advertisedName !== "" ? advertisedName : speakerName
    _configMigrated = true
    var steps = [[pluginDir + "/bin/airplay-write-config", "--name", name]]
    if (running && !playing)
      steps.push([binSystemctl, "--user", "restart", unit])
    else
      _restartWhenIdle = running
    runSteps("update", steps)
  }
  property bool _restartWhenIdle: false
  // Half a minute of silence, so a pause or a track change is never cut short.
  Timer {
    interval: 30000
    running: root._restartWhenIdle && root.running && root.configStale
             && !root.playing && !root.busy
    onTriggered: { root._restartWhenIdle = false; root.restart() }
  }

  // Visibly in a terminal, never pkexec: root must not run files from the
  // user-writable plugin folder.
  function runSetup(wide) {
    var cmd = Util.shellQuote(pluginDir + "/bin/airplay-setup")
    if (wide) cmd += " --wide"
    launchInTerminal(cmd)
  }

  function runRemove() {
    launchInTerminal(Util.shellQuote(pluginDir + "/bin/airplay-remove") + " --system")
  }

  // Remove then setup in one terminal (one sudo prompt), then restore the
  // unit's enabled/running state.
  function runRepair() {
    if (busy) return
    launchInTerminal(Util.shellQuote(pluginDir + "/bin/airplay-repair"))
  }

  // Sealed: the launcher sources Omarchy scripts by bare name, so an inherited
  // PATH could run planted code before setup seals anything. The deadline wraps
  // setsid, not the launcher, which it would kill mid-password: it bounds the
  // spawn, not the session.
  function launchInTerminal(command) {
    Quickshell.execDetached({
      command: [binTimeout, launcherKillAfter, launcherDeadlineSec,
                binSetsid, binTerminal, command],
      clearEnvironment: true,
      environment: sealedTerminalEnv
    })
    // The terminal changes state behind our back, so start watching for it
    // rather than waiting for the next scheduled poll.
    catchUpTimer.restart()
  }

  // A single command. Most actions are one step.
  function runAction(name, command) {
    runSteps(name, [command])
  }

  // Commands in order, stopping at the first failure; busy for the whole chain.
  function runSteps(name, steps) {
    if (!steps || steps.length === 0) return
    lastError = ""
    pendingAction = name
    _queuedSteps = steps.slice(1)
    _spawnStep(steps[0])
  }

  // Steps of the current action still to run.
  property var _queuedSteps: []

  function _runNextStep() {
    if (_queuedSteps.length === 0) return
    var next = _queuedSteps[0]
    _queuedSteps = _queuedSteps.slice(1)
    _spawnStep(next)
  }

  // Single place every action step is spawned, so the deadline cannot be
  // forgotten on a future one.
  function _spawnStep(argv) {
    actionProcess.command =
      [binTimeout, actionKillAfter, actionDeadlineSec].concat(argv)
    actionProcess.running = true
  }

  // ------------------------------------------------------------- processes
  Process {
    id: statusProcess
    command: [root.binTimeout, root.probeKillAfter, root.probeDeadlineSec,
              root.pluginDir + "/bin/airplay-status"]
    running: false
    clearEnvironment: true
    environment: root.sealedEnv
    stdout: StdioCollector {
      id: statusOut
      waitForEnd: false
      onDataChanged: if (text.length > root.maxChildBytes && statusProcess.running) {
        root._statusCapped = true
        statusProcess.signal(15)
      }
    }
    stderr: StdioCollector {
      id: statusErr
      waitForEnd: false
      onDataChanged: if (text.length > root.maxChildBytes && statusProcess.running) {
        root._statusCapped = true
        statusProcess.signal(15)
      }
    }
    onExited: function(exitCode) {
      root.probed = true
      if (root._statusCapped) {
        root._statusCapped = false
        root.lastError = "Receiver status returned more data than expected"
        return
      }
      if (exitCode === 124) {
        root.lastError = "Timed out reading receiver status"
        return
      }
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
        root.clientName = String(s.client_name || "")
        root.configStale = !!s.config_stale
        root.configTemplateFound = Number(s.config_template) || 0
        root.nqptpActive = s.nqptp !== false
        root.listening = s.listening !== false
        if (root.configPresent && root.configTemplateFound < root.configTemplate)
          Qt.callLater(root.migrateConfig)
      } catch (e) {
        root.lastError = "Could not parse receiver status"
      }
    }
  }

  Process {
    id: firewallProcess
    command: [root.binTimeout, root.probeKillAfter, root.probeDeadlineSec,
              root.pluginDir + "/bin/airplay-check-firewall"]
    running: false
    clearEnvironment: true
    environment: root.sealedEnv
    stdout: StdioCollector {
      id: firewallOut
      waitForEnd: false
      onDataChanged: if (text.length > root.maxChildBytes && firewallProcess.running) {
        root._firewallCapped = true
        firewallProcess.signal(15)
      }
    }
    onExited: function(exitCode) {
      var capped = root._firewallCapped
      root._firewallCapped = false
      var f = null
      if (!capped && exitCode === 0) {
        try { f = JSON.parse(String(firewallOut.text || "{}")) } catch (e) { f = null }
      }
      // A check that cannot run is reported, never read as "all fine".
      if (!f || typeof f.ok !== "boolean") {
        root.lastError = root.firewallCheckFailed
        return
      }
      if (root.lastError === root.firewallCheckFailed) root.lastError = ""
      root.firewallOk = f.ok
      root.firewallReason = String(f.reason || "")
      root.firewallMissing = f.missing instanceof Array ? f.missing : []
    }
  }

  Process {
    id: coverProcess
    command: []
    running: false
    clearEnvironment: true
    environment: root.sealedEnv
    stdout: StdioCollector {
      id: coverOut
      waitForEnd: false
      onDataChanged: if (text.length > root.maxChildBytes && coverProcess.running) {
        root._coverCapped = true
        coverProcess.signal(15)
      }
    }
    onExited: function(exitCode) {
      var capped = root._coverCapped
      root._coverCapped = false
      // A blank URL is not a new one: it is usually resent a moment later.
      if (root.artUrl !== "" && root._coverArtFor !== root.artUrl) {
        Qt.callLater(root.refreshCoverArt)
        return
      }
      // The blank outlasted the rebuild and the cover was cleared: too late.
      if (root._coverArtFor === "") return
      // Only ever a copy in the helper's own directory, named as it names them.
      // Refused art clears the cover rather than leave the last track's up.
      var path = String(coverOut.text || "").trim()
      root._coverCandidate = !capped && exitCode === 0
          && /^\/.*\/\.cache\/shairport-sync\/omairplay-art\/cover-[0-9a-f]{32}\.(png|jpg)$/.test(path)
        ? path : ""
      coverSettleTimer.restart()
    }
  }

  Process {
    id: actionProcess
    command: []
    running: false
    clearEnvironment: true
    environment: root.sealedEnv
    stderr: StdioCollector {
      id: actionErr
      waitForEnd: false
      onDataChanged: if (text.length > root.maxChildBytes && actionProcess.running) {
        root._actionCapped = true
        actionProcess.signal(15)
      }
    }
    onExited: function(exitCode) {
      var action = root.pendingAction

      if (exitCode === 0 && root._queuedSteps.length > 0) {
        // Next step, started outside this exit handler.
        Qt.callLater(root._runNextStep)
        return
      }

      root.pendingAction = ""
      root._queuedSteps = []
      if (exitCode !== 0) {
        var err = String(actionErr.text || "").trim()
        if (root._actionCapped) {
          root._actionCapped = false
          err = ""
          root.lastError = "The " + action + " command returned more data than expected"
        } else if (exitCode === 124)
          root.lastError = "Timed out trying to " + action + " the receiver"
        else
          root.lastError = err !== "" ? err : ("Could not " + action + " the receiver")
        // Do not keep claiming a state the action failed to reach.
        root.desiredRunning = -1
      }
      root.refresh()
      if (action === "name") root.refreshFirewall()
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

  // Rules change on their own (new network, new IPv6 prefix): poll slowly.
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
