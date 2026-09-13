import QtQuick
import QtQuick.Window
import qs.Commons

// Stereo level history: left channel above the centre line, right below,
// newest on the right. Asks for a sample through sampleNeeded() whenever it has
// scrolled one bar, and draws what push(left, right) gives it.
//
// Amplitude only. There is no frequency data to draw a spectrum from, so this
// shows what the peaks are actually doing rather than inventing bands.
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

  property var leftLevels: blank()
  property var rightLevels: blank()
  property int offsetPx: 0
  property int _frames: 0

  onBarCountChanged: reset()
  onPitchPxChanged: reset()

  function blank() {
    var a = []
    for (var i = 0; i <= barCount; i++) a.push(0)
    return a
  }

  // Per channel: a smoothed envelope in dB, its recent average, and how much it
  // has recently been moving.
  property var _state: [null, null]
  readonly property real silenceDb: -54

  function reset() {
    leftLevels = blank(); rightLevels = blank()
    _state = [null, null]
    offsetPx = 0
  }

  function toDb(p) {
    return 20 * Math.log(Math.max(p, 1e-5)) / Math.LN10
  }

  // Mastered music moves only a few dB from one moment to the next, so mapping
  // level onto height directly gives a wall of near-identical bars. Instead this
  // measures how far the envelope sits from its own recent average, relative to
  // how much it has been moving lately, and eases that through tanh around the
  // middle. The meter undulates the same whether the source is loud, quiet,
  // compressed or dynamic, and never flattens against the top.
  //
  // Tuned against real peak levels recorded from an AirPlay stream, with one bar
  // every 1/12 s. The bar length now depends on scale and refresh rate, so each
  // rate is converted to what gives the same time constant at the actual length.
  function rate(perReferenceBar) {
    return 1 - Math.pow(1 - perReferenceBar, barSeconds / (5 / 60))
  }

  function levelFor(channel, peak) {
    var x = toDb(peak)
    var st = _state[channel]
    if (x < silenceDb) {
      _state[channel] = null
      return 0
    }
    if (st === null) st = { e: x, m: x, s: 1.2 }
    st.e += (x - st.e) * rate(x > st.e ? 0.9 : 0.45)
    st.m += (st.e - st.m) * rate(0.03)
    st.s += (Math.abs(st.e - st.m) - st.s) * rate(0.08)
    _state[channel] = st
    var z = (st.e - st.m) / (1.4 * Math.max(st.s, 0.6))
    return 0.52 + 0.44 * Math.tanh(z)
  }

  function push(l, r) {
    var nl = leftLevels.slice(1);  nl.push(levelFor(0, l))
    var nr = rightLevels.slice(1); nr.push(levelFor(1, r))
    leftLevels = nl; rightLevels = nr
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
        readonly property real lv: root.leftLevels[index] || 0
        readonly property real rv: root.rightLevels[index] || 0

        x: (index * root.pitchPx - root.offsetPx) / root.dpr
        width: root.barPx / root.dpr
        height: root.height
        opacity: 0.4 + 0.6 * (index / root.barCount)

        readonly property real corner: Style.cornerRadius > 0 ? width / 2 : 0

        Rectangle {
          readonly property int px: Math.max(root.restPx, Math.round(root.halfPx * slot.lv))
          width: parent.width
          height: px / root.dpr
          y: (root.halfPx - px) / root.dpr
          radius: Math.min(slot.corner, height / 2)
          color: root.colourFor(slot.lv)
        }

        Rectangle {
          readonly property int px: Math.max(root.restPx, Math.round(root.halfPx * slot.rv))
          width: parent.width
          height: px / root.dpr
          y: (root.halfPx + root.centrePx) / root.dpr
          radius: Math.min(slot.corner, height / 2)
          color: root.colourFor(slot.rv)
        }
      }
    }
  }
}
