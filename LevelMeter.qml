import QtQuick
import Quickshell.Services.Pipewire
import qs.Commons

// Feeds LevelMeterView from the receiver's own PipeWire stream, only while the
// popup is open. Hidden, not drawn flat, while there are no levels to give.
Item {
  id: root

  property bool active: false
  property color foreground: Color.foreground
  property color accent: Color.accent

  // Exists only while the receiver is streaming.
  readonly property var streamNode: findStream()
  readonly property bool live: active && streamNode !== null

  // Whether the monitor has produced any level for this stream: Quickshell 0.3.1
  // reports nothing for a stream upmixed into a wider sink (quickshell#1147).
  // Judged on values, since a silent passage stops reports too.
  property bool _heardAudio: false
  readonly property bool delivering: live && _heardAudio

  implicitHeight: visible ? view.implicitHeight : 0
  visible: delivering
  opacity: delivering ? 1 : 0
  Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutQuad } }

  // Which field names shairport-sync depends on how the stream was created;
  // other playback streams must not drive the meter.
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

  // Mean peak since the last bar: it follows vocals better than the maximum.
  property real _sum: 0
  property int _count: 0
  property real _last: 0

  function clamp(v) {
    return isFinite(v) ? Math.max(0, Math.min(1, v)) : 0
  }

  // Any channel: a virtual sink can carry the audio outside front left/right.
  function anyPeak(list) {
    for (var i = 0; i < list.length; i++) if (list[i] > 0) return true
    return false
  }

  PwNodePeakMonitor {
    node: root.streamNode
    enabled: root.live
    onPeaksChanged: {
      var p = peaks
      if (!p || p.length === 0) return
      var l = root.clamp(p[0])
      var r = root.clamp(p.length > 1 ? p[1] : p[0])
      root._sum += (l + r) / 2
      root._count++
      if (root.anyPeak(p)) root._heardAudio = true
    }
    // A renegotiated capture is a different graph: judge its levels afresh.
    onChannelsChanged: root._heardAudio = false
  }

  onLiveChanged: if (!live) { root._heardAudio = false; view.reset() }

  LevelMeterView {
    id: view
    anchors.fill: parent
    running: root.live
    foreground: root.foreground
    accent: root.accent
    // No report since the last bar: repeat the last value, never draw a gap.
    onSampleNeeded: {
      if (root._count > 0) root._last = root._sum / root._count
      view.push(root._last)
      root._sum = 0
      root._count = 0
    }
  }
}
