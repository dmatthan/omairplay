import QtQuick
import Quickshell.Services.Pipewire
import qs.Commons

// Feeds LevelMeterView from the receiver's own PipeWire stream.
//
// Gated on the popup being open: with `active` false the peak monitor is off,
// the timer stops and the history clears, so nothing here costs anything while
// the popup is shut. Service.qml does not know this exists.
Item {
  id: root

  property bool active: false
  property color foreground: Color.foreground
  property color accent: Color.accent

  // Present only while the receiver is streaming: PipeWire creates the node
  // when playback starts and drops it when it stops.
  readonly property var streamNode: findStream()
  readonly property bool live: active && streamNode !== null

  implicitHeight: view.implicitHeight
  visible: live
  opacity: live ? 1 : 0
  Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutQuad } }

  // Match on anything that identifies shairport-sync, because which field
  // carries the name depends on how the stream was created. Required: this
  // machine has other playback streams (EQ and surround sinks) that must not
  // drive the meter.
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
      // For a stream, isSink means it feeds audio into the graph: playback.
      if (n.isSink !== true) continue
      if (looksLikeOurs(n)) return n
    }
    return null
  }

  // Without this the node's properties are not kept live.
  PwObjectTracker { objects: root.streamNode ? [root.streamNode] : [] }

  // The loudest peak per channel since the last tick. PipeWire reports more
  // often than the meter draws, so keeping the maximum rather than whatever
  // value happens to be current is what makes short transients show up.
  property real _left: 0
  property real _right: 0
  property bool _fresh: false
  property real _lastLeft: 0
  property real _lastRight: 0

  function clamp(v) {
    return isFinite(v) ? Math.max(0, Math.min(1, v)) : 0
  }

  PwNodePeakMonitor {
    node: root.streamNode
    enabled: root.live
    onPeaksChanged: {
      var p = peaks
      if (!p || p.length === 0) return
      var l = root.clamp(p[0])
      var r = root.clamp(p.length > 1 ? p[1] : p[0])
      if (l > root._left) root._left = l
      if (r > root._right) root._right = r
      root._fresh = true
    }
  }

  onLiveChanged: if (!live) view.reset()

  LevelMeterView {
    id: view
    anchors.fill: parent
    running: root.live
    foreground: root.foreground
    accent: root.accent
    // No report since the last bar: repeat the last values rather than draw a
    // gap that was never in the audio.
    onSampleNeeded: {
      if (root._fresh) {
        root._lastLeft = root._left
        root._lastRight = root._right
      }
      view.push(root._lastLeft, root._lastRight)
      root._left = 0
      root._right = 0
      root._fresh = false
    }
  }
}
