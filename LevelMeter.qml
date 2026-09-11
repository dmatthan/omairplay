import QtQuick
import Quickshell.Services.Pipewire
import qs.Commons

// A level meter driven by the receiver's actual audio.
//
// Deliberately a level *history* rather than a spectrum. Quickshell exposes
// PwNodePeakMonitor, which gives amplitude — not frequency content — so bars
// spread across a frequency axis would be invented data. The same reasoning
// that keeps transport controls out of this plugin applies here: a graph that
// looks like it means something it doesn't is worse than no graph. This shows
// the last couple of seconds of real level, scrolling right to left.
//
// Lives in its own file, and entirely on the presentation side, because it is
// gated on the popup being open — which is a widget concern, not session
// state. Service.qml does not know or care that this exists.
Item {
  id: root

  // Set false and the peak monitor is switched off, the timer stops and the
  // history is cleared. Nothing here costs anything while the popup is shut.
  property bool active: false
  property color foreground: Color.foreground
  property color accent: Color.accent

  readonly property int barCount: 28
  readonly property real barGap: Math.max(1, Style.space(2))

  // Present only while the receiver is actually streaming: PipeWire creates the
  // stream node when playback starts and drops it when it stops.
  readonly property var streamNode: findStream()
  readonly property bool live: active && streamNode !== null

  implicitHeight: Style.space(26)
  visible: live
  opacity: live ? 1 : 0
  Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutQuad } }

  property var levels: emptyLevels()
  property real _smoothed: 0

  // Peak is a linear amplitude, and peak over a 40ms window of music barely
  // moves -- measured on a real AirPlay stream it sat between 0.38 and 0.65.
  // Plotted linearly, or over a wide dB window, every bar comes out the same
  // height. So map it the way audio meters do -- to decibels -- but over a
  // deliberately narrow window, with a gamma that spreads the band music
  // actually occupies across the full height:
  //
  //   peak 1.00 -> 1.00      peak 0.50 -> 0.40
  //   peak 0.80 -> 0.78      peak 0.38 -> 0.24
  //   peak 0.65 -> 0.60      below -18dB -> 0
  //
  // This is undulation, not a dancing spectrum. Those need frequency
  // separation, and amplitude on its own cannot provide it.
  readonly property real floorDb: -18
  function normalise(peak) {
    if (!(peak > 0)) return 0
    var db = 20 * Math.log(Math.max(peak, 1e-4)) / Math.LN10
    var n = (db - floorDb) / -floorDb
    if (n < 0) n = 0
    if (n > 1) n = 1
    return Math.pow(n, 2.2)
  }

  function emptyLevels() {
    var a = []
    for (var i = 0; i < barCount; i++) a.push(0)
    return a
  }

  // Match on anything that identifies shairport-sync, because which field
  // carries the name depends on how the stream was created. Checked
  // case-insensitively across the node's own labels and its PipeWire
  // properties.
  function looksLikeOurs(node) {
    var candidates = [node.name, node.nickname, node.description]
    var props = node.properties
    if (props) {
      candidates.push(props["application.name"],
                      props["application.process.binary"],
                      props["node.name"],
                      props["media.name"])
    }
    for (var i = 0; i < candidates.length; i++) {
      if (String(candidates[i] || "").toLowerCase().indexOf("shairport") !== -1)
        return true
    }
    return false
  }

  function findStream() {
    var nodes = Pipewire.nodes ? Pipewire.nodes.values : []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || !n.isStream || !n.audio) continue
      // For a stream, isSink means it feeds audio into the graph, i.e. playback.
      if (n.isSink !== true) continue
      if (looksLikeOurs(n)) return n
    }
    return null
  }

  // Without this the node's properties are not kept live by Quickshell. Same
  // pattern the first-party audio panel and media service use.
  PwObjectTracker { objects: root.streamNode ? [root.streamNode] : [] }

  PwNodePeakMonitor {
    id: peakMonitor
    node: root.streamNode
    enabled: root.live
  }

  // Sampled on a timer rather than bound to `peak`, so the bars are evenly
  // spaced in time however often PipeWire happens to report.
  Timer {
    interval: 40
    repeat: true
    running: root.live
    onTriggered: {
      var p = peakMonitor.peak
      if (!isFinite(p) || p < 0) p = 0
      if (p > 1) p = 1
      // Rise immediately, fall gently. That asymmetry is what makes a meter
      // readable instead of a flicker.
      var v = normalise(p)
      root._smoothed = Math.max(v, root._smoothed * 0.82)
      var next = root.levels.slice(1)
      next.push(root._smoothed)
      root.levels = next
    }
  }

  onLiveChanged: if (!live) { levels = emptyLevels(); _smoothed = 0 }

  Row {
    anchors.fill: parent
    spacing: root.barGap

    Repeater {
      model: root.barCount

      Rectangle {
        readonly property real level: {
          var v = root.levels[index]
          return (v === undefined || !isFinite(v)) ? 0 : Math.max(0, Math.min(1, v))
        }
        // A small floor so the strip reads as a meter at rest rather than
        // disappearing into the background.
        readonly property real minFraction: 0.06

        width: Math.max(1, (root.width - root.barGap * (root.barCount - 1)) / root.barCount)
        height: Math.max(1, root.height * (minFraction + level * (1 - minFraction)))
        anchors.bottom: parent.bottom
        radius: Style.cornerRadius > 0 ? Math.min(width / 2, Style.space(2)) : 0

        // Newest sample on the right at full strength, fading back through the
        // history. Reads as motion even in a still screenshot.
        color: root.foreground
        opacity: 0.30 + 0.60 * (index / Math.max(1, root.barCount - 1))

        Behavior on height {
          NumberAnimation { duration: 70; easing.type: Easing.OutQuad }
        }
      }
    }
  }
}
