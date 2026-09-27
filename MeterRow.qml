import QtQuick
import qs.Commons

// One resource: label, a bar that warms from foreground through accent to
// urgent as it fills, the figure, and an optional note underneath.
// Layout idea adapted from jonspinks/omarchy-winvm (MIT), see NOTICE.
Item {
  id: root

  property string label: ""
  property real value: 0            // 0..1, drives the bar
  property string valueText: ""
  property string note: ""
  property color foreground: Color.foreground
  property color midColor: Color.accent
  property color hotColor: Color.urgent
  property string fontFamily: Style.font.family

  implicitHeight: labelText.implicitHeight + (note !== "" ? noteText.implicitHeight + Style.space(2) : 0)

  function mix(a, b, t) {
    t = Math.max(0, Math.min(1, t))
    return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t,
                   a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t)
  }

  readonly property real clamped: Math.max(0, Math.min(1, isFinite(value) ? value : 0))
  readonly property color barColor: clamped < 0.5
    ? mix(foreground, midColor, clamped / 0.5)
    : mix(midColor, hotColor, (clamped - 0.5) / 0.5)

  Text {
    id: labelText
    anchors.left: parent.left
    anchors.top: parent.top
    width: Style.space(58)
    text: root.label
    textFormat: Text.PlainText
    elide: Text.ElideRight
    color: root.foreground
    opacity: 0.7
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  Rectangle {
    id: track
    anchors.left: labelText.right
    anchors.leftMargin: Style.space(8)
    anchors.right: valueLabel.left
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: labelText.verticalCenter
    height: Math.max(3, Style.space(4))
    radius: height / 2
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)

    Rectangle {
      width: Math.max(parent.height, parent.width * root.clamped)
      height: parent.height
      radius: parent.radius
      color: root.barColor
      Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
    }
  }

  Text {
    id: valueLabel
    anchors.right: parent.right
    anchors.verticalCenter: labelText.verticalCenter
    width: Math.max(Style.space(62), Math.min(implicitWidth, root.width * 0.45))
    horizontalAlignment: Text.AlignRight
    text: root.valueText
    textFormat: Text.PlainText
    elide: Text.ElideRight
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  Text {
    id: noteText
    visible: root.note !== ""
    anchors.left: labelText.left
    anchors.right: parent.right
    anchors.top: labelText.bottom
    anchors.topMargin: Style.space(2)
    text: root.note
    textFormat: Text.PlainText
    elide: Text.ElideRight
    color: root.foreground
    opacity: 0.5
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
