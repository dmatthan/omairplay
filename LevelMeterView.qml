import QtQuick
import QtQuick.Window
import qs.Commons

// Level history mirrored about a centre line, newest on the right. Asks for a
// sample through sampleNeeded() each time it has scrolled one bar, and draws
// what push(level) gives it.
//
// Amplitude only. There is no frequency data to draw a spectrum from, so this
// shows what the level is actually doing rather than inventing bands.
Item {
  id: root

  property color foreground: Color.foreground
  property color accent: Color.accent
  property color muted: Color.muted
  property bool running: false

  signal sampleNeeded()

  // Geometry is worked out in physical pixels, then divided back into logical
  // ones. Anything fractional in physical pixels -- which fractional monitor
  // scaling and the shell's UI scale both produce -- makes bars straddle the
  // pixel grid unevenly: wider ones form light bands, and a scroll that moves a
  // non-whole number of pixels shimmers as every bar's antialiasing changes
  // from frame to frame.
  readonly property real dpr: Math.max(1, Screen.devicePixelRatio)
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

  // Motion: a whole number of physical pixels, on a whole number of frames.
  // Roughly a pixel per frame at 60 Hz; on a faster display the same step is
  // taken every second or third frame, and on a dense display the step is
  // larger, so the speed stays near 60 physical pixels a second everywhere and
  // every move is identical. Anything much faster than half a bar's pitch per
  // step and the regular pattern of bars strobes.
  readonly property int stepPx: Math.max(1, Math.round(dpr))
  property real _frameSeconds: 1 / 60
  // 60 and 75 Hz step every frame, 120 and 144 Hz every second, 165 and above
  // every third. Biased so the switch falls between common refresh rates rather
  // than on one, where a jittery estimate would flip it back and forth.
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

  // Tuned against a recording of real AirPlay music, with vocal-band energy as
  // the reference for what the meter should follow, at one bar every 1/12 s.
  // The bar length depends on scale and refresh rate, so rates and the history
  // length are converted to give the same time constants at the actual length.
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

  // Height is the level placed within this song's own recent range: the 10th
  // to 95th percentile of the last twenty seconds. A quieter verse sits lower
  // than the chorus and a vocal that swells rises with it, which a measure of
  // change against a short average cannot show -- it re-centres on each new
  // level within a couple of seconds and flattens exactly those shifts.
  //
  // Percentiles rather than extremes, so one loud hit cannot pin the scale. A
  // three dB minimum span, so a heavily limited master still moves instead of
  // drawing a wall. Silence clears the range: each song is judged on its own.
  //
  // The bottom of the range sits at a quarter height, not at rest, and anything
  // quieter compresses into the space below it, so a soft passage still ripples.
  // Only silence rests.
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

  // The high swings glow in the accent itself: lighter on a dark theme, deeper
  // on a light one.
  readonly property color glow: foreground.hslLightness < 0.5
    ? Qt.darker(accent, 1.6) : Qt.lighter(accent, 1.45)

  function colourFor(v) {
    var c = Qt.tint(muted, Qt.rgba(accent.r, accent.g, accent.b, 0.45 + 0.55 * v))
    var g = Math.max(0, Math.min(1, (v - 0.72) / 0.24))
    return g > 0 ? Qt.tint(c, Qt.rgba(glow.r, glow.g, glow.b, 0.75 * g)) : c
  }

  // Driven by the frame clock rather than a timer, counting frames rather than
  // accumulating time, so every step is the same size and lands on the same
  // cadence. Frame time is only used to learn the refresh rate.
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

    Repeater {
      model: root.barCount + 1

      Item {
        id: slot
        readonly property real v: root.levels[index] || 0
        readonly property int px: Math.max(root.restPx, Math.round(root.halfPx * v))
        readonly property color colour: root.colourFor(v)

        x: (index * root.pitchPx - root.offsetPx) / root.dpr
        width: root.barPx / root.dpr
        height: root.height
        opacity: 0.4 + 0.6 * (index / root.barCount)

        // Rounded themes get a stepped tip at both ends of each bar, one pixel
        // step in from each side, instead of a smoothed radius. At this size an
        // antialiased curve is only a blur; whole pixels keep the ends crisp.
        readonly property int tipPx: Style.cornerRadius > 0 && px >= 3 * root.tipStepPx ? root.tipStepPx : 0

        Repeater {
          model: [root.halfPx - slot.px, root.halfPx + root.centrePx]

          Item {
            required property int modelData
            y: modelData / root.dpr
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
