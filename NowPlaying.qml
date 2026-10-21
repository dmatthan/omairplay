import QtQuick
import qs.Commons
import qs.Commons as Commons

// What the phone is playing: cover, title, artist | album and the sender's
// volume, with the level meter filling the space beside the cover so the
// block ends level with it.
Item {
  id: root

  property var svc: null
  property bool showArtwork: true
  property bool meterActive: false
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
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

  readonly property string coverUrl: svc ? svc.coverArtUrl : ""
  onCoverUrlChanged: if (coverUrl === "") { fadeIn.stop(); over.opacity = 0; under.source = "" }

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

    // The shown cover sits underneath; a new one loads on top and fades in
    // once ready, so a change never passes through an empty tile.
    Image {
      id: under
      anchors.fill: parent
      anchors.margins: 1
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      smooth: true
    }

    Image {
      id: over
      anchors.fill: parent
      anchors.margins: 1
      source: root.coverUrl
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      smooth: true
      opacity: 0
      onStatusChanged: if (status === Image.Ready) { opacity = 0; fadeIn.restart() }
    }

    NumberAnimation {
      id: fadeIn
      target: over
      property: "opacity"
      to: 1
      duration: 220
      easing.type: Easing.OutQuad
      onFinished: under.source = over.source
    }

    Text {
      anchors.centerIn: parent
      visible: over.status !== Image.Ready && under.status !== Image.Ready
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
      // Long lines scroll rather than cut off.
      Marquee {
        width: parent.width
        running: root.meterActive

        Text {
          textFormat: Text.PlainText
          text: root.title
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }
      }

      Item {
        width: parent.width
        height: volumeRow.implicitHeight
        visible: root.artist !== "" || root.album !== "" || volumeRow.visible

        // Artist and album, scrolling like the title.
        Marquee {
          width: parent.width - (volumeRow.visible ? volumeRow.width + Style.space(8) : 0)
          running: root.meterActive

          Text {
            textFormat: Text.PlainText
            text: root.artist
            visible: text !== ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            text: " | "
            visible: root.artist !== "" && root.album !== ""
            color: Util.alpha(root.foreground, 0.25)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            text: root.album
            visible: text !== ""
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
