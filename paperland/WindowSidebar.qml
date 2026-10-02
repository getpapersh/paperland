pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC
import "Layout.js" as CanvasLayout
import "shared/WorkspaceCatalog.js" as WorkspaceCatalog
import "shared" as Shared

ColumnLayout {
  id: root
  property var rows: ({})
  property var rowIds: []
  property var windows: ({})
  property var badgeAddresses: []
  property string query: ""
  property string scope: "all"
  property string scopeMonitor: ""
  property int scopeWorkspace: -1
  property string focusedAddress: ""
  property string selectedAddress: ""
  property var iconFor: function(app) { return ""; }
  property var nameFor: function(app) { return CanvasLayout.appName(app); }
  property var items: []
  readonly property var matchIds: items.map(function(item) { return item.address; })
  readonly property var computedItems: CanvasLayout.sidebar(rows, rowIds, query, scope, scopeMonitor, scopeWorkspace, WorkspaceCatalog.customName)
  readonly property var displayGroups: {
    var groups = [];
    root.rowIds.forEach(function(id) {
      var row = root.rows[id];
      if (!row) return;
      var group = groups.find(function(item) { return item.name === row.monitor; });
      if (!group) {
        group = { name: row.monitor, windows: 0, desktops: 0 };
        groups.push(group);
      }
      group.windows += row.windows.length;
      if (!WorkspaceCatalog.isSpecial({ id: row.id, name: row.name })) group.desktops += 1;
    });
    return groups;
  }
  signal activated(string address)
  signal scopeSelected()
  spacing: 12

  onComputedItemsChanged: syncItems()
  Component.onCompleted: syncItems()
  function syncItems() {
    // Window details bind separately, so a title or geometry refresh need not
    // rebuild the list and reset its scroll position.
    var changed = JSON.stringify(items) !== JSON.stringify(computedItems);
    if (changed) items = computedItems;
    var previous = selectedAddress;
    if (matchIds.indexOf(selectedAddress) < 0)
      selectedAddress = matchIds.indexOf(focusedAddress) >= 0 ? focusedAddress : (matchIds[0] || "");
    if (changed || previous !== selectedAddress) Qt.callLater(ensureVisible);
  }
  function resetSelection() {
    selectedAddress = matchIds.indexOf(focusedAddress) >= 0 ? focusedAddress : (matchIds[0] || "");
    Qt.callLater(ensureVisible);
  }
  function menuAnchor(): point {
    var card = windowList.itemAtIndex(matchIds.indexOf(selectedAddress));
    if (card && card.y + card.height > windowList.contentY && card.y < windowList.contentY + windowList.height)
      return card.mapToItem(null, 0, Math.max(0, windowList.contentY - card.y));
    return root.mapToItem(null, width / 2, height / 2);
  }
  function ensureVisible() {
    var index = matchIds.indexOf(selectedAddress);
    if (index < 0) return;
    windowList.positionViewAtIndex(index, ListView.Contain);
    // Contain accounts for the viewport, but not the overlaid sticky label.
    var item = windowList.itemAtIndex(index);
    if (item && item.y < windowList.contentY + 29)
      windowList.contentY = Math.max(windowList.originY, item.y - 29);
  }
  function selectNext(direction) {
    if (!matchIds.length) return;
    var index = matchIds.indexOf(selectedAddress);
    selectedAddress = matchIds[(index + direction + matchIds.length) % matchIds.length];
    ensureVisible();
  }
  Keys.onDownPressed: selectNext(1)
  Keys.onUpPressed: selectNext(-1)
  Keys.onReturnPressed: if (selectedAddress) activated(selectedAddress)
  Keys.onEnterPressed: if (selectedAddress) activated(selectedAddress)

  Text {
    objectName: "sidebar-heading"
    text: root.query ? root.matchIds.length + (root.matchIds.length === 1 ? " matching window" : " matching windows")
      : root.matchIds.length + " windows"
    textFormat: Text.PlainText
    color: Theme.textPrimary
    font { family: Theme.fontFamily; pixelSize: 13; weight: Font.DemiBold }
  }
  ColumnLayout {
    objectName: "sidebar-display-groups"
    Layout.fillWidth: true
    spacing: 2
    Repeater {
      model: root.displayGroups
      delegate: Text {
        required property var modelData
        objectName: "sidebar-display-group-" + modelData.name
        Layout.fillWidth: true
        text: modelData.name + " · " + modelData.windows + (modelData.windows === 1 ? " window" : " windows")
          + " · " + modelData.desktops + (modelData.desktops === 1 ? " desktop" : " desktops")
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: Theme.textTertiary
        font { family: Theme.fontFamily; pixelSize: 11; weight: Font.Medium }
      }
    }
  }
  Rectangle {
    id: scopeTrack
    Layout.fillWidth: true
    implicitHeight: 32
    radius: 8
    color: Theme.surfaceControl
    RowLayout {
      anchors.fill: parent
      anchors.margins: 2
      spacing: 0
      Repeater {
        model: [{ value: "all", label: "All" }, { value: "display", label: "This display" }, { value: "workspace", label: "This workspace" }]
        delegate: Button {
          id: scopeSegment
          required property var modelData
          objectName: "scope-" + modelData.value
          Layout.fillWidth: true
          // Equal preferred widths make the segments equal despite their
          // different label lengths.
          Layout.preferredWidth: 1
          Layout.fillHeight: true
          text: modelData.label
          selected: root.scope === modelData.value
          focusable: true
          fontSize: 12
          leftPadding: 4
          rightPadding: 4
          verticalPadding: 0
          background: Rectangle {
            radius: 6
            color: scopeSegment.selected ? Theme.surfaceSelected : scopeSegment.hovered ? Theme.surfaceHover : "transparent"
          }
          contentItem: Text {
            text: scopeSegment.text
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: scopeSegment.selected ? Theme.textPrimary : Theme.textSecondary
            font { family: Theme.fontFamily; pixelSize: 12; weight: scopeSegment.selected ? Font.DemiBold : Font.Medium }
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
          }
          onClicked: {
            root.scope = modelData.value;
            root.forceActiveFocus();
            root.scopeSelected();
          }
        }
      }
    }
  }
  ListView {
    id: windowList
    objectName: "window-list"
    Layout.fillWidth: true
    Layout.fillHeight: true
    clip: true
    Accessible.role: Accessible.List
    spacing: 4
    model: root.items
    currentIndex: root.matchIds.indexOf(root.selectedAddress)
    section.property: "sectionLabel"
    section.criteria: ViewSection.FullString
    section.labelPositioning: ViewSection.InlineLabels | ViewSection.CurrentLabelAtStart
    section.delegate: Rectangle {
      id: sectionHeader
      required property string section
      readonly property int sectionCount: {
        var n = 0;
        root.items.forEach(function(item) { if (item.sectionLabel === sectionHeader.section) n += 1; });
        return n;
      }
      width: windowList.width
      height: 28
      color: "transparent"
      z: 2
      Text {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: parent.section
        textFormat: Text.PlainText
        elide: Text.ElideRight
        width: parent.width - sectionCount.width - 16
        color: Theme.textTertiary
        font { family: Theme.fontFamily; pixelSize: 11; weight: Font.DemiBold; letterSpacing: 0.6; capitalization: Font.AllUppercase }
      }
      Text {
        id: sectionCount
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: sectionHeader.sectionCount + (sectionHeader.sectionCount === 1 ? " window" : " windows")
        textFormat: Text.PlainText
        color: Theme.textTertiary
        font { family: Theme.fontFamily; pixelSize: 11 }
      }
    }
    QQC.ScrollBar.vertical: QQC.ScrollBar { }
    delegate: Rectangle {
      id: windowCard
      required property var modelData
      readonly property var window: root.windows[modelData.address] || null
      readonly property bool selected: root.selectedAddress === modelData.address
      readonly property bool focused: window && window.address === root.focusedAddress
      // Full state stays in the accessible name; the row itself only labels
      // the states worth acting on.
      readonly property string viewState: !window ? "" : focused ? "Focused" : window.visible ? "Visible" : ""
      readonly property string detailState: !window ? "" : focused ? "Focused"
        : window.visible ? "In view" : window.inView ? "Covered" : "Offscreen"
      objectName: "window-" + modelData.address
      width: windowList.width
      height: 52
      radius: 8
      color: selected ? Theme.accentSoft : windowMouse.containsMouse ? Theme.surfaceHover : "transparent"
      border.width: selected ? 1 : 0
      border.color: Theme.accent
      readonly property int badgeNumber: root.badgeAddresses.indexOf(modelData.address) + 1
      Shared.StripBadge {
        objectName: "sidebar-badge-" + windowCard.modelData.address
        anchors { right: parent.right; top: parent.top; margins: 3 }
        z: 2
        visible: windowCard.badgeNumber > 0 && windowCard.badgeNumber <= 9
        number: windowCard.badgeNumber
      }
      Accessible.role: Accessible.Button
      Accessible.selected: selected
      Accessible.name: window ? window.title + ", " + root.nameFor(window.app) + ", " + window.monitor + ", workspace " + window.workspaceId + ", " + detailState
        + (windowCard.badgeNumber > 0 && windowCard.badgeNumber <= 9 ? ", number " + windowCard.badgeNumber : "") : ""
      Accessible.onPressAction: root.activated(modelData.address)
      RowLayout {
        anchors.fill: parent
        anchors.margins: 10
        spacing: 10
        Item {
          Layout.preferredWidth: 24
          Layout.preferredHeight: 24
          Image {
            anchors.fill: parent
            source: windowCard.window ? root.iconFor(windowCard.window.app) : ""
            visible: source.toString() !== ""
            sourceSize.width: 32
            sourceSize.height: 32
            fillMode: Image.PreserveAspectFit
          }
        }
        ColumnLayout {
          Layout.fillWidth: true
          spacing: 3
          Text {
            Layout.fillWidth: true
            text: windowCard.window ? windowCard.window.title : ""
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: Theme.textPrimary
            font { family: Theme.fontFamily; pixelSize: 13; weight: Font.Medium }
          }
          RowLayout {
            Layout.fillWidth: true
            spacing: 5
            Rectangle {
              visible: windowCard.viewState !== ""
              Layout.preferredWidth: 6
              Layout.preferredHeight: 6
              radius: 3
              color: Theme.accent
            }
            Text {
              objectName: "sidebar-app-name"
              Layout.fillWidth: true
              text: {
                var w = windowCard.window;
                return w ? root.nameFor(w.app) + (w.pinned ? " · Pinned" : w.floating ? " · Floating" : "") + (w.groupSize > 1 ? " · Group of " + w.groupSize : "") : "";
              }
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: Theme.textTertiary
              font { family: Theme.fontFamily; pixelSize: 12 }
            }
            Text {
              Layout.alignment: Qt.AlignVCenter
              text: windowCard.viewState
              visible: windowCard.viewState !== ""
              color: Theme.accent
              font { family: Theme.fontFamily; pixelSize: 11; weight: Font.DemiBold }
            }
          }
        }
      }
      MouseArea {
        id: windowMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          root.selectedAddress = windowCard.modelData.address;
          root.activated(windowCard.modelData.address);
        }
        QQC.ToolTip {
          visible: windowMouse.containsMouse
          delay: 500
          contentItem: Text {
            text: windowCard.window ? windowCard.window.title : ""
            textFormat: Text.PlainText
            color: Theme.textPrimary
            font { family: Theme.fontFamily; pixelSize: 12 }
          }
          background: Rectangle { color: Theme.background; radius: 5; border.color: Theme.borderStrong }
        }
      }
    }
    Text {
      anchors.centerIn: parent
      width: parent.width - 24
      visible: root.items.length === 0
      text: root.query ? "No windows match “" + root.query + "” in this scope."
        : root.scope === "workspace" ? "No scrolling windows in this workspace."
        : "No scrolling windows in this scope."
      wrapMode: Text.WordWrap
      horizontalAlignment: Text.AlignHCenter
      color: Theme.textTertiary
      font { family: Theme.fontFamily; pixelSize: 13 }
    }
  }
}
