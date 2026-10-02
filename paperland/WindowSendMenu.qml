pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQml.Models
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Wayland
import "shared/WindowDestinations.js" as Destinations
import "shared/WindowActions.js" as Actions

Item {
  id: root
  required property var service
  property bool opened: false
  property var target: null
  property var destination: null
  property var menuScreen: null
  property string openingMonitor: ""
  property bool submitting: false
  // The minimap that opened the menu; it alone offers selection actions.
  property var selectionHost: null
  readonly property bool hasSelection: !!selectionHost && selectionHost.selectedInOrder().length > 0
  signal starting()
  readonly property var contentItem: popupWindow.contentItem.QQC.Overlay.overlay
  property point anchorPoint: Qt.point(8, 8)
  property var destinationsSnapshot: []
  readonly property var monitors: destinationsSnapshot.reduce(function(names, d) { if (names.indexOf(d.monitor) < 0) names.push(d.monitor); return names; }, [])

  function openFor(address: string, screen: var, position: point): void {
    if (service.moveBusy || service.groupActive || !service.allWindows[address]) return;
    service.cancelActivationCheck();
    target = service.allWindows[address];
    destination = null; selectionHost = null; openingMonitor = service.focusedMonitor;
    menuScreen = screen || Quickshell.screens.find(function(s) { return s.name === root.openingMonitor; }) || Quickshell.screens[0];
    anchorPoint = position;
    destinationsSnapshot = service.destinations.map(function(d) { return Object.assign({}, d); });
    service.moveMessage = ""; numberInput.text = "";
    starting(); opened = true;
    Qt.callLater(function() { if (root.opened) menu.popup(root.anchorPoint.x, root.anchorPoint.y); });
  }
  function openForSelection(address: string, screen: var, position: point, host: var): void {
    openFor(address, screen, position);
    if (opened) selectionHost = host;
  }
  function act(command: string): void {
    if (submitting || !target) return;
    close();
    service.dispatchWindowAction(command);
  }
  function close(): void {
    if (submitting) return;
    opened = false; menu.dismiss(); form.close();
  }
  function showForm(): void {
    form.open(); menu.dismiss();
    Qt.callLater(function() { if (root.destination) form.forceActiveFocus(); else numberInput.forceActiveFocus(); });
  }
  function submit(follow: bool): void {
    if (submitting) return;
    var chosen = destination;
    if (numberInput.text) {
      var id = Destinations.number(numberInput.text);
      if (!id) { service.moveMessage = "Enter a workspace number from 1 to 2147483647."; showForm(); return; }
      chosen = {kind: "number", id: id};
    }
    if (!chosen) { service.moveMessage = "Choose a destination."; showForm(); return; }
    send.destination = chosen; send.follow = follow;
    submitting = true; menu.dismiss(); form.close();
    // Release the exclusive layer before native follow can focus the client.
    send.restart();
  }
  Timer {
    id: send
    interval: 40
    property var destination: null
    property bool follow: false
    onTriggered: {
      if (!root.service.moveWindow(root.target, destination, follow)) { root.submitting = false; root.showForm(); }
    }
  }
  Connections {
    target: root.service
    function onMoveFinished(success) {
      root.submitting = false;
      if (success) root.close();
      else root.showForm();
    }
  }
  component Menu: QQC.Menu {
    popupType: QQC.Popup.Item
    width: Math.min(280, window.width - 16)
    height: Math.min(implicitHeight, window.height - 16)
    margins: 8
    padding: 5
    delegate: QQC.MenuItem { objectName: subMenu ? subMenu.objectName : "" }
    palette.window: "#272727"; palette.windowText: "#eeeeee"
    palette.text: "#eeeeee"; palette.buttonText: "#eeeeee"
    palette.highlight: "#513651"; palette.highlightedText: "white"
    background: Rectangle { color: "#272727"; radius: 8; border.color: "#707070" }
  }
  PanelWindow {
    id: window
    screen: root.menuScreen
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "paperland-window-send"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened && !root.submitting ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    PopupWindow {
      id: popupWindow
      visible: root.opened && !root.submitting
      color: "transparent"
      implicitWidth: root.menuScreen ? root.menuScreen.width : 1
      implicitHeight: root.menuScreen ? root.menuScreen.height : 1
      anchor.window: window
      anchor.rect: Qt.rect(0, 0, 1, 1)
      anchor.edges: Edges.Top | Edges.Left
      anchor.gravity: Edges.Bottom | Edges.Right
      MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onClicked: root.close() }
      Menu {
        id: menu
        objectName: "send-menu"
        onClosed: if (!root.submitting && !form.visible) root.close()
        QQC.MenuItem {
          text: root.target ? root.target.title : "Send window to…"
          enabled: false
        }
        QQC.MenuSeparator {}
        QQC.MenuItem {
          objectName: "send-toggle-float"
          // Live state: a float toggle made just before opening may land after the snapshot.
          readonly property var live: root.target ? root.service.allWindows[root.target.address] : null
          text: (live && live.stableId === root.target.stableId ? live.floating : root.target && root.target.floating) ? "Tile Window" : "Float Window"
          onTriggered: root.act(Actions.toggleFloat(root.target.stableId))
        }
        QQC.MenuSeparator {}
        Instantiator {
          model: root.monitors
          delegate: Menu {
            id: monitorMenu
            required property string modelData
            title: modelData
            objectName: "send-monitor-" + modelData
            Instantiator {
              model: root.destinationsSnapshot.filter(function(d) { return d.monitor === monitorMenu.modelData; })
              delegate: Menu {
                id: workspaceMenu
                required property var modelData
                property var captured: null
                title: modelData.label
                objectName: "send-existing-" + modelData.id
                onAboutToShow: { captured = Object.assign({}, modelData); root.destination = captured; numberInput.text = ""; }
                QQC.MenuItem {
                  objectName: "send-confirm-" + workspaceMenu.modelData.id
                  text: "Send"
                  onTriggered: { root.destination = workspaceMenu.captured; root.submit(false); }
                }
                QQC.MenuItem {
                  objectName: "send-follow-" + workspaceMenu.modelData.id
                  text: "Send and follow"
                  onTriggered: { root.destination = workspaceMenu.captured; root.submit(true); }
                }
              }
              onObjectAdded: (index, object) => monitorMenu.insertMenu(index, object)
              onObjectRemoved: (index, object) => monitorMenu.removeMenu(object)
            }
          }
          onObjectAdded: (index, object) => menu.insertMenu(index + 4, object)
          onObjectRemoved: (index, object) => menu.removeMenu(object)
        }
        QQC.MenuSeparator {}
        QQC.MenuItem {
          objectName: "send-number-menu"
          text: "Workspace number…"
          onTriggered: { root.destination = null; root.showForm(); }
        }
        // Hidden rows keep zero height and stay disabled so keyboard navigation skips them.
        QQC.MenuSeparator { visible: !!root.selectionHost; height: visible ? implicitHeight : 0 }
        QQC.MenuItem {
          objectName: "send-select-all"
          text: "Select All on this Workspace"
          visible: !!root.selectionHost; enabled: visible; height: visible ? implicitHeight : 0
          onTriggered: { var host = root.selectionHost; root.close(); if (host) host.selectAllWindows(); }
        }
        QQC.MenuItem {
          objectName: "send-clear-selection"
          text: "Clear Selection"
          visible: root.hasSelection; enabled: visible; height: visible ? implicitHeight : 0
          onTriggered: { var host = root.selectionHost; root.close(); if (host) host.clearSelection(); }
        }
        QQC.MenuSeparator {}
        QQC.MenuItem {
          objectName: "send-display-left"
          text: "Move to Left Display"
          onTriggered: root.act(Actions.moveToDisplay(root.target.stableId, -1))
        }
        QQC.MenuItem {
          objectName: "send-display-right"
          text: "Move to Right Display"
          onTriggered: root.act(Actions.moveToDisplay(root.target.stableId, 1))
        }
        QQC.MenuSeparator {}
        QQC.MenuItem {
          objectName: "send-close-window"
          text: "Close Window"
          onTriggered: root.act(Actions.close(root.target.stableId))
        }
        QQC.MenuItem {
          objectName: "send-quit-app"
          text: "Quit App"
          onTriggered: root.act(Actions.quitApp(root.target.stableId))
        }
      }
      QQC.Popup {
        id: form
        objectName: "send-form"
        popupType: QQC.Popup.Item
        x: Math.max(8, Math.min(root.anchorPoint.x, window.width - width - 8))
        y: Math.max(8, Math.min(root.anchorPoint.y, window.height - height - 8))
        width: Math.min(360, window.width - 16)
        height: Math.min(implicitHeight, window.height - 16)
        padding: 12; focus: true
        closePolicy: root.submitting ? QQC.Popup.NoAutoClose : QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutside
        onClosed: if (!root.submitting && !menu.visible) root.close()
        palette.button: "#393339"; palette.buttonText: "#eeeeee"
        palette.placeholderText: "#b7abb7"; palette.base: "#202020"; palette.text: "#eeeeee"
        background: Rectangle { radius: 8; color: "#272727"; border.color: "#707070" }
        contentItem: ColumnLayout {
          spacing: 8
          QQC.Button {
            objectName: "send-back"
            text: "‹ Destinations"
            enabled: !root.submitting
            onClicked: {
              root.destination = null; numberInput.text = ""; root.service.moveMessage = "";
              root.destinationsSnapshot = root.service.destinations.map(function(d) { return Object.assign({}, d); });
              menu.popup(root.anchorPoint.x, root.anchorPoint.y); form.close();
            }
          }
          Text {
            Layout.fillWidth: true
            text: root.target ? root.target.title : "Send window to…"
            color: "#eeeeee"; textFormat: Text.PlainText; elide: Text.ElideRight
          }
          QQC.TextField {
            id: numberInput
            objectName: "send-workspace-number"
            Layout.fillWidth: true
            visible: !root.destination
            placeholderText: "Workspace number…"
            Accessible.name: "Destination workspace number"
            enabled: !root.submitting
            onTextEdited: root.service.moveMessage = ""
            onAccepted: root.submit(false)
          }
          Text {
            Layout.fillWidth: true
            text: root.service.moveMessage || (root.destination ? root.destination.label : "Send stays here. Send and follow switches to the window.")
            textFormat: Text.PlainText; color: "#dddddd"; wrapMode: Text.Wrap; font.pixelSize: 12
          }
          RowLayout {
            Layout.fillWidth: true
            QQC.Button { objectName: "send-cancel"; text: "Cancel"; enabled: !root.submitting; onClicked: root.close() }
            Item { Layout.fillWidth: true }
            QQC.Button { objectName: "send-confirm"; text: "Send"; enabled: !root.submitting; onClicked: root.submit(false) }
            QQC.Button { objectName: "send-follow"; text: "Send and follow"; enabled: !root.submitting; onClicked: root.submit(true) }
          }
        }
      }
    }
  }
}
