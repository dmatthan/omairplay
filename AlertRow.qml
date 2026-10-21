import QtQuick
import qs.Commons
import qs.Ui

// A wrapped warning inside the popup, optionally with the action that fixes
// it on the right, so the fix sits where the problem is named.
Item {
  id: root

  property string text: ""
  property bool urgent: false
  property string actionText: ""
  property bool hasCursor: false
  property color foreground: Color.foreground
  property color urgentColor: Color.urgent
  property string fontFamily: Style.font.family

  signal actionClicked()

  readonly property color tint: urgent ? urgentColor : Qt.darker(foreground, 1.25)
  readonly property int pad: Style.space(8)

  implicitHeight: visible
    ? Math.max(body.implicitHeight, action.visible ? action.implicitHeight : 0) + 2 * pad
    : 0

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: Util.alpha(root.tint, 0.10)
    border.width: 1
    border.color: Util.alpha(root.tint, 0.35)
  }

  Text {
    id: body
    x: root.pad
    width: parent.width - 2 * root.pad - (action.visible ? action.width + root.pad : 0)
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: root.text
    color: root.tint
    wrapMode: Text.WordWrap
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Button {
    id: action
    visible: root.actionText !== ""
    anchors.right: parent.right
    anchors.rightMargin: root.pad
    anchors.verticalCenter: parent.verticalCenter
    text: root.actionText
    bordered: true
    foreground: root.foreground
    fontFamily: root.fontFamily
    hasCursor: root.hasCursor
    onClicked: root.actionClicked()
  }
}
