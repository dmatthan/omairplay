import QtQuick
import qs.Commons

// What the phone is playing: cover, title, artist | album and the sender's
// volume, with the level meter filling the space beside the cover so the
// block ends level with it.
Item {
  id: root

  property var svc: null
  property bool showArtwork: true
  property bool meterActive: false
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  readonly property color dim: Qt.darker(foreground, 1.25)
  readonly property color dimmer: Qt.darker(foreground, 1.7)
  readonly property int artSize: Style.space(88)
  readonly property int gap: Style.space(12)

  readonly property string title: svc && svc.title !== "" ? svc.title : "AirPlay"
  readonly property string artist: svc ? svc.artist : ""
  readonly property string album: svc && svc.album !== svc.title ? svc.album : ""
  readonly property real volume: svc ? svc.senderVolume : -1

  implicitHeight: visible ? artSize : 0

  // Cover tile. The rebuilt copy only (Service.coverArtUrl); a glyph while
  // there is none, so the layout does not jump.
  Rectangle {
    id: tile
    visible: root.showArtwork
    width: root.artSize
    height: root.artSize
    radius: Math.min(Style.cornerRadius, root.artSize / 6)
    color: Util.alpha(root.foreground, 0.06)
    border.width: 1
    border.color: Util.alpha(root.foreground, 0.10)
    clip: true

    Image {
      id: art
      anchors.fill: parent
      anchors.margins: 1
      source: root.svc ? root.svc.coverArtUrl : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      smooth: true
      opacity: status === Image.Ready ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutQuad } }
    }

    Text {
      anchors.centerIn: parent
      visible: art.status !== Image.Ready
      textFormat: Text.PlainText
      text: "󰝚"  // U+F075A md-music
      color: Util.alpha(root.foreground, 0.35)
      font.family: root.fontFamily
      font.pixelSize: Math.round(root.artSize * 0.42)
    }
  }

  Item {
    id: side
    x: tile.visible ? root.artSize + root.gap : 0
    width: root.width - x
    height: root.artSize

    Column {
      id: lines
      width: parent.width
      spacing: Style.space(2)
      // Centred when the meter is hidden, rather than leaving a gap below.
      y: meter.visible ? 0 : Math.round((parent.height - height) / 2)

      // Track text is the sender's: PlainText, so markup is never parsed.
      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: root.title
        elide: Text.ElideRight
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      Item {
        width: parent.width
        height: artistText.implicitHeight
        visible: root.artist !== "" || root.album !== "" || volumeRow.visible

        Row {
          spacing: Style.space(6)
          readonly property real room: parent.width - (volumeRow.visible ? volumeRow.width + Style.space(8) : 0)

          Text {
            id: artistText
            textFormat: Text.PlainText
            text: root.artist
            visible: text !== ""
            width: Math.min(implicitWidth, parent.room)
            elide: Text.ElideRight
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            id: pipe
            textFormat: Text.PlainText
            text: "|"
            visible: root.artist !== "" && root.album !== ""
            color: Util.alpha(root.foreground, 0.25)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            text: root.album
            visible: text !== ""
            width: Math.max(0, Math.min(implicitWidth, parent.room
                   - (artistText.visible ? artistText.width + parent.spacing : 0)
                   - (pipe.visible ? pipe.width + parent.spacing : 0)))
            elide: Text.ElideRight
            color: root.dimmer
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // The phone's volume: readable, not settable from here.
        Row {
          id: volumeRow
          anchors.right: parent.right
          spacing: Style.space(3)
          visible: root.volume >= 0

          Text {
            textFormat: Text.PlainText
            text: root.volume <= 0 ? "󰖁"     // U+F0581 md-volume-off
                : root.volume < 0.34 ? "󰕿"   // U+F057F md-volume-low
                : root.volume < 0.67 ? "󰖀"   // U+F0580 md-volume-medium
                : "󰕾"                        // U+F057E md-volume-high
            color: root.dimmer
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            text: Math.round(root.volume * 100)
            color: root.dimmer
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }

    LevelMeter {
      id: meter
      anchors.bottom: parent.bottom
      width: parent.width
      height: parent.height - lines.implicitHeight - lines.spacing
      active: root.meterActive
      streamNode: root.svc ? root.svc.streamNode : null
      foreground: root.foreground
      accent: root.accent
    }
  }
}
