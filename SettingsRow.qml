import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The row that opens and closes the popup's settings. The chevron turns down
// while they are shown.
Item {
  id: root

  property bool expanded: false
  property bool hasCursor: false
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family

  signal clicked()

  implicitHeight: button.implicitHeight

  Button {
    id: button
    width: parent.width
    text: "Settings"
    leftAlign: true
    foreground: root.foreground
    fontFamily: root.fontFamily
    hasCursor: root.hasCursor
    onClicked: root.clicked()
  }

  Text {
    anchors.right: parent.right
    anchors.rightMargin: Style.spacing.controlPaddingX
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: "󰅂"  // U+F0142 md-chevron-right
    rotation: root.expanded ? 90 : 0
    color: Qt.darker(root.foreground, 1.4)
    font.family: root.fontFamily
    font.pixelSize: Style.font.icon
    Behavior on rotation { NumberAnimation { duration: 140; easing.type: Easing.OutQuad } }
  }
}
