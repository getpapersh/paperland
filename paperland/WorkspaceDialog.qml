import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import "shared" as Shared
import "native" as Native

Item {
  id: root
  property var service: null
  property var dialogScreen: null
  property var workspace: 0
  property string mode: ""
  // Peek duration editing lives here since PAPLA-30 moved it off the overview
  // surface; the popover is reachable from the minimap and the overview strips.
  property int peekSeconds: 3
  signal peekSecondsRequested(int seconds)
  signal welcomeRequested()
  readonly property var entry: !service ? null : workspace === "special:scratchpad"
    ? service.scratchpadForMonitor(dialogScreen ? dialogScreen.name : "") : service.catalog.entries[workspace] || null
  readonly property bool opened: mode !== ""
  // Screen-logical invocation point; the layer covers the whole screen.
  property point anchorPoint: Qt.point(0, 0)
  // Where the popover's bottom sits when it opens upward: the top of the
  // invoking control, so a flip never covers it.
  property real aboveY: 0
  signal activating()
  function openFor(id: int, screen: var, position: point, above: real): void {
    if (!service || !service.catalog.entries[id]) return;
    workspace = id; dialogScreen = screen; anchorPoint = position; aboveY = above;
    menu.selectedIndex = 0; mode = "menu";
    Qt.callLater(function() { menu.forceActiveFocus(); });
  }
  function openScratchpadFor(screen: var, position: point, above: real): void {
    if (!service) return;
    workspace = "special:scratchpad"; dialogScreen = screen; anchorPoint = position; aboveY = above;
    menu.selectedIndex = 0; mode = "menu";
    Qt.callLater(function() { menu.forceActiveFocus(); });
  }
  function pauseActivation(): void { activation.stop(); }
  function close(): void { activation.stop(); mode = ""; }
  function activate(address) { activation.address = address; activating(); close(); activation.restart(); }
  onEntryChanged: if (opened && !entry) close()
  onModeChanged: if (mode === "windows") Qt.callLater(function() { preview.forceActiveFocus(); })
  Timer { id: activation; interval: 40; property string address: ""; onTriggered: if (root.service) root.service.activate(address) }
  PanelWindow {
    id: window
    screen: root.dialogScreen
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "paperland-workspace-editor"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened && !Native.Runtime.sendMenu.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    mask: Region { width: Native.Runtime.sendMenu.opened ? 0 : window.width; height: Native.Runtime.sendMenu.opened ? 0 : window.height }
    MouseArea { anchors.fill: parent; onClicked: root.close() }
    // This layer only covers its own display; leaving that display would
    // otherwise strand an open menu holding exclusive keyboard focus.
    Connections {
      target: Hyprland
      function onFocusedMonitorChanged() {
        if (root.opened && root.dialogScreen && Hyprland.focusedMonitor
            && Hyprland.focusedMonitor.name !== root.dialogScreen.name) root.close();
      }
    }
    Rectangle {
      id: card
      objectName: "workspace-actions-card"
      readonly property bool popover: root.mode === "menu"
      readonly property real room: 8
      width: popover ? Math.min(280, parent.width - 2 * room) : Math.min(500, parent.width - 32)
      height: popover ? Math.min(menu.implicitHeight + 12 + (peekRow.visible ? peekRow.implicitHeight + 6 : 0), parent.height - 2 * room)
        : Math.min(root.mode === "windows" ? 420 : root.mode === "close" ? closeConfirm.implicitHeight + 32 : 310, parent.height - 32)
      // Open toward the side with room, like a native context menu.
      x: !popover ? (parent.width - width) / 2
        : Math.max(room, root.anchorPoint.x + width + room <= parent.width ? root.anchorPoint.x : root.anchorPoint.x - width)
      y: !popover ? (parent.height - height) / 2
        : Math.max(room, root.anchorPoint.y + height + room <= parent.height ? root.anchorPoint.y : root.aboveY - height)
      radius: popover ? 8 : 12
      color: "#272727"
      border.color: "#707070"
      MouseArea { anchors.fill: parent }
      Shared.WorkspaceMenu {
        id: menu
        anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
        anchors.margins: 6
        anchors.bottomMargin: 6 + (peekRow.visible ? peekRow.implicitHeight + 6 : 0)
        visible: root.mode === "menu"
        entry: root.entry
        followChecked: root.service ? root.service.scratchpadFollow : false
        welcomeAvailable: true
        onCancelled: root.close()
        onChosen: function(action) {
          if (action === "switch") { var id = root.workspace; root.close(); root.service.activateWorkspace(id); }
          else if (action === "windows") root.mode = "windows";
          else if (action === "welcome") { root.close(); root.welcomeRequested(); }
          else if (action === "follow") { root.service.setScratchpadFollow(!root.service.scratchpadFollow); root.close(); }
          else if (action === "close") { root.mode = "close"; closeConfirm.begin(root.workspace, menu.closable); }
          else { root.mode = "rename"; editor.begin(root.workspace, root.entry.name, action === "clear"); }
        }
      }
      RowLayout {
        id: peekRow
        visible: root.mode === "menu"
        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
        anchors.margins: 8
        spacing: 6
        Text { text: "Peek lasts"; color: Theme.alpha(Theme.foreground, 0.65); font.pixelSize: 11 }
        QQC.SpinBox {
          objectName: "peek-seconds"
          from: 1; to: 60
          value: root.peekSeconds
          editable: true
          implicitWidth: 96
          font.pixelSize: 11
          palette.text: Theme.foreground
          palette.buttonText: Theme.foreground
          palette.base: Theme.background
          palette.button: Theme.background
          palette.highlight: Theme.accent
          Accessible.name: "Peek duration in seconds"
          onValueModified: root.peekSecondsRequested(value)
        }
        Text { text: "seconds"; color: Theme.alpha(Theme.foreground, 0.65); font.pixelSize: 11 }
        Item { Layout.fillWidth: true }
      }
      Shared.WorkspaceEditor {
        id: editor
        anchors.fill: parent; anchors.margins: 16
        visible: root.mode === "rename"
        client: Native.Runtime.names
        onCancelled: root.close()
      }
      Shared.WorkspaceCloseConfirm {
        id: closeConfirm
        anchors.fill: parent; anchors.margins: 16
        visible: root.mode === "close"
        onCancelled: root.close()
        onConfirmed: function(id, targets) { root.close(); root.service.closeWindows(id, targets); }
      }
      Shared.WorkspacePreview {
        id: preview
        thumbnailSource: Qt.resolvedUrl("native/WindowThumbnail.qml")
        captureEnabled: window.visible && root.mode === "windows"
        iconFor: Native.Runtime.iconFor
        nameFor: Native.Runtime.nameFor
        anchors.fill: parent; anchors.margins: 16
        visible: root.mode === "windows"
        entry: root.entry
        row: root.entry && !root.entry.special && root.service ? root.service.rows[root.workspace] || null : null
        keyboardMode: true
        focusedAddress: root.service ? root.service.focusedAddress : ""
        onCancelled: root.close()
        onActivated: function(address) { root.activate(address); }
        onWindowMenuRequested: function(address, position) { Native.Runtime.sendMenu.openFor(address, root.dialogScreen, position); }
      }
    }
  }
}
