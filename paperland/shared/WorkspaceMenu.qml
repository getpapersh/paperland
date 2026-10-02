import QtQuick
import QtQuick.Controls as QQC
import "WorkspaceCatalog.js" as Catalog

FocusScope {
  id: root
  property var entry: null
  property int selectedIndex: 0
  // State of the scratchpad-follow preference, shown by the checkable item.
  property bool followChecked: false
  property bool settingsAvailable: false
  // Only the standalone app hosts the welcome tour.
  property bool welcomeAvailable: false
  // Windows the close-all action counts ({address, stableId}); hosts confirm and close this list.
  readonly property var closable: Catalog.closableWindows(entry)
  readonly property var actions: (!entry ? [] : entry.special
    ? [{ key: "windows", label: "Show windows" },
       { key: "follow", label: "Show windows in minimap while open", checked: followChecked }]
    : (entry.active ? [] : [{ key: "switch", label: "Switch to workspace " + entry.id }])
      .concat([{ key: "windows", label: "Show windows" }, { key: "rename", label: "Rename…" }, { key: "clear", label: "Clear custom name" }])
      .concat(closable.length ? [{ key: "close", label: Catalog.closeAllLabel(closable.length) }] : []))
      .concat(settingsAvailable && entry ? [{ key: "settings", label: "Settings…" }] : [])
      .concat(welcomeAvailable && entry ? [{ key: "welcome", label: "Replay welcome tour…" }] : [])
  signal chosen(string action)
  signal cancelled()
  implicitWidth: 300
  implicitHeight: actions.length * 42
  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Escape) root.cancelled();
    else if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab) selectedIndex = (selectedIndex + 1) % actions.length;
    else if (event.key === Qt.Key_Up || event.key === Qt.Key_Backtab) selectedIndex = (selectedIndex + actions.length - 1) % actions.length;
    else if ((event.key === Qt.Key_Enter || event.key === Qt.Key_Return) && actions[selectedIndex]) root.chosen(actions[selectedIndex].key);
    else return;
    event.accepted = true;
  }
  Column {
    anchors.fill: parent
    Repeater {
      model: root.actions
      delegate: QQC.ItemDelegate {
        id: actionItem
        required property var modelData
        required property int index
        objectName: "workspace-menu-action-" + modelData.key
        width: root.width
        height: 42
        text: modelData.label
        highlighted: root.selectedIndex === index
        onClicked: root.chosen(modelData.key)
        // The checkable item is a checkbox: its state comes from the role,
        // not from a decorated name.
        Accessible.role: actionItem.modelData.checked !== undefined ? Accessible.CheckBox : Accessible.Button
        Accessible.name: actionItem.modelData.label
        Accessible.checked: actionItem.modelData.checked === true
        contentItem: Text { text: parent.text; textFormat: Text.PlainText; color: "#eeeeee"; font.pixelSize: 13; verticalAlignment: Text.AlignVCenter }
        background: Rectangle { color: parent.highlighted || parent.hovered ? "#454545" : "transparent"; radius: 5 }
        Text {
          visible: actionItem.modelData.checked !== undefined
          text: actionItem.modelData.checked ? "✓" : ""
          anchors.right: parent.right; anchors.rightMargin: 14
          anchors.verticalCenter: parent.verticalCenter
          color: "#eeeeee"; font.pixelSize: 13
        }
      }
    }
  }
}
