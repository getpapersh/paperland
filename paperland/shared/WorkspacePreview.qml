pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as QQC
import ".." as Paper
import "../Layout.js" as Layout
import "PreviewGeometry.js" as Geometry

FocusScope {
  id: root
  property url thumbnailSource
  property bool captureEnabled: false
  property bool spacious: false
  property rect captureViewport: Qt.rect(0, 0, width, height)
  property string query: ""
  property bool panEnabled: false
  signal panned(real delta)
  function changeZoom(factor: real): void { map.changeZoom(factor); }
  function fit(): void { map.fit(); }
  function currentView(): void { map.currentView(); }
  readonly property real chromeHeight: workspaceLabel.height + monitorLabel.height + footer.height + 24
  readonly property real bodyHeight: spacious ? Math.max(0, height - chromeHeight) : Math.max(80, height - 90)
  readonly property real desiredWidth: row ? row.bounds.width * map.preferredScale + 14 : 720
  readonly property real desiredHeight: row ? row.bounds.height * map.preferredScale + 14 + chromeHeight : 480
  property var iconFor: function(app) { return ""; }
  property var nameFor: function(app) { return Layout.appName(app); }
  property var entry: null
  property var row: null
  property var badgeAddresses: []
  property string focusedAddress: ""
  property bool keyboardMode: false
  property bool externalControl: false
  readonly property real mapZoom: map.zoom
  property color foreground: "#eeeeee"
  property color background: "#272727"
  property color accent: "#a55eab"
  property var addresses: []
  property var listAspects: ({})
  function listImage(address: string): var {
    return Geometry.imageSize(listAspects[address], width - 180, 220);
  }
  property var pendingListAspects: ({})
  function rememberListAspect(address: string, ratio: real): void {
    if (!spacious || addresses.indexOf(address) < 0 || ratio <= 0) return;
    pendingListAspects[address] = ratio;
    Qt.callLater(publishListAspects);
  }
  function publishListAspects(): void {
    var next = Object.assign({}, listAspects);
    var changed = false;
    Object.keys(pendingListAspects).forEach(function(address) {
      if (root.addresses.indexOf(address) >= 0 && next[address] !== root.pendingListAspects[address]) {
        next[address] = root.pendingListAspects[address];
        changed = true;
      }
    });
    pendingListAspects = {};
    if (changed) listAspects = next;
  }
  property string selectedAddress: ""
  readonly property int selectedIndex: items.findIndex(function(item) { return item.address === selectedAddress; })
  property var lastWorkspace: null
  readonly property var items: entry ? entry.windows : []
  signal activated(string address)
  function menuAnchor(): point {
    if (root.row) return map.menuAnchor(root.selectedAddress);
    var card = windowList.itemAtIndex(root.addresses.indexOf(root.selectedAddress));
    if (card && card.y + card.height > windowList.contentY && card.y < windowList.contentY + windowList.height)
      return card.mapToItem(null, 0, Math.max(0, windowList.contentY - card.y));
    return root.mapToItem(null, width / 2, height / 2);
  }
  signal windowMenuRequested(string address, point position)
  signal cancelled()
  implicitWidth: 480
  implicitHeight: 260
  function selectIndex(index: int): void {
    if (!keyboardMode) return;
    selectedAddress = items[index] ? items[index].address : "";
  }
  function revealSelection(): void {
    if (selectedIndex < 0) return;
    if (row) map.reveal(selectedAddress);
    else windowList.positionViewAtIndex(selectedIndex, ListView.Contain);
  }
  onSelectedAddressChanged: Qt.callLater(revealSelection)
  onSelectedIndexChanged: Qt.callLater(revealSelection)
  onItemsChanged: {
    var next = items.map(function(w) { return w.address; });
    if (JSON.stringify(next) !== JSON.stringify(addresses)) {
      addresses = next;
      var retained = {};
      next.forEach(function(address) { if (root.listAspects[address]) retained[address] = root.listAspects[address]; });
      listAspects = retained;
    }
    if (entry && entry.id !== lastWorkspace) {
      lastWorkspace = entry.id; map.fit(); selectIndex(0);
    } else if (!items.some(function(item) { return item.address === selectedAddress; })) selectIndex(0);
  }
  Keys.onPressed: function(event) {
    if (!root.keyboardMode) return;
    if ((event.key === Qt.Key_Menu || (event.key === Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier))) && root.selectedAddress) root.windowMenuRequested(root.selectedAddress, root.menuAnchor());
    else if (event.key === Qt.Key_Escape) root.cancelled();
    else if ([Qt.Key_Right, Qt.Key_Down, Qt.Key_Tab].indexOf(event.key) >= 0) selectIndex(Math.min(items.length - 1, selectedIndex + 1));
    else if ([Qt.Key_Left, Qt.Key_Up, Qt.Key_Backtab].indexOf(event.key) >= 0) selectIndex(Math.max(0, selectedIndex - 1));
    else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && items[selectedIndex]) root.activated(items[selectedIndex].address);
    else return;
    event.accepted = true;
  }
  Column {
    anchors.fill: parent
    spacing: 8
    WorkspaceLabel { id: workspaceLabel; entry: root.entry; foreground: root.foreground; maximumWidth: root.width; width: implicitWidth }
    Text {
      width: parent.width
      id: monitorLabel
      text: !root.entry ? "" : root.entry.special
        ? "Scratchpad · " + (root.entry.active ? "Open on " : "Closed on ") + root.entry.monitor
        : root.entry.monitor + (root.entry.active ? " · Current workspace" : " · Inactive workspace")
      textFormat: Text.PlainText
      color: root.foreground
      opacity: 0.7
      font.pixelSize: 11
    }
    Paper.CanvasMap {
      id: map
      objectName: "workspace-preview-map"
      captureViewport: Qt.rect(root.captureViewport.x, root.captureViewport.y - y, root.captureViewport.width, root.captureViewport.height)
      query: root.query
      minimumImageEdge: root.spacious ? 160 : 0
      visible: !!root.row && root.items.length > 0
      width: parent.width
      height: root.bodyHeight
      thumbnailSource: root.thumbnailSource
      captureEnabled: root.captureEnabled
      iconFor: root.iconFor
      nameFor: root.nameFor
      row: root.row
      badgeAddresses: root.badgeAddresses
      focusedAddress: root.focusedAddress
      selectedAddress: root.selectedAddress
      live: false
      externalControl: root.externalControl
      panEnabled: root.panEnabled
      onPanned: function(delta) { root.panned(delta); }
      foreground: root.foreground
      background: root.background
      accent: root.accent
      onActivated: function(address) { root.activated(address); }
      onWindowMenuRequested: function(address, position) { root.windowMenuRequested(address, position); }
    }
    ListView {
      id: windowList
      objectName: "workspace-preview-list"
      visible: !root.row && root.items.length > 0
      width: parent.width
      height: root.bodyHeight
      clip: true
      readonly property rect captureArea: {
        var x = Math.max(0, root.captureViewport.x);
        var y = Math.max(0, root.captureViewport.y - windowList.y);
        return Qt.rect(x, y, Math.max(0, Math.min(width, root.captureViewport.x + root.captureViewport.width) - x),
          Math.max(0, Math.min(height, root.captureViewport.y - windowList.y + root.captureViewport.height) - y));
      }
      flickableDirection: root.spacious ? Flickable.AutoFlickIfNeeded : Flickable.VerticalFlick
      contentWidth: root.spacious ? root.addresses.reduce(function(extent, address) {
        return Math.max(extent, root.listImage(address).width + 180);
      }, width) : width
      model: root.addresses
      currentIndex: root.selectedIndex
      QQC.ScrollBar.vertical: QQC.ScrollBar {}
      QQC.ScrollBar.horizontal: QQC.ScrollBar { policy: root.spacious ? QQC.ScrollBar.AsNeeded : QQC.ScrollBar.AlwaysOff }
      delegate: QQC.ItemDelegate {
        id: listCard
        required property string modelData
        readonly property var window: root.items.find(function(w) { return w.address === listCard.modelData; }) || ({app: "", title: ""})
        required property int index
        readonly property var imageSize: root.listImage(modelData)
        width: windowList.contentWidth
        height: root.thumbnailSource.toString() ? (root.spacious ? imageSize.height + topPadding + bottomPadding : 92) : 44
        focusPolicy: Qt.NoFocus
        text: root.nameFor(window.app) + " · " + window.title
        Accessible.name: text
        highlighted: root.keyboardMode && root.selectedIndex === index
        onClicked: root.activated(modelData)
        TapHandler { acceptedButtons: Qt.RightButton; onTapped: eventPoint => root.windowMenuRequested(listCard.modelData, listCard.mapToItem(null, eventPoint.position.x, eventPoint.position.y)) }
        contentItem: Item {
          ThumbnailSlot {
            id: imageSlot
            width: root.thumbnailSource.toString() ? (root.spacious ? listCard.imageSize.width : 110) : 24
            height: parent.height
            onAspectRatioChanged: root.rememberListAspect(listCard.modelData, aspectRatio)
            address: listCard.modelData
            thumbnailSource: root.thumbnailSource
            iconSource: root.iconFor(listCard.window.app)
            captureEnabled: root.captureEnabled
            viewport: Qt.rect(windowList.contentX + windowList.captureArea.x - listCard.leftPadding, windowList.contentY + windowList.captureArea.y - listCard.y - listCard.topPadding, windowList.captureArea.width, windowList.captureArea.height)
          }
          Column {
            x: imageSlot.width + 10
            width: parent.width - x
            anchors.verticalCenter: parent.verticalCenter
            spacing: 3
            Text { width: parent.width; text: root.nameFor(listCard.window.app); textFormat: Text.PlainText; elide: Text.ElideRight; color: root.foreground; font.bold: true; font.pixelSize: 13 }
            Text { width: parent.width; text: listCard.window.title; textFormat: Text.PlainText; elide: Text.ElideRight; color: root.foreground; opacity: 0.7; font.pixelSize: 11 }
          }
        }
        background: Rectangle { color: listCard.highlighted ? "#454545" : "transparent"; radius: 5 }
      }
    }
    Text {
      visible: root.items.length === 0
      width: parent.width
      height: root.bodyHeight
      text: root.entry && root.entry.count === 0
        ? (root.entry.special ? "No windows in the scratchpad." : "No windows on this workspace.")
        : "No previewable windows."
      color: root.foreground
      verticalAlignment: Text.AlignVCenter
      horizontalAlignment: Text.AlignHCenter
    }
    Text {
      width: parent.width
      id: footer
      wrapMode: Text.Wrap
      font.pixelSize: 11
      color: root.foreground
      opacity: 0.65
      text: root.entry && root.entry.count !== null && root.entry.count !== root.items.length
        ? root.entry.count + " native windows · " + root.items.length + " previewable (groups, hidden or pinned windows can differ)."
        : (root.row ? "Click a window to switch · Ctrl+wheel to zoom · Drag empty space to inspect" : "Click a window to switch")
    }
  }
}
