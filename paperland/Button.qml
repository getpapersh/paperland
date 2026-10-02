import QtQuick
import QtQuick.Controls as QQC

QQC.Button {
  id: control
  property bool selected: false
  property bool focusable: false
  property real fontSize: 13
  verticalPadding: 7
  property string tooltipText: ""
  hoverEnabled: true
  focusPolicy: focusable ? Qt.StrongFocus : Qt.NoFocus
  Keys.onReturnPressed: clicked()
  Keys.onEnterPressed: clicked()
  leftPadding: 10
  rightPadding: 10
  topPadding: verticalPadding
  bottomPadding: verticalPadding
  Accessible.name: tooltipText || text
  contentItem: Text {
    text: control.text
    textFormat: Text.PlainText
    color: control.enabled ? Theme.textSecondary : Theme.textDisabled
    font.family: Theme.fontFamily
    font.pixelSize: control.fontSize
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
  }
  background: Rectangle {
    implicitWidth: 30
    implicitHeight: 28
    radius: 6
    color: control.down ? Theme.surfaceSelected : control.hovered || control.selected ? Theme.surfaceHover : Theme.surfaceControl
    border.color: control.visualFocus || control.selected ? Theme.accent : "transparent"
  }
  QQC.ToolTip.visible: hovered && tooltipText !== ""
  QQC.ToolTip.text: tooltipText
  QQC.ToolTip.delay: 450
}
