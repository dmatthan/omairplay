import QtQuick
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

  // Whole pixels throughout. With a fractional pitch each bar straddles the
  // pixel grid differently, and the wider ones form light bands that stand
  // still while the waveform moves.
  readonly property int barWidth: Math.max(2, Style.space(3))
  readonly property int gap: Math.max(1, Style.space(2))
  readonly property int pitch: barWidth + gap
  readonly property int barCount: Math.max(1, Math.floor((width + gap) / pitch))
  readonly property int rowWidth: barCount * pitch - gap
  readonly property int centreGap: Math.max(1, Style.space(2))
  readonly property int halfHeight: Math.max(1, Math.floor((height - centreGap) / 2))
  readonly property int restHeight: Math.max(1, Style.space(2))

  // One bar every 5 frames at 60 Hz: exactly one pixel of scroll per frame.
  // Faster than about half a bar's pitch per frame and the regular pattern of
  // bars strobes, because the eye can no longer tell which way it is moving.
  readonly property real barMs: 1000 * 5 / 60
  readonly property real speed: pitch / (barMs / 1000)

  implicitHeight: Style.space(44)

  property var leftLevels: blank()
  property var rightLevels: blank()
  property real offset: 0

  onBarCountChanged: reset()

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
    offset = 0
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
  // Tuned against real peak levels recorded from an AirPlay stream, at this bar
  // rate: rates below are per bar.
  function levelFor(channel, peak) {
    var x = toDb(peak)
    var st = _state[channel]
    if (x < silenceDb) {
      _state[channel] = null
      return 0
    }
    if (st === null) st = { e: x, m: x, s: 1.2 }
    st.e += (x - st.e) * (x > st.e ? 0.9 : 0.45)
    st.m += (st.e - st.m) * 0.03
    st.s += (Math.abs(st.e - st.m) - st.s) * 0.08
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

  // Driven by the frame clock rather than a timer, so the scroll advances the
  // same distance every frame and asks for a sample exactly when it has moved
  // one bar.
  //
  // Frame times jitter around the refresh interval, so a raw advance of
  // speed * frameTime lands just short of a whole pixel now and then and the
  // scroll stalls for a frame. Where the smoothed advance is within a whisker of
  // a whole pixel -- exactly one at 60 Hz -- it is taken as that, and the row
  // moves the same distance every frame.
  property real _frameSeconds: 1 / 60
  FrameAnimation {
    running: root.running && root.barCount > 1
    onTriggered: {
      root._frameSeconds += (Math.min(frameTime, 0.1) - root._frameSeconds) * 0.05
      var step = root.speed * root._frameSeconds
      if (Math.abs(step - Math.round(step)) < 0.1) step = Math.round(step)
      root.offset += step
      while (root.offset >= root.pitch) {
        root.offset -= root.pitch
        root.sampleNeeded()
      }
    }
  }

  Item {
    x: Math.floor((root.width - root.rowWidth) / 2)
    width: root.rowWidth
    height: root.height
    clip: true

    Repeater {
      model: root.barCount + 1

      Item {
        id: slot
        readonly property real lv: root.leftLevels[index] || 0
        readonly property real rv: root.rightLevels[index] || 0

        x: index * root.pitch - Math.round(root.offset)
        width: root.barWidth
        height: root.height
        opacity: 0.4 + 0.6 * (index / root.barCount)

        readonly property real corner: Style.cornerRadius > 0 ? width / 2 : 0

        Rectangle {
          width: parent.width
          height: Math.max(root.restHeight, Math.round(root.halfHeight * slot.lv))
          y: root.halfHeight - height
          radius: Math.min(slot.corner, height / 2)
          color: root.colourFor(slot.lv)
        }

        Rectangle {
          width: parent.width
          height: Math.max(root.restHeight, Math.round(root.halfHeight * slot.rv))
          y: root.halfHeight + root.centreGap
          radius: Math.min(slot.corner, height / 2)
          color: root.colourFor(slot.rv)
        }
      }
    }
  }
}
