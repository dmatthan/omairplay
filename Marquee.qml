import QtQuick
import QtQuick.Effects
import qs.Commons

// One line that scrolls to its end and back when it does not fit, pausing at
// each end. The edges fade only where text is hidden. Moves in whole physical
// pixels so the text does not shimmer.
Item {
  id: root

  default property alias content: row.data
  property bool running: true
  property real speed: 30      // logical pixels per second
  property int pause: 1600     // ms at each end

  readonly property real overflow: Math.max(0, Math.ceil(row.implicitWidth - width))
  readonly property real dpr: Window.window ? Window.window.devicePixelRatio : 1
  readonly property int fadeWidth: Style.space(14)
  property real offset: 0

  implicitHeight: row.implicitHeight
  clip: true

  onOverflowChanged: restart()
  onRunningChanged: restart()

  function restart() {
    scroll.stop()
    offset = 0
    if (running && overflow > 0) scroll.start()
  }

  Item {
    id: viewport
    anchors.fill: parent
    visible: root.overflow === 0
    layer.enabled: root.overflow > 0

    Row {
      id: row
      x: -Math.round(root.offset * root.dpr) / root.dpr
      height: parent.height
    }
  }

  MultiEffect {
    anchors.fill: viewport
    source: viewport
    visible: root.overflow > 0
    maskEnabled: true
    maskSource: mask
  }

  Item {
    id: mask
    anchors.fill: parent
    visible: false
    layer.enabled: true

    Rectangle {
      id: fade
      anchors.fill: parent
      readonly property real edge: root.width > 0 ? root.fadeWidth / root.width : 0
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0; color: root.offset > 0.5 ? "transparent" : "white" }
        GradientStop { position: fade.edge; color: "white" }
        GradientStop { position: 1 - fade.edge; color: "white" }
        GradientStop { position: 1; color: root.offset < root.overflow - 0.5 ? "transparent" : "white" }
      }
    }
  }

  SequentialAnimation {
    id: scroll
    loops: Animation.Infinite
    readonly property int travel: Math.max(1, Math.round(root.overflow / root.speed * 1000))
    PauseAnimation { duration: root.pause }
    NumberAnimation { target: root; property: "offset"; from: 0; to: root.overflow; duration: scroll.travel; easing.type: Easing.InOutSine }
    PauseAnimation { duration: root.pause }
    NumberAnimation { target: root; property: "offset"; from: root.overflow; to: 0; duration: scroll.travel; easing.type: Easing.InOutSine }
  }
}
