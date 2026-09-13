import QtQuick
import qs.Commons

// Stereo level history: left channel above the centre line, right channel
// below, newest on the right. Feed it with push(left, right) once per tick.
//
// Amplitude only. There is no frequency data to draw a spectrum from, so this
// shows what the peaks are actually doing rather than inventing bands.
Item {
  id: root

  property color foreground: Color.foreground
  property color accent: Color.accent
  property color muted: Color.muted

  readonly property int tickMs: 40
  // Whole pixels throughout. With a fractional pitch each bar straddles the
  // pixel grid differently, some rendering a pixel wider than their
  // neighbours, and because the scroll replays the same sweep every tick those
  // wider bars form light bands that stand still while the waveform moves.
  readonly property int barWidth: Math.max(2, Style.space(3))
  readonly property int gap: Math.max(1, Style.space(2))
  readonly property int pitch: barWidth + gap
  readonly property int barCount: Math.max(1, Math.floor((width + gap) / pitch))
  readonly property int rowWidth: barCount * pitch - gap
  readonly property int centreGap: Math.max(1, Style.space(2))
  readonly property int halfHeight: Math.max(1, Math.floor((height - centreGap) / 2))
  // Quiet bars keep a sliver, so the meter reads as a meter at rest.
  readonly property int restHeight: Math.max(1, Style.space(2))

  implicitHeight: Style.space(44)

  // One more slot than is visible, so the scroll has something to reveal.
  property var leftLevels: blank()
  property var rightLevels: blank()
  property var punches: blank()
  property real phase: 0

  onBarCountChanged: reset()

  function blank() {
    var a = []
    for (var i = 0; i <= barCount; i++) a.push(0)
    return a
  }

  // Auto-ranging, in dB. The display maps [floor, ceiling] onto the full
  // height, so the picture is the same at any sending-device volume, and the
  // few dB music normally moves through fill the space instead of sitting in
  // a band near the top.
  property real _ceiling: -90
  property real _floor: -90
  property real _average: -90
  readonly property real minSpanDb: 10
  readonly property real silenceDb: -54

  function reset() {
    leftLevels = blank(); rightLevels = blank(); punches = blank()
    _ceiling = -90; _floor = -90; _average = -90
  }

  function toDb(p) {
    return 20 * Math.log(Math.max(p, 1e-5)) / Math.LN10
  }

  function push(l, r) {
    var dl = toDb(l), dr = toDb(r)
    var d = Math.max(dl, dr)

    if (_ceiling < silenceDb && d >= silenceDb) {
      // Coming out of silence: start from a sensible range rather than
      // spending seconds climbing out of the old one.
      _floor = d - minSpanDb * 1.4
      _average = d
    }
    // Ceiling jumps with a louder peak and eases back about 5 dB a second.
    _ceiling = Math.max(d, _ceiling - 0.2)
    // Floor follows the quieter moments: drops quickly, rises slowly.
    _floor += (d - _floor) * (d < _floor ? 0.3 : 0.015)

    var lo = Math.min(_floor, _ceiling - minSpanDb)
    var span = _ceiling - lo
    var silent = _ceiling < silenceDb

    // How far this moment stands above the recent average: beats, mostly.
    var onset = silent ? 0 : Math.max(0, Math.min(1, (d - _average) / 6))
    _average += (d - _average) * 0.1

    function level(x) {
      if (silent) return 0
      var t = (x - lo) / span
      if (t <= 0) return 0
      if (t >= 1) return 1
      return Math.pow(t, 1.15)
    }

    var lift = onset * 0.22
    var nl = leftLevels.slice(1);  nl.push(Math.min(1, level(dl) + lift))
    var nr = rightLevels.slice(1); nr.push(Math.min(1, level(dr) + lift))
    var np = punches.slice(1); np.push(onset)
    leftLevels = nl; rightLevels = nr; punches = np

    scroll.restart()
  }

  // Beats glow in the accent itself -- lighter on a dark theme, deeper on a light
  // one -- rather than towards the foreground, whose hue often differs.
  readonly property color glow: foreground.hslLightness < 0.5
    ? Qt.darker(accent, 1.6) : Qt.lighter(accent, 1.45)

  function colourFor(v, p) {
    var c = Qt.tint(muted, Qt.rgba(accent.r, accent.g, accent.b, 0.45 + 0.55 * v))
    return p > 0 ? Qt.tint(c, Qt.rgba(glow.r, glow.g, glow.b, 0.85 * p)) : c
  }

  // Each push shifts every value one slot left; starting the row one pitch to
  // the right and sliding it back over the tick turns that into a continuous
  // scroll instead of a step.
  NumberAnimation {
    id: scroll
    target: root
    property: "phase"
    from: 1
    to: 0
    duration: root.tickMs
  }

  // The row is centred in whatever width is left over, and clipped to itself so
  // bars scrolling in and out do not show in the margins.
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
        readonly property real pv: root.punches[index] || 0
        readonly property real age: index / root.barCount

        x: Math.round((index - 1 + root.phase) * root.pitch)
        width: root.barWidth
        height: root.height
        opacity: 0.4 + 0.6 * age

        readonly property real corner: Style.cornerRadius > 0 ? width / 2 : 0

        Rectangle {
          width: parent.width
          height: Math.max(root.restHeight, Math.round(root.halfHeight * slot.lv))
          y: root.halfHeight - height
          radius: Math.min(slot.corner, height / 2)
          color: root.colourFor(slot.lv, slot.pv)
        }

        Rectangle {
          width: parent.width
          height: Math.max(root.restHeight, Math.round(root.halfHeight * slot.rv))
          y: root.halfHeight + root.centreGap
          radius: Math.min(slot.corner, height / 2)
          color: root.colourFor(slot.rv, slot.pv)
        }
      }
    }
  }
}
