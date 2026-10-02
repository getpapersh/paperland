import QtQuick
import QtQuick.Controls as QQC

FocusScope {
  id: root
  property var client: null
  property int workspace: 0
  property string observedName: ""
  property bool clearRequested: false
  property string draft: ""
  property bool submitted: false
  property var draftCapture: null
  property int captureToken: 0
  property string captureMessage: ""
  readonly property bool canSubmit: !!client && !client.busy && !!draftCapture && draftCapture === client.capture && draftCapture.id === workspace
  property bool hadFocus: false
  onVisibleChanged: if (!visible) hadFocus = false
  onActiveFocusChanged: {
    if (activeFocus) hadFocus = true;
    else if (hadFocus && visible && !submitted) cancelled();
  }
  property color foreground: "#eeeeee"
  property color accent: "#a55eab"
  signal cancelled()
  implicitWidth: 420
  implicitHeight: 240
  function begin(id, name, clearing) {
    workspace = id; observedName = name; clearRequested = clearing;
    draft = clearing ? "" : name; submitted = false;
    draftCapture = null; captureMessage = "";
    captureToken = client ? client.begin(id) : 0;
    if (!captureToken) captureMessage = "Another name operation is running. Reload this workspace when it finishes.";
    Qt.callLater(function() { input.forceActiveFocus(); input.selectAll(); });
  }
  function receipt(key) { return client && client.outcome && client.outcome[key] === true ? "Yes" : client && client.outcomeUnresolved ? "Unknown" : "No"; }
  function submit() {
    if (!canSubmit) return;
    submitted = client.submit(draft, draftCapture);
  }
  Connections {
    target: root.client
    function onCaptured(value, token) {
      if (!root.visible || token !== root.captureToken || value.id !== root.workspace) return;
      root.draftCapture = value; root.captureMessage = "";
      root.observedName = value.observedName;
      root.draft = root.clearRequested ? "" : value.observedName;
      Qt.callLater(function() { input.forceActiveFocus(); input.selectAll(); });
    }
  }
  Keys.onEscapePressed: cancelled()
  Column {
    anchors.fill: parent
    spacing: 12
    Text { text: "Rename workspace " + root.workspace; color: root.foreground; font.pixelSize: 17; font.bold: true }
    QQC.TextField {
      id: input
      objectName: "workspace-name-input"
      width: parent.width
      text: root.draft
      onTextEdited: root.draft = text
      readOnly: !!root.client && root.client.busy
      font.pixelSize: 14
      padding: 9
      color: root.foreground
      selectionColor: root.accent
      Accessible.name: "Custom name for workspace " + root.workspace
      onAccepted: root.submit()
      background: Rectangle { color: "#383838"; radius: 5; border.color: input.activeFocus ? root.accent : "#666666" }
    }
    Text {
      width: parent.width
      wrapMode: Text.Wrap
      text: "The workspace number stays the same. Saved names become native creation defaults. Leave blank to clear Paperland’s default; the replacement is resolved after reload."
      color: root.foreground
      opacity: 0.7
      font.pixelSize: 12
    }
    Text {
      objectName: "workspace-name-status"
      width: parent.width
      wrapMode: Text.Wrap
      textFormat: Text.PlainText
      text: root.captureMessage || (root.client ? root.client.message : "")
      color: root.foreground
      font.pixelSize: 12
    }
    Text {
      objectName: "workspace-name-receipts"
      width: parent.width
      visible: !!root.client && (!!root.client.outcome || root.client.outcomeUnresolved)
      text: "Saved: " + root.receipt("saved") + " · Loaded: " + root.receipt("loaded") + " · Applied to live workspace: " + root.receipt("applied")
      wrapMode: Text.Wrap
      color: root.foreground
      font.pixelSize: 12
    }
    Row {
      spacing: 10
      QQC.Button { palette.button: "#3c3c3c"; palette.buttonText: root.foreground; palette.highlight: root.accent; objectName: "workspace-name-submit"; text: "Rename"; enabled: root.canSubmit; onClicked: root.submit() }
      QQC.Button { palette.button: "#3c3c3c"; palette.buttonText: root.foreground; palette.highlight: root.accent; text: "Reload"; visible: !root.canSubmit && !!root.client && !root.client.busy; onClicked: root.begin(root.workspace, root.observedName, root.clearRequested) }
      QQC.Button { palette.button: "#3c3c3c"; palette.buttonText: root.foreground; palette.highlight: root.accent; objectName: "workspace-name-cancel"; text: root.submitted ? "Close" : "Cancel"; onClicked: root.cancelled() }
    }
  }
}
