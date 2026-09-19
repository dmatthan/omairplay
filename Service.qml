import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
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

  // Where this plugin's own executables live, taken from the QML engine rather
  // than rebuilt out of $HOME.
  //
  // This used to be home + "/.config/omarchy/plugins/<id>", which meant the
  // path we run helpers from was derived from an inherited value -- the same
  // ambient resolution the PATH pin exists to remove, and worse, because it
  // decides which files get executed rather than merely where to look for a
  // command. Qt.resolvedUrl(".") is the engine's own record of where this file
  // was loaded from and cannot be influenced by the environment.
  //
  // The host does not offer an alternative: it deletes __sourceDir from the
  // manifest before handing it to a third-party plugin (shell.qml,
  // publicPluginManifest), and `manifest` is still null when this is first
  // evaluated. The $HOME form is kept only as a fallback.
  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    if (u.indexOf("file://") === 0) {
      u = decodeURIComponent(u.substring(7)).replace(/\/+$/, "")
      if (u !== "") return u
    }
    return home + "/.config/omarchy/plugins/io.github.dmatthan.omairplay"
  }
  readonly property string unit: "omarchy-airplay.service"

  // Absolute paths for everything spawned from here.
  //
  // Quickshell resolves a Process command through the PATH the shell inherited,
  // and that PATH puts user-writable directories ahead of /usr/bin -- six of
  // them on the development machine, with /usr/bin only at position 10. A bare
  // "systemctl" is therefore a lookup through space the user can write to,
  // inside a long-running process. All three of these ship in /usr/bin; the
  // omarchy package installs its own commands there too.
  readonly property string binSystemctl: "/usr/bin/systemctl"
  readonly property string binNotifySend: "/usr/bin/notify-send"
  readonly property string binTerminal:
    "/usr/bin/omarchy-launch-floating-terminal-with-presentation"
  readonly property string binTimeout: "/usr/bin/timeout"
  readonly property string binSetsid: "/usr/bin/setsid"

  // The environment handed to every child spawned from here.
  //
  // The scripts re-exec themselves into a closed environment, but that leaves
  // two gaps this closes: timeout(1) itself, and systemctl and notify-send,
  // which are binaries with nothing to re-exec into. All three would otherwise
  // start with the shell's inherited environment, where LD_PRELOAD alone is
  // enough to run code inside them.
  //
  // Only what they actually need: systemctl --user and notify-send reach the
  // session bus, and pactl (via the scripts) needs the runtime directory.
  // HOME is read from the environment here rather than the passwd database
  // because Quickshell offers no lookup; the scripts correct it themselves on
  // re-exec, which is what decides where files are written.
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

  // The launcher needs more than the probes do, because it starts a graphical
  // terminal. Same closed base, plus the session variables that terminal
  // genuinely requires -- passed through only when they are actually set, so a
  // different session shape degrades rather than breaks.
  //
  // LC_ALL is deliberately absent here. The probes pin it to C for
  // deterministic parsing, but this environment reaches a terminal a person
  // reads: C would mangle the UTF-8 in Omarchy's logo and gum widgets. LANG is
  // passed instead, and airplay-setup re-pins LC_ALL=C for itself on re-exec,
  // so the scripts still parse deterministically.
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

  // A deadline timeout(1) will actually enforce. Without --kill-after it sends
  // SIGTERM and then waits indefinitely, so a child that ignores the signal
  // outlives its own deadline -- measured at 30s against a 3s limit. The grace
  // period then escalates to SIGKILL. Omarchy's own scripts use the same form.
  readonly property string launcherKillAfter: "--kill-after=5s"
  // Generous: the spawn returns in well under a second, so this only fires if
  // setsid itself never comes back.
  readonly property string launcherDeadlineSec: "15"
  // A live ceiling on what a child may hand back.
  //
  // The deadline bounds how long a process runs; this bounds how much it can
  // return while running. StdioCollector exposes no cap of its own, but with
  // waitForEnd false it emits dataChanged as the buffer grows, so the size can
  // be checked as it arrives and the process killed the moment it goes over --
  // rather than discovering it after the whole thing has been buffered. The
  // text is still complete at onExited for a process that finishes normally.
  //
  // 64 KiB is far above anything these can legitimately produce: the probes
  // emit a fixed set of JSON keys with capped fields, measured at a little over
  // 200 bytes. It is a ceiling on runaway output, not a working limit.
  readonly property int maxChildBytes: 65536
  property bool _statusCapped: false
  property bool _firewallCapped: false
  property bool _actionCapped: false

  readonly property string probeKillAfter: "--kill-after=5s"
  readonly property string actionKillAfter: "--kill-after=10s"

  // Every child process gets a hard deadline, so a wedged helper cannot leave
  // this plugin busy forever inside the long-running shell process. timeout(1)
  // sends SIGTERM at the deadline and exits 124, which the handlers below
  // report as a timeout rather than a command failure.
  //
  // The probes are read-only and measured at 40ms and 130ms; ten seconds is
  // three orders of magnitude of headroom and only fires if something is
  // genuinely stuck.
  readonly property string probeDeadlineSec: "10"

  // Actions need a much larger budget, because a legitimate one can block for
  // a long time and cutting it short would report a false failure. Starting
  // the receiver waits on the unit's ExecStartPre audio gate (up to 45s), and
  // systemd's own DefaultTimeoutStartSec is 90s, with TimeoutStopSec=10 on
  // stop -- so a restart can legitimately take about 100 seconds. 150 is
  // beyond anything systemd will allow to continue, so it bounds the wait
  // without ever pre-empting a real one.
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
  // The quiet case: ufw is not ruling on IPv6 while the network offers it.
  // Nothing is "missing" from ufw's point of view, so it needs its own flag.
  property bool firewallIpv6Ignored: false

  // The clock-sync service AirPlay 2 needs, and whether the receiver is
  // actually accepting connections. Both are reported by airplay-status; the
  // defaults keep a first poll from flashing a warning.
  property bool nqptpActive: true
  property bool listening: true

  // The states the popup cannot fix in place, only advise Repair for. Guarded
  // on `probed` and running so an off receiver never raises them.
  readonly property bool clockSyncDown: probed && setupComplete
    && effectiveRunning && !nqptpActive
  readonly property bool notListening: probed && setupComplete
    && effectiveRunning && !listening

  // One flag for "this cannot do its job", used by the status line so the
  // popup never reads READY next to a warning. The only fix is Repair, so the
  // flag is about honesty, not about which action to offer.
  readonly property bool needsRepair: !firewallOk
    || (probed && setupComplete && effectiveRunning
        && (!nqptpActive || !listening || audioStalled))

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
    if (needsRepair) return "Needs repair"
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

    // Bounded like the rest. A notification is a short D-Bus call, and unlike
    // the setup terminal there is nothing interactive to protect, so the
    // deadline can sit directly on it.
    var args = [binTimeout, probeKillAfter, probeDeadlineSec,
                binNotifySend, "-a", "OmairPlay"]
    var art = String(artUrl || "")
    if (art.indexOf("file://") === 0)
      args.push("-i", decodeURIComponent(art.substring(7)))
    args.push(title !== "" ? title : "AirPlay")

    var sub = []
    if (artist !== "") sub.push(artist)
    if (album !== "" && album !== title) sub.push(album)
    args.push(sub.join("  \u00b7  "))

    Quickshell.execDetached({
      command: args,
      clearEnvironment: true,
      environment: sealedEnv
    })
  }

  Component.onCompleted: _serviceLoadedAt = Date.now()

  // "Title - Artist", or as much of it as there is.
  readonly property string trackLine: {
    if (!hasTrack) return ""
    if (title !== "" && artist !== "") return title + "  -  " + artist
    return title !== "" ? title : artist
  }

  // Whether a shairport-sync stream is actually feeding PipeWire. The control
  // channel can be up while the audio path is dead -- a blocked IPv6 prefix,
  // or a PulseAudio instance that restarted under the receiver -- and that is
  // the "shows the track and plays nothing" state. The node exists only while
  // audio flows, so its absence while MPRIS says playing is the signal.
  //
  // Same match as LevelMeter.qml: which field carries the name depends on how
  // the stream was created, so check all of them.
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

  // A few seconds of grace: the stream appears a beat after playback starts,
  // and a false alarm would send someone to Repair for nothing.
  property bool audioStalled: false
  Timer {
    id: audioStallTimer
    interval: 4000
    repeat: false
    running: root.probed && root.setupComplete && root.effectiveRunning
             && root.playing && root.hasTrack && !root.audioStreamUp
    onTriggered: root.audioStalled = true
  }
  onAudioStreamUpChanged: if (audioStreamUp) audioStalled = false
  onPlayingChanged: if (!playing) audioStalled = false
  onEffectiveRunningChanged: if (!effectiveRunning) audioStalled = false

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

  // Applies a config written while the receiver was already up. Interrupts
  // playback, so the popup only offers it rather than doing it automatically.
  function restart() {
    if (busy || !setupComplete) return
    runAction("restart", [binSystemctl, "--user", "restart", unit])
  }

  function setStartAtLogin(enabled) {
    if (busy || !setupComplete) return
    runAction(enabled ? "enable" : "disable",
              [binSystemctl, "--user", enabled ? "enable" : "disable", unit])
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
    // Two argv arrays rather than one shell string. This used to hand
    // "set -e; write-config --name <name>; systemctl restart <unit>" to
    // bash -c, which meant building a command line around a name the user
    // typed and relying on the quoting to hold. runSteps chains the two
    // commands instead, stopping if the first fails -- same effect as set -e,
    // with no shell involved and nothing to quote.
    var steps = [[pluginDir + "/bin/airplay-write-config", "--name", wanted]]
    if (restartIfRunning && running)
      steps.push([binSystemctl, "--user", "restart", unit])
    runSteps("name", steps)
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
    launchInTerminal(Util.shellQuote(pluginDir + "/bin/airplay-remove") + " --system")
  }

  // Reverts the receiver and sets it up again, in one terminal. Both halves
  // run as the user; sudo's per-tty credential cache means one prompt covers
  // the whole repair in the common case. The script restores the unit's prior
  // enabled/running state afterwards, which removal alone would drop.
  function runRepair() {
    if (busy) return
    launchInTerminal(Util.shellQuote(pluginDir + "/bin/airplay-repair"))
  }

  // Sealed like everything else here, and this one matters most: it is the
  // entry point to the privileged setup and removal.
  //
  // The launcher is an Omarchy script that `source`s omarchy-restart-gum and
  // calls setsid, uwsm-app, xdg-terminal-exec, bash, omarchy-show-logo and
  // omarchy-show-done by bare name. Handed an inherited PATH, a file planted
  // earlier in it runs -- a `source`, so arbitrary code in the launcher's own
  // shell -- before the setup script exists to seal anything. Sealing only our
  // own scripts left that open, on the one path that asks for a password.
  //
  // Bounded, but around setsid rather than around the launcher directly.
  //
  // A timeout placed straight on the launcher reaches the terminal: uwsm-app
  // stays in the foreground, so the deadline lands on the session and kills it.
  // Measured -- the command inside started, then died at the deadline, which in
  // practice means setup cut off while the password prompt is open.
  //
  // setsid forks and its parent returns at once, so the deadline applies to the
  // spawn and the session continues in a new session of its own. Measured the
  // same way: exit 0 in under a second, terminal still alive well past the
  // deadline.
  //
  // Being straight about what this bounds: the spawn, not the session. An
  // interactive terminal someone is typing a password into cannot be given a
  // time limit, and should not be. What it prevents is a wedged spawn sitting
  // around for ever.
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

  // Several commands in order, stopping at the first failure. `pendingAction`
  // stays set for the whole chain, so `busy` and `actionLabel` describe the
  // operation rather than whichever step happens to be in flight.
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
        root.configStale = !!s.config_stale
        root.nqptpActive = s.nqptp !== false
        root.listening = s.listening !== false
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
      if (root._firewallCapped) { root._firewallCapped = false; return }
      if (exitCode !== 0) return
      try {
        var f = JSON.parse(String(firewallOut.text || "{}"))
        root.firewallOk = !!f.ok
        root.firewallReason = String(f.reason || "")
        root.firewallMissing = f.missing instanceof Array ? f.missing : []
        root.firewallIpv6Ignored = !!f.ipv6_ignored
      } catch (e) {
        // Leave the last known answer alone rather than claim a problem.
      }
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
        // More to do, and the last step succeeded. Start the next one outside
        // this handler rather than restarting the process from inside its own
        // exit signal.
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
