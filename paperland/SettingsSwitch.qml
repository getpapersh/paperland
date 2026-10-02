import QtQuick
import QtQuick.Controls as QQC

QQC.Switch {
  id: control
  implicitWidth: 76
  implicitHeight: 32
  indicator: Rectangle {
    x: 0
    y: (control.height - height) / 2
    width: 47
    height: 27
    radius: 14
    color: !control.enabled ? Theme.settingsColor("#30384d") : control.checked ? Theme.settingsColor("#5b82f6") : Theme.settingsColor("#2c344b")
    border.color: control.visualFocus || control.checked ? Theme.settingsColor("#7fa0ff") : Theme.settingsColor("#414b65")
    Rectangle {
      x: control.checked ? 23 : 3
      y: 3
      width: 20
      height: 20
      radius: 10
      color: control.enabled ? Theme.settingsColor("#f2f4ff") : Theme.settingsColor("#929bb4")
      Behavior on x { NumberAnimation { duration: 120 } }
    }
  }
  contentItem: Text {
    leftPadding: 54
    text: control.checked ? "On" : "Off"
    color: control.enabled ? Theme.settingsColor("#c4cbe7") : Theme.settingsColor("#78839f")
    verticalAlignment: Text.AlignVCenter
    font.pixelSize: 12
  }
}
