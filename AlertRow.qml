import QtQuick
import qs.Commons

// A single wrapped warning line inside the popup. Two of these carry the
// problems that would otherwise make the plugin look broken for no visible
// reason: another shairport-sync holding the AirPlay 2 slot, and the firewall
// letting discovery through while blocking the connection.
Item {
  id: root

  property string text: ""
  property bool urgent: false
  property color foreground: Color.foreground
  property color urgentColor: Color.urgent
  property string fontFamily: Style.font.family

  readonly property color tint: urgent ? urgentColor : Qt.darker(foreground, 1.25)

  implicitHeight: visible ? body.implicitHeight + Style.space(12) : 0

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: Util.alpha(root.tint, 0.10)
    border.width: 1
    border.color: Util.alpha(root.tint, 0.35)
  }

  Text {
    id: body
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(8)
    anchors.rightMargin: Style.space(8)
    text: root.text
    color: root.tint
    wrapMode: Text.WordWrap
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
