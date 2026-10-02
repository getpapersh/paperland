import QtQuick
import QtQuick.Controls as QQC

QQC.TextField {
  id: control
  font.family: Theme.fontFamily
  font.pixelSize: 14
  color: Theme.foreground
  selectionColor: Theme.alpha(Theme.accent, 0.3)
  selectedTextColor: Theme.foreground
  placeholderTextColor: Theme.alpha(Theme.foreground, 0.5)
  leftPadding: 12
  rightPadding: 12
  topPadding: 10
  bottomPadding: 10
  background: Rectangle {
    radius: 7
    color: Theme.alpha(Theme.foreground, 0.035)
    border.color: control.activeFocus ? Theme.accent : Theme.alpha(Theme.foreground, 0.18)
  }
}
