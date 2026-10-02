import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC
import ".." as Paperland
import "../Layout.js" as CanvasLayout
import "Density.js" as Density

Window {
  id: demo
  title: "Paperland — 3 displays / 50 windows demo"
  visible: true
  width: 1240
  height: 800
  minimumWidth: 800
  minimumHeight: 560
  color: Paperland.Theme.background
  readonly property var snapshot: Density.snapshot()
  readonly property var model: CanvasLayout.build(snapshot.monitors, snapshot.workspaces, snapshot.clients, snapshot.directions)
  property string focusedAddress: "0x15"
  property string feedback: "Simulation only. Clicks select demo windows; your desktop stays in place."

  ColumnLayout {
    anchors.fill: parent
    anchors.margins: 24
    spacing: 16
    Text { text: "Paperland"; color: Paperland.Theme.foreground; font.pixelSize: 28; font.bold: true }
    Text { text: "DEMO · 3 displays · 5 workspaces · 50 windows"; color: Paperland.Theme.accent; font.pixelSize: 13 }
    Paperland.TextField {
      id: search
      Layout.fillWidth: true
      placeholderText: "Find a window, app, or display…"
      Accessible.name: "Find a demo window, app, or display"
      Keys.onDownPressed: sidebar.selectNext(1)
      Keys.onUpPressed: sidebar.selectNext(-1)
      onAccepted: if (sidebar.selectedAddress) sidebar.activated(sidebar.selectedAddress)
      Component.onCompleted: forceActiveFocus()
    }
    RowLayout {
      Layout.fillWidth: true
      Layout.fillHeight: true
      spacing: 20
      QQC.ScrollView {
        id: canvases
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        contentWidth: availableWidth
        Column {
          width: canvases.availableWidth
          spacing: 16
          Repeater {
            model: demo.model.ids
            delegate: Rectangle {
              id: workspace
              required property int modelData
              readonly property var row: demo.model.rows[modelData]
              width: canvases.availableWidth
              height: row.vertical ? 360 : 250
              radius: 12
              color: Paperland.Theme.alpha(Paperland.Theme.foreground, 0.025)
              border.color: Paperland.Theme.alpha(Paperland.Theme.foreground, 0.12)
              ColumnLayout {
                anchors.fill: parent
                anchors.margins: 14
                spacing: 8
                Text { text: workspace.row.monitor + " / " + workspace.row.name + (workspace.row.active ? " · ON DISPLAY" : " · INACTIVE"); color: Paperland.Theme.foreground; font.pixelSize: 12 }
                Paperland.CanvasMap {
                  id: map
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  row: workspace.row
                  query: search.text
                  selectedAddress: sidebar.selectedAddress
                  focusedAddress: demo.focusedAddress
                  foreground: Paperland.Theme.foreground
                  background: Paperland.Theme.background
                  accent: Paperland.Theme.accent
                  panEnabled: false
                  onActivated: function(address) { sidebar.selectedAddress = address; sidebar.activated(address); }
                }
                RowLayout {
                  Paperland.Button { text: "Fit all"; fontSize: 11; onClicked: map.fit(); }
                  Paperland.Button { text: "Current view"; fontSize: 11; enabled: workspace.row.active; onClicked: map.currentView(); }
                  Text { text: "Ctrl + scroll to zoom"; color: Paperland.Theme.alpha(Paperland.Theme.foreground, 0.5); font.pixelSize: 11 }
                }
              }
            }
          }
        }
      }
      Paperland.WindowSidebar {
        id: sidebar
        Layout.preferredWidth: Math.min(380, demo.width * 0.34)
        Layout.fillHeight: true
        rows: demo.model.rows
        rowIds: demo.model.ids
        windows: demo.model.windows
        query: search.text
        scopeMonitor: "HDMI-A-1"
        scopeWorkspace: 3
        focusedAddress: demo.focusedAddress
        onScopeSelected: search.forceActiveFocus()
        onActivated: function(address) {
          var window = demo.model.windows[address];
          demo.focusedAddress = address;
          demo.feedback = "Selected demo window: " + window.monitor + " / workspace " + window.workspaceId + " · " + window.title;
        }
      }
    }
    Text {
      Layout.fillWidth: true
      text: demo.feedback
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: Paperland.Theme.alpha(Paperland.Theme.foreground, 0.6)
      font.pixelSize: 12
    }
  }
}
