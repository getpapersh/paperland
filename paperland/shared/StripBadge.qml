import QtQuick

Rectangle {
  id: root
  required property int number
  width: 13
  height: 13
  radius: 7
  color: "#e0c4e5"
  border.color: "#a55eab"
  border.width: 0.7
  Accessible.ignored: true

  Text {
    anchors.centerIn: parent
    text: root.number
    color: "#272727"
    font.pixelSize: 8
    font.bold: true
  }
}
