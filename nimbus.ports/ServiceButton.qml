import QtQuick
import qs.Commons

Rectangle {
  id: btn
  property string label: ""
  property bool active: true
  property color color1: "#1e8449"
  property color color2: "#27ae60"
  property string fontFamily: Style.font.menuFamily
  signal clicked()

  width: label.length > 4 ? Style.space(56) : Style.space(46)
  height: Style.space(24)
  radius: Style.cornerRadius
  color: !active ? "#2c2c2c" : (area.containsMouse ? color2 : color1)
  opacity: active ? 1.0 : 0.4

  Text {
    anchors.centerIn: parent
    text: btn.label
    color: "white"
    font.family: btn.fontFamily
    font.pixelSize: Style.font.caption
  }

  MouseArea {
    id: area
    anchors.fill: parent
    hoverEnabled: true
    enabled: btn.active
    cursorShape: btn.active ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: btn.clicked()
  }
}
