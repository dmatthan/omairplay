import QtQuick
import QtQuick.Window
import qs.Commons
import qs.Commons as Commons

// Level history mirrored about a centre line, newest on the right. Asks for a
// sample via sampleNeeded() each time it scrolls one bar. Amplitude only.
Item {
  id: root

  // Qualified: with QtQuick.Window imported, a bare `Color` is QtQuick's helper.
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property color muted: Commons.Color.muted
  property bool running: false

  signal sampleNeeded()

  // Geometry in whole physical pixels, or bars straddle the grid and shimmer.
  // The window's ratio, not the screen's: under fractional scaling Screen
  // reports the integer scale. Window.devicePixelRatio is Qt 6.11+.
  readonly property real dpr: {
    var w = Window.window ? Window.window.devicePixelRatio : 0
    return Math.max(1, w > 0 ? w : Screen.devicePixelRatio)
  }
  readonly property int barPx: Math.max(2, Math.round(Style.space(3) * dpr))
  readonly property int gapPx: Math.max(1, Math.round(Style.space(2) * dpr))
  readonly property int pitchPx: barPx + gapPx
  readonly property int barCount: Math.max(1, Math.floor((width * dpr + gapPx) / pitchPx))
  readonly property int rowPx: barCount * pitchPx - gapPx
  readonly property int centrePx: Math.max(1, Math.round(Style.space(2) * dpr))
  readonly property int halfPx: Math.max(1, Math.floor((height * dpr - centrePx) / 2))
  readonly property int restPx: Math.max(1, Math.round(Style.space(2) * dpr))
  // A third of the bar, so the tip stays centred and in proportion at any scale.
  readonly property int tipStepPx: Math.floor(barPx / 3)

  // A whole number of physical pixels on a whole number of frames, so every
  // step is identical, at roughly 60 physical pixels a second on any display.
  readonly property int stepPx: Math.max(1, Math.round(dpr))
  property real _frameSeconds: 1 / 60
  // 60/75 Hz step every frame, 120/144 every second, 165+ every third; biased
  // between common rates so a jittery estimate cannot flip it.
  readonly property int frameStride: Math.max(1, Math.floor((1 / _frameSeconds) / 60 + 0.25))
  readonly property real barSeconds: pitchPx / stepPx * frameStride * _frameSeconds

  implicitHeight: Style.space(44)

  property var levels: blank()
  property int offsetPx: 0
  property int _frames: 0

  onBarCountChanged: reset()
  onPitchPxChanged: reset()

  function blank() {
    var a = []
    for (var i = 0; i <= barCount; i++) a.push(0)
    return a
  }

  readonly property real silenceDb: -54

  function reset() {
    levels = blank()
    _envelope = null
    _history = []
    offsetPx = 0
  }

  function toDb(p) {
    return 20 * Math.log(Math.max(p, 1e-5)) / Math.LN10
  }

  // Time constants tuned at one bar per 1/12 s, converted to the real bar length.
  function rate(perReferenceBar) {
    return 1 - Math.pow(1 - perReferenceBar, barSeconds / (5 / 60))
  }

  property var _envelope: null
  property var _history: []

  function percentile(sorted, pct) {
    var i = (sorted.length - 1) * pct / 100
    var lo = Math.floor(i), hi = Math.ceil(i)
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (i - lo)
  }

  // The level within this song's recent range (10th-95th percentile of the last
  // 20 s), so a quiet verse sits below the chorus. At least 3 dB of span; the
  // range bottom sits at a quarter height so soft passages still ripple; only
  // silence rests.
  function levelFor(peak) {
    var x = toDb(peak)
    if (x < silenceDb) {
      _envelope = null
      _history = []
      return 0
    }
    _envelope = _envelope === null ? x : _envelope + (x - _envelope) * (x > _envelope ? 1 : rate(0.5))
    var keep = Math.max(24, Math.round(20 / barSeconds))
    var h = _history
    h.push(_envelope)
    if (h.length > keep) h.splice(0, h.length - keep)
    var sorted = h.slice().sort(function(a, b) { return a - b })
    var lo = percentile(sorted, 10), hi = percentile(sorted, 95)
    var span = Math.max(hi - lo, 3)
    var centre = (hi + lo) / 2
    var t = (_envelope - (centre - span / 2)) / span
    var v = t >= 0 ? 0.25 + 0.7 * Math.min(1, t) : 0.25 + 0.15 * Math.max(-1, t)
    return Math.max(0.08, v)
  }

  function push(level) {
    var next = levels.slice(1)
    next.push(levelFor(level))
    levels = next
  }

  // High swings glow in the accent: lighter on dark themes, deeper on light.
  readonly property color glow: foreground.hslLightness < 0.5
    ? Qt.darker(accent, 1.6) : Qt.lighter(accent, 1.45)

  function colourFor(v) {
    var c = Qt.tint(muted, Qt.rgba(accent.r, accent.g, accent.b, 0.45 + 0.55 * v))
    var g = Math.max(0, Math.min(1, (v - 0.72) / 0.24))
    return g > 0 ? Qt.tint(c, Qt.rgba(glow.r, glow.g, glow.b, 0.75 * g)) : c
  }

  // Frame-counted rather than timed, so every step is the same size.
  FrameAnimation {
    running: root.running && root.barCount > 1
    onTriggered: {
      root._frameSeconds += (Math.min(Math.max(frameTime, 1 / 500), 0.1) - root._frameSeconds) * 0.05
      if (++root._frames < root.frameStride) return
      root._frames = 0
      root.offsetPx += root.stepPx
      while (root.offsetPx >= root.pitchPx) {
        root.offsetPx -= root.pitchPx
        root.sampleNeeded()
      }
    }
  }

  Item {
    x: Math.floor((root.width * root.dpr - root.rowPx) / 2) / root.dpr
    width: root.rowPx / root.dpr
    height: root.height
    clip: true

    // The bars sit still in this strip; only the strip moves each frame.
    Item {
      x: -root.offsetPx / root.dpr
      width: parent.width + root.pitchPx / root.dpr
      height: parent.height

      Repeater {
        model: root.barCount + 1

        Item {
          id: slot
          readonly property real v: root.levels[index] || 0
          readonly property int px: Math.max(root.restPx, Math.round(root.halfPx * v))
          readonly property color colour: root.colourFor(v)

          x: index * root.pitchPx / root.dpr
          width: root.barPx / root.dpr
          height: root.height
          opacity: 0.4 + 0.6 * (index / root.barCount)

          // Rounded themes get a stepped tip instead of a blurry antialiased radius.
          readonly property int tipPx: Style.cornerRadius > 0 && px >= 3 * root.tipStepPx ? root.tipStepPx : 0

          // Fixed items: a Repeater over the two halves rebuilt them every sample.
          Item {
            y: (root.halfPx - slot.px) / root.dpr
            width: parent.width
            height: slot.px / root.dpr

            Rectangle {
              x: slot.tipPx / root.dpr
              width: (root.barPx - 2 * slot.tipPx) / root.dpr
              height: parent.height
              color: slot.colour
            }

            Rectangle {
              y: slot.tipPx / root.dpr
              width: parent.width
              height: (slot.px - 2 * slot.tipPx) / root.dpr
              color: slot.colour
            }
          }

          Item {
            y: (root.halfPx + root.centrePx) / root.dpr
            width: parent.width
            height: slot.px / root.dpr

            Rectangle {
              x: slot.tipPx / root.dpr
              width: (root.barPx - 2 * slot.tipPx) / root.dpr
              height: parent.height
              color: slot.colour
            }

            Rectangle {
              y: slot.tipPx / root.dpr
              width: parent.width
              height: (slot.px - 2 * slot.tipPx) / root.dpr
              color: slot.colour
            }
          }
        }
      }
    }
  }
}
