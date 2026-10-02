import QtQuick
Button {
  id: control
  selected: checked
  focusable: true
  property bool primary: false
  implicitHeight: 36
  leftPadding: 14
  rightPadding: 14
  background: Rectangle {
    radius: 7
    color: !control.enabled ? Theme.settingsColor("#242b3e") : control.down ? Theme.settingsColor("#4664ba") : (control.selected || control.primary) ? Theme.settingsColor("#5b82f6") : control.hovered ? Theme.settingsColor("#303a56") : Theme.settingsColor("#202639")
    border.color: !control.enabled ? Theme.settingsColor("#414c6b") : control.visualFocus || control.selected || control.primary ? Theme.settingsColor("#81a0ff") : Theme.settingsColor("#414c6b")
  }
  contentItem: Text {
    text: control.text
    textFormat: Text.PlainText
    color: !control.enabled ? Theme.settingsColor("#78819f") : control.selected || control.primary ? Theme.settingsColor("#10192f") : Theme.settingsColor("#d6dcf5")
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    font.pixelSize: 13
  }
}
