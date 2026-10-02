import QtQuick
import QtQuick.Controls as QQC
import "WorkspaceCatalog.js" as Catalog

// PaperMac's close-all alert: the counted windows are fixed when it opens.
FocusScope {
  id: root
  property int workspace: 0
  property var targets: []
  readonly property var wording: Catalog.closeConfirmation(targets.length)
  property color foreground: "#eeeeee"
  property color accent: "#a55eab"
  signal confirmed(int workspace, var targets)
  signal cancelled()
  implicitWidth: 420
  implicitHeight: content.implicitHeight
  function begin(id: int, list: var): void {
    workspace = id; targets = list.slice();
    Qt.callLater(function() { confirmButton.forceActiveFocus(); });
  }
  function confirm(): void { if (targets.length) confirmed(workspace, targets); }
  // Enter is the alert's default button, but never while Cancel holds focus.
  function accept(): void { if (cancelButton.activeFocus) cancelled(); else confirm(); }
  Keys.onEscapePressed: cancelled()
  Keys.onReturnPressed: accept()
  Keys.onEnterPressed: accept()
  Column {
    id: content
    anchors.left: parent.left; anchors.right: parent.right
    spacing: 12
    Text { objectName: "workspace-close-title"; text: root.wording.title; color: root.foreground; font.pixelSize: 17; font.bold: true }
    Text {
      objectName: "workspace-close-detail"
      width: parent.width
      wrapMode: Text.Wrap
      text: root.wording.detail
      color: root.foreground
      opacity: 0.7
      font.pixelSize: 12
    }
    Row {
      spacing: 10
      QQC.Button { id: confirmButton; objectName: "workspace-close-confirm"; palette.button: "#3c3c3c"; palette.buttonText: root.foreground; palette.highlight: root.accent; text: root.wording.confirm; onClicked: root.confirm() }
      QQC.Button { id: cancelButton; objectName: "workspace-close-cancel"; palette.button: "#3c3c3c"; palette.buttonText: root.foreground; palette.highlight: root.accent; text: "Cancel"; onClicked: root.cancelled() }
    }
  }
}
