import QtQuick
import Quickshell
import Quickshell.Wayland

PanelWindow {
  id: root
  property var service: null
  property var noticeScreen: null
  property bool eligible: true
  property bool showing: false
  screen: noticeScreen
  visible: showing && eligible
  anchors { top: true; right: true }
  margins { top: 48; right: 16 }
  implicitWidth: 360
  implicitHeight: message.implicitHeight + 24
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "paperland-activation-notice"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  // Failed activation must not take input away from the surviving client.
  mask: Region {}
  function updateNotice(): void {
    showing = !!service && (!!service.groupNotice || !!service.activationError);
    if (showing) dismiss.restart();
  }
  Connections {
    target: root.service
    function onActivationErrorChanged() { root.updateNotice(); }
    function onGroupNoticeChanged() { root.updateNotice(); }
  }
  Timer { id: dismiss; interval: 5000; onTriggered: root.showing = false }
  Rectangle {
    anchors.fill: parent
    color: "#272727"
    radius: 8
    border.color: root.service && root.service.groupNotice ? "#e6aa4b" : "#a55eab"
    Text {
      id: message
      anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
      text: root.service ? root.service.groupNotice || root.service.activationError : ""
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      font.pixelSize: 13
      color: "#eeeeee"
      Accessible.role: Accessible.AlertMessage
      Accessible.name: text
    }
  }
}
