import QtQuick
import qs.Commons
import qs.Ui

// Single-line speaker-name field that never reads the clipboard.
//
// Not a TextField: an editable TextInput reads every foreign clipboard offer in
// full on the GUI thread as it changes (Qt 6.11 q_canPasteChanged). TextEdit's
// paste check looks at the offered formats only. Its two paste paths, the
// Paste shortcut and middle click, are closed below.
FocusScope {
  id: root

  property alias text: edit.text
  property string placeholderText: ""
  // Counted in UTF-16 units, as TextInput's maximumLength was.
  property int maximumLength: 50
  property string fontFamily: Style.font.family
  property color foreground: Color.foreground
  property color accent: Color.accent
  property bool hasCursor: false

  // Keys the panel acts on, accepted here so none reaches the editor.
  signal submitted()
  signal cancelled()
  signal navigated(int delta)

  function selectAll() { edit.selectAll() }

  readonly property bool _focused: activeFocus
  readonly property bool _hot: hover.hovered || hasCursor
  readonly property var _borderSpec: Border.controlSpec(_focused ? "focus" : (_hot ? "hover-cursor" : "normal"), root.foreground, root.accent)
  readonly property real _padX: Style.spacing.controlPaddingX
  readonly property real _padY: Style.spacing.inputPaddingY

  implicitHeight: Math.max(edit.implicitHeight, placeholder.implicitHeight)
    + _padY * 2 + Border.top(_borderSpec) + Border.bottom(_borderSpec)

  BorderSurface {
    anchors.fill: parent
    color: Style.controlFill(root._focused, root._hot, root.foreground, root.accent)
    borderSpec: root._borderSpec
    radius: Style.cornerRadius
  }

  HoverHandler {
    id: hover
    cursorShape: Qt.IBeamCursor
  }

  // Presses in the padding still focus the field and place the cursor.
  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.IBeamCursor
    onPressed: function(mouse) {
      root.forceActiveFocus()
      var p = mapToItem(edit, mouse.x, mouse.y)
      edit.cursorPosition = edit.positionAt(p.x, edit.height / 2)
    }
  }

  Item {
    id: viewport
    anchors.fill: parent
    anchors.leftMargin: root._padX + Border.left(root._borderSpec)
    anchors.rightMargin: root._padX + Border.right(root._borderSpec)
    anchors.topMargin: root._padY + Border.top(root._borderSpec)
    anchors.bottomMargin: root._padY + Border.bottom(root._borderSpec)
    clip: true

    Text {
      id: placeholder
      y: Math.round((viewport.height - height) / 2)
      width: viewport.width
      text: root.placeholderText
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: Qt.darker(root.foreground, 1.6)
      font: edit.font
      visible: edit.length === 0 && edit.preeditText === ""
    }

    TextEdit {
      id: edit
      focus: true
      // TextEdit does not scroll to the cursor itself; see ensureCursorVisible.
      x: -scroll
      y: Math.round((viewport.height - height) / 2)
      textFormat: TextEdit.PlainText
      wrapMode: TextEdit.NoWrap
      selectByMouse: true
      persistentSelection: false
      color: root.foreground
      selectionColor: Style.selectionFillFor(root.foreground, root.accent)
      selectedTextColor: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body

      property real scroll: 0
      property bool fixing: false

      function ensureCursorVisible() {
        var r = cursorRectangle
        var w = viewport.width
        var s = scroll
        if (r.x < s) s = r.x
        else if (r.x + r.width > s + w) s = r.x + r.width - w
        scroll = Math.max(0, Math.min(s, Math.max(contentWidth, r.x + r.width) - w))
      }

      onCursorRectangleChanged: ensureCursorVisible()
      onContentWidthChanged: ensureCursorVisible()
      Connections {
        target: viewport
        function onWidthChanged() { edit.ensureCursorVisible() }
      }

      // One line, no control characters (an input method can commit Tab or a
      // newline), at most maximumLength; excess is trimmed from what was typed.
      onTextChanged: {
        if (fixing) return
        fixing = true
        var t = text
        for (var i = t.length - 1; i >= 0; i--) {
          var c = t.charCodeAt(i)
          if (c < 0x20 || c === 0x7f || c === 0x2028 || c === 0x2029)
            remove(i, i + 1)
        }
        var excess = length - root.maximumLength
        if (root.maximumLength >= 0 && excess > 0) {
          var end = cursorPosition
          var start = end - excess
          if (start < 0) { start = root.maximumLength; end = length }
          // Never leave half of a surrogate pair behind.
          var lo = text.charCodeAt(start)
          if (start > 0 && lo >= 0xdc00 && lo <= 0xdfff) start--
          remove(start, end)
        }
        fixing = false
      }

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          event.accepted = true; root.submitted()
        } else if (event.key === Qt.Key_Escape) {
          event.accepted = true; root.cancelled()
        } else if (event.key === Qt.Key_Up) {
          event.accepted = true; root.navigated(-1)
        } else if (event.key === Qt.Key_Down) {
          event.accepted = true; root.navigated(1)
        } else if (event.matches(StandardKey.Paste) || event.key === Qt.Key_Paste) {
          // Paste would be a synchronous, unbounded clipboard read: swallowed.
          event.accepted = true
        } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
          // TextEdit would insert a tab character.
          event.accepted = true
        }
      }
    }

    // Middle click would paste the primary selection (an unbounded read): dropped.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.MiddleButton
      onPressed: function(mouse) { mouse.accepted = true }
    }
  }
}
