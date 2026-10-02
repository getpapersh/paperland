pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as QQC
import "Layout.js" as CanvasLayout
import "MiniLayout.js" as MiniLayout
import "shared/PreviewGeometry.js" as PreviewGeometry
import "shared" as Shared

Rectangle {
  id: root
  property url thumbnailSource
  property bool captureEnabled: false
  property var row: null
  property var workspaces: []
  property var remoteWorkspaces: []
  property var destinations: []
  property var tabs: []
  readonly property var visibleTabs: vertical && collapsed ? tabs.filter(function(tab) { return tab.active; }) : tabs
  property var scratchpad: null
  property var shortcutBinding: null
  property bool scratchpadOpen: false
  property var addresses: []
  property var badgeAddresses: []
  property int hitMonitorId: -1
  property real hitMonitorX: 0
  property real hitMonitorY: 0
  property var selectedAddresses: []
  property var selectedIds: ({})
  property string selectionAnchor: ""
  property var dragDestinations: []
  property var dragRemoteWorkspaces: []
  property bool dragSnapshotReady: false
  readonly property var offeredDestinations: draggingSelection && dragSnapshotReady ? dragDestinations : destinations
  readonly property var offeredRemoteWorkspaces: draggingSelection && dragSnapshotReady ? dragRemoteWorkspaces : remoteWorkspaces
  readonly property var remoteMonitorNames: offeredRemoteWorkspaces.map(function(entry) { return entry.monitor; })
    .filter(function(name, index, names) { return names.indexOf(name) === index; })
  property bool draggingSelection: false
  property point dragStart: Qt.point(0, 0)
  property real dragDeltaX: 0
  property real dragDeltaY: 0
  property int dragWorkspace: -1
  property var dragReorder: null
  property point dragPoint: Qt.point(0, 0)
  property int remoteEdge: 0
  readonly property var cardHitBoxes: {
    if (!stripRow || collapsed) return [];
    return addresses.map(function(address) {
      var window = root.windowFor(address);
      if (!window) return null;
      var box = MiniLayout.box(stripRow, window, vertical ? strip.height : strip.width);
      var cross = MiniLayout.crossBox(stripRow, window, vertical ? strip.width : 44);
      return [hitMonitorX + root.x + strip.x + (vertical ? cross.position : box.position),
        hitMonitorY + root.y + strip.y + (vertical ? box.position : 3 + cross.position),
        vertical ? cross.size : box.size, vertical ? box.size : cross.size];
    }).filter(function(box) { return box && box[2] > 0 && box[3] > 0; });
  }
  function selectedInOrder(): var {
    return addresses.filter(function(address) {
      var window = windowFor(address);
      return selectedAddresses.indexOf(address) >= 0 && window && window.stableId === selectedIds[address];
    });
  }
  function toggleSelection(address: string): void {
    var window = windowFor(address);
    if (!window || !window.stableId) return;
    var next = selectedAddresses.slice();
    var ids = Object.assign({}, selectedIds);
    var index = next.indexOf(address);
    if (index >= 0) {
      next.splice(index, 1);
      delete ids[address];
      if (selectionAnchor === address) selectionAnchor = next.length ? next[next.length - 1] : "";
    } else {
      next.push(address);
      ids[address] = window.stableId;
      selectionAnchor = address;
    }
    selectedIds = ids;
    selectedAddresses = next;
  }
  function extendSelection(address: string): void {
    var start = addresses.indexOf(selectionAnchor || address);
    var end = addresses.indexOf(address);
    if (start < 0 || end < 0) return;
    var range = addresses.slice(Math.min(start, end), Math.max(start, end) + 1);
    var retained = selectedInOrder();
    var ids = Object.assign({}, selectedIds);
    range.forEach(function(item) {
      var window = windowFor(item);
      if (window && window.stableId) ids[item] = window.stableId;
    });
    selectedIds = ids;
    selectedAddresses = addresses.filter(function(item) {
      return (retained.indexOf(item) >= 0 || range.indexOf(item) >= 0) && !!ids[item];
    });
    if (!selectionAnchor) selectionAnchor = address;
  }
  // Hover preview popover: the first show dwells, later cards retarget at once.
  property string hoverAddress: ""
  property string previewAddress: ""
  readonly property bool previewSuppressed: collapsed || !enabled || thumbnailSource.toString() === ""
    || draggingSelection || gripMouse.pressed || scrubMouse.pressed || workspaceScroll.dragging
  onPreviewSuppressedChanged: if (previewSuppressed) hidePreview()
  function hoverCard(address: string, inside: bool): void {
    if (inside) {
      hoverAddress = address;
      previewHide.stop();
      if (previewAddress !== "" && !previewSuppressed) previewAddress = address;
      else previewDwell.restart();
    } else if (hoverAddress === address) {
      hoverAddress = "";
      previewDwell.stop();
      previewHide.restart();
    }
  }
  function hidePreview(): void {
    previewDwell.stop(); previewHide.stop();
    previewAddress = "";
  }
  Timer {
    id: previewDwell
    interval: 500
    onTriggered: if (root.hoverAddress !== "" && !root.previewSuppressed) root.previewAddress = root.hoverAddress
  }
  // Short grace so gliding across the gap between cards keeps the popover.
  Timer { id: previewHide; interval: 120; onTriggered: if (root.hoverAddress === "") root.previewAddress = "" }
  function selectAllWindows(): void {
    var ids = {};
    var next = addresses.filter(function(address) {
      var window = root.windowFor(address);
      if (window && window.stableId) ids[address] = window.stableId;
      return !!ids[address];
    });
    selectedIds = ids;
    selectedAddresses = next;
    selectionAnchor = next.length ? next[next.length - 1] : "";
  }
  function clearSelection(): void {
    selectedIds = ({}); selectedAddresses = []; selectionAnchor = "";
  }
  function targetAt(point: point): int {
    var floatingTargets = [floatGroup, countTab, railGroup];
    for (var index = 0; index < floatingTargets.length; index++) {
      var floating = floatingTargets[index];
      if (!floating.visible) continue;
      var within = floating.mapFromItem(root, point.x, point.y);
      if (within.x >= 0 && within.y >= 0 && within.x < floating.width && within.y < floating.height) return -2;
    }
    if (remoteScroll.visible) {
      var remoteViewport = remoteScroll.mapFromItem(root, point.x, point.y);
      if (remoteViewport.x >= 0 && remoteViewport.y >= 0 && remoteViewport.x < remoteScroll.width && remoteViewport.y < remoteScroll.height) {
        for (var remoteIndex = 0; remoteIndex < remoteRepeater.count; remoteIndex++) {
          var remotePill = remoteRepeater.itemAt(remoteIndex);
          if (!remotePill) continue;
          var remotePoint = remotePill.mapFromItem(root, point.x, point.y);
          if (remotePoint.x >= 0 && remotePoint.y >= 0 && remotePoint.x < remotePill.width && remotePoint.y < remotePill.height)
            return offeredRemoteWorkspaces[remoteIndex].id;
        }
      }
    }
    // The portrait + sits in the header's second row, outside the pill
    // viewport; only it may bypass the guard below.
    var railPlus = railNewPill.mapFromItem(root, point.x, point.y);
    if (railNewPill.visible && railPlus.x >= 0 && railPlus.y >= 0 && railPlus.x < railNewPill.width && railPlus.y < railNewPill.height) return 0;
    var viewport = workspaceScroll.mapFromItem(root, point.x, point.y);
    if (viewport.x < 0 || viewport.y < 0 || viewport.x >= workspaceScroll.width || viewport.y >= workspaceScroll.height) return -1;
    var plus = newPill.mapFromItem(root, point.x, point.y);
    if (newPill.visible && plus.x >= 0 && plus.y >= 0 && plus.x < newPill.width && plus.y < newPill.height) return 0;
    for (var i = 0; i < workspaceRepeater.count; i++) {
      var pill = workspaceRepeater.itemAt(i);
      if (!pill) continue;
      var local = pill.mapFromItem(root, point.x, point.y);
      if (local.x >= 0 && local.y >= 0 && local.x < pill.width && local.y < pill.height) return visibleTabs[i].id;
    }
    return -1;
  }
  function reorderAt(point: point): var {
    if (!stripRow) return null;
    var local = strip.mapFromItem(root, point.x, point.y);
    if (local.x < 0 || local.y < 0 || local.x >= strip.width || local.y >= strip.height) return null;
    for (var i = 0; i < stripRow.windows.length; i++) {
      var window = stripRow.windows[i];
      if (selectedInOrder().indexOf(window.address) >= 0) continue;
      var box = MiniLayout.box(stripRow, window, vertical ? strip.height : strip.width);
      var cross = MiniLayout.crossBox(stripRow, window, vertical ? strip.width : 44);
      var x = vertical ? cross.position : box.position;
      var y = vertical ? box.position : 3 + cross.position;
      var width = vertical ? cross.size : box.size;
      var height = vertical ? box.size : cross.size;
      if (local.x >= x && local.y >= y && local.x < x + width && local.y < y + height)
        return { anchor: window.address, after: (vertical ? local.y - y >= height / 2 : local.x - x >= width / 2) };
    }
    return null;
  }
  function trackRemoteEdge(point: point): void {
    remoteEdge = 0;
    if (!remoteScroll.visible || vertical || remoteScroll.contentWidth <= remoteScroll.width) return;
    var local = remoteScroll.mapFromItem(root, point.x, point.y);
    if (local.y < 0 || local.y >= remoteScroll.height || local.x < 0 || local.x >= remoteScroll.width) return;
    if (local.x < 14 && remoteScroll.contentX > 0) remoteEdge = -1;
    else if (local.x >= remoteScroll.width - 14 && remoteScroll.contentX < remoteScroll.contentWidth - remoteScroll.width) remoteEdge = 1;
  }
  Timer {
    interval: 32; repeat: true
    running: root.draggingSelection && root.remoteEdge !== 0
    onTriggered: {
      remoteScroll.contentX = Math.max(0, Math.min(remoteScroll.contentWidth - remoteScroll.width,
        remoteScroll.contentX + root.remoteEdge * 8));
      root.trackRemoteEdge(root.dragPoint);
      root.dragWorkspace = root.targetAt(root.dragPoint);
    }
  }
  function endSelectionDrag(point: point): void {
    var workspace = targetAt(point);
    var reorder = workspace === -1 ? reorderAt(point) : null;
    var selected = selectedInOrder();
    var ids = {};
    selected.forEach(function(address) { ids[address] = selectedIds[address]; });
    var offered = offeredDestinations.find(function(entry) { return entry.kind === "existing" && entry.id === workspace; }) || null;
    draggingSelection = false;
    dragSnapshotReady = false; dragDestinations = []; dragRemoteWorkspaces = [];
    dragDeltaX = 0; dragDeltaY = 0; dragWorkspace = -1; dragReorder = null; remoteEdge = 0;
    if ((workspace >= 0 || workspace === -2) && selected.length) selectionDropRequested(selected, workspace, null, ids, offered);
    else if (reorder && selected.length) selectionDropRequested(selected, row.id, reorder, ids, null);
  }
  // Keyed by address like `addresses`, so a floating window's title or focus
  // order changing does not rebuild its chip or list row mid-click.
  property var floatAddresses: []
  property string focusedAddress: ""
  property bool pinned: false
  property bool peek: true
  property int backgroundOpacity: 96
  property bool collapsed: false
  property bool moved: false
  property bool panEnabled: false
  property bool pointerInside: false
  // The count tab and its list sit outside the strip, so the strip's own hover
  // cannot see them; both hold the strip revealed.
  readonly property bool interacting: pointerInside || gripMouse.pressed || scrubMouse.pressed || workspaceScroll.dragging
    || tabHover.hovered || floatListOpen || draggingSelection
  property var iconFor: function(app) { return ""; }
  property var nameFor: function(app) { return CanvasLayout.appName(app); }
  property color accent: "#a55eab"
  readonly property bool vertical: !!row && row.vertical
  // Cards, extent, stacking and the scrubber follow tiled windows only; floating
  // windows have no column and are shown as chips instead.
  readonly property var stripRow: CanvasLayout.tiledRow(row)
  readonly property var floats: row ? row.windows.filter(function(w) { return CanvasLayout.isFloating(w); }) : []
  // "group": the full Floating group in the header. "count": condensed to one
  // chip in a tab above the controls, so the pills never lose width to floats.
  // "rail": a portrait rail's row below its strip.
  readonly property string floatMode: floats.length === 0 ? "" : vertical ? "rail"
    : MiniLayout.floatGroupFits(header.width, pills.width, controls.width,
        MiniLayout.floatGroupWidth(floatLabel.width, floats.length)) ? "group" : "count"
  property bool floatListOpen: false
  onFloatModeChanged: if (floatMode !== "count") floatListOpen = false
  onEnabledChanged: if (!enabled) floatListOpen = false
  // Pointer input the host surface must accept beyond the strip's rectangle,
  // in the strip's coordinates.
  readonly property rect floatTabRect: countTab.visible ? Qt.rect(countTab.x, countTab.y, countTab.width, countTab.height) : Qt.rect(0, 0, 0, 0)
  readonly property real topReach: countTab.visible ? -countTab.y : 0
  readonly property var focusedWindow: row ? row.windows.find(function(w) { return w.address === root.focusedAddress; }) : null
  readonly property real headerHeight: vertical
    ? (collapsed ? 64 : controls.height + 6 + pills.height + 8)
    : 18 + (remoteOverflow ? 22 : 0)
  readonly property real warningHeight: splitWarning !== "" ? Math.max(18, warningText.implicitHeight + 6) : 0
  readonly property bool warningBelow: moved && y < warningHeight + 4
  readonly property bool remoteOverflow: draggingSelection && offeredRemoteWorkspaces.length > 0 && !vertical
    && (Math.max(pills.width + 8, (header.width - remotePills.width) / 2) + remotePills.width
      > (selectionCount.visible ? selectionCount.x : (floatGroup.visible ? floatGroup.x : controls.x)) - 8)
  readonly property bool completeStack: CanvasLayout.hasCompleteStack(stripRow, selectedInOrder())
  readonly property string splitWarning: {
    if (!draggingSelection || !completeStack) return "";
    if (dragWorkspace === 0) return "Stack may split on new Desktop";
    var destination = offeredDestinations.find(function(entry) { return entry.kind === "existing" && entry.id === dragWorkspace; });
    if (!destination || !destination.layout) return dragWorkspace > 0 ? "Stack may split on this Desktop" : "";
    var current = destinations.find(function(entry) { return entry.kind === "existing" && entry.id === destination.id; });
    if (!current || current.name !== destination.name || current.monitor !== destination.monitor
        || current.monitorId !== destination.monitorId || current.selector !== destination.selector)
      return "Desktop changed; drop will cancel";
    return current.layout !== "scrolling" ? "Stack will split on this Desktop" : "";
  }
  readonly property bool canPan: panEnabled && !!row && row.active && !row.fullscreen
  signal activated(string address)
  signal selectionDropRequested(var addresses, int workspace, var reorder, var ids, var offered)
  signal windowMenuRequested(string address, point position)
  signal workspaceActivated(int workspace)
  signal workspaceMenuRequested(int workspace, point position)
  signal scratchpadToggleRequested()
  signal scratchpadMenuRequested(point position)
  signal newWorkspaceRequested()
  function scrollWheel(event: WheelEvent): void {
    if (!root.canPan) { event.accepted = false; return; }
    var pixels = root.vertical ? event.pixelDelta.y : event.pixelDelta.x || event.pixelDelta.y;
    var angle = root.vertical ? event.angleDelta.y : event.angleDelta.x || event.angleDelta.y;
    root.scrubbed(pixels ? -pixels : -angle / 120 * 160);
    event.accepted = true;
  }
  signal scrubbed(real delta)
  signal scrubStarted()
  signal scrubLanded()
  signal scrubCancelled()
  // Address the in-progress drag would focus on release; empty when not dragging.
  property string pendingLanding: ""

  // True once the pointer is over the scrubber, and throughout a drag. The host
  // window takes exclusive keyboard focus while this holds, which is what stops
  // Hyprland cancelling the pan: a numeric tape move refocuses the column at the
  // viewport centre with a hard focus reason, and that re-centres or re-fits it,
  // returning the camera. An exclusive layer surface suppresses that refocus.
  // Acquiring on hover rather than on press is load-bearing: the compositor
  // releases all mouse buttons when a layer becomes exclusive, which would
  // cancel the very drag that asked for it.
  readonly property bool scrubEngaged: scrubMouse.enabled && !scrubHandoff
    && scrubArmed && (scrubMouse.containsMouse || scrubMouse.pressed)
  // Exclusive keyboard focus is taken on deliberate hover, not on transit. The
  // compositor routes every keystroke to this layer while it is held, so a
  // pointer merely crossing the scrubber must not swallow the user's typing.
  property bool scrubArmed: false
  Timer { id: armTimer; interval: 150; onTriggered: root.scrubArmed = scrubMouse.containsMouse }
  // Set the moment a drag ends so exclusive focus is released before the
  // landing is applied. A focus dispatch made while this layer still owns the
  // keyboard is ignored, and the compositor then restores the previous window.
  // Cleared shortly after, so hovering still re-arms the next drag.
  property bool scrubHandoff: false
  // Keep the latch set while a button is still down: re-acquiring exclusive
  // focus mid-press would make the compositor release that button. A drag begun
  // inside this window therefore cannot pan; it ends as an ordinary cancel.
  Timer { id: handoffTimer; interval: 200; onTriggered: root.scrubHandoff = scrubMouse.pressed }
  function endScrub(cancelled) {
    scrubHandoff = true;
    handoffTimer.restart();
    if (cancelled) root.scrubCancelled(); else root.scrubLanded();
  }
  signal pinToggled()
  signal peekToggled()
  signal hideRequested()
  signal overviewRequested()
  signal settingsRequested()
  implicitWidth: vertical ? 150 : 1000
  implicitHeight: collapsed ? (vertical ? 84 : 40)
    : vertical ? Math.max(480, strip.y + 120 + 10 + (railGroup.visible ? railGroup.height + 6 : 0))
      : 104 + (remoteOverflow ? 22 : 0)
  radius: 12
  color: Qt.rgba(39 / 255, 39 / 255, 39 / 255, backgroundOpacity / 100)
  border.color: "#707070"
  border.width: 0.75
  // A portrait rail keeps its contents inside its rounded edge. A landscape
  // strip must not clip: its count tab and list sit outside it.
  clip: vertical && !draggingSelection
  function trackPointer(position) {
    pointerInside = position.x >= 0 && position.y >= 0 && position.x < width && position.y < height;
  }
  HoverHandler {
    id: hover
    onHoveredChanged: root.pointerInside = hovered
    onPointChanged: if (hovered && !gripMouse.pressed && !scrubMouse.pressed) root.trackPointer(point.position)
  }

  onWorkspacesChanged: syncTabs()
  onStripRowChanged: {
    syncWindows(); selectedAddresses = selectedInOrder();
    var ids = {};
    selectedAddresses.forEach(function(address) { ids[address] = selectedIds[address]; });
    selectedIds = ids;
    if (selectedAddresses.indexOf(selectionAnchor) < 0) selectionAnchor = selectedAddresses.length ? selectedAddresses[selectedAddresses.length - 1] : "";
  }
  Component.onCompleted: { syncTabs(); syncWindows(); }
  function syncTabs() {
    if (JSON.stringify(tabs) !== JSON.stringify(workspaces)) tabs = workspaces;
  }
  function syncWindows() {
    var ids = stripRow ? stripRow.windows.map(function(w) { return w.address; }) : [];
    if (JSON.stringify(ids) !== JSON.stringify(addresses)) addresses = ids;
    var floating = floats.map(function(w) { return w.address; });
    if (JSON.stringify(floating) !== JSON.stringify(floatAddresses)) floatAddresses = floating;
  }
  function windowFor(address) { return row ? row.windows.find(function(w) { return w.address === address; }) : null; }
  function clampPosition() {
    // A hidden layer surface reports no size; clamping against it would move
    // a dragged strip to the corner and lose its position for this process.
    if (!parent || parent.width <= 0 || parent.height <= 0) return;
    x = Math.max(0, Math.min(x, parent.width - width));
    y = Math.max(topReach, Math.min(y, parent.height - height));
  }
  onHeightChanged: if (moved) clampPosition()
  onTopReachChanged: if (moved) clampPosition()
  onWidthChanged: if (moved) clampPosition()
  Connections {
    target: root.parent
    function onWidthChanged() { if (root.moved) root.clampPosition(); }
    function onHeightChanged() { if (root.moved) root.clampPosition(); }
  }

  Item {
    id: header
    z: 30
    x: 12; y: 10
    width: parent.width - 24
    height: root.headerHeight
    Flickable {
      id: workspaceScroll
      objectName: "mini-workspaces"
      x: 0; y: root.vertical ? controls.height + 6 : 0
      width: root.vertical ? header.width
        : Math.max(0, (selectionCount.visible ? selectionCount.x : (floatGroup.visible ? floatGroup.x : controls.x)) - 8)
      height: root.vertical ? Math.max(18, header.height - y) : 18
      contentWidth: root.vertical ? width : pills.width
      contentHeight: root.vertical ? pills.height + (root.collapsed ? 0 : 8) : height
      flickableDirection: root.vertical ? Flickable.VerticalFlick : Flickable.HorizontalFlick
      interactive: !root.vertical
      clip: true
      Grid {
        id: pills
        columns: root.vertical ? 1 : root.tabs.length + 1 + (scratchpadPill.visible ? 1 : 0)
        spacing: 4
        NewWorkspaceControl { id: newPill; objectName: "mini-new-workspace"; visible: !root.vertical }
        Repeater {
          id: workspaceRepeater
          model: root.visibleTabs
          delegate: Rectangle {
            id: pill
            required property var modelData
            objectName: "workspace-" + modelData.id
            width: root.vertical ? workspaceScroll.width : Math.max(18, Math.min(170, pillLabel.width + 14))
            height: 18
            radius: height / 2
            readonly property bool fadedForScratchpad: modelData.active && root.scratchpadOpen
            opacity: fadedForScratchpad ? 0.55 : 1
            color: root.draggingSelection && root.dragWorkspace === modelData.id && root.splitWarning !== "" ? "#654825"
              : modelData.active ? root.accent : modelData.count ? "#414141" : "transparent"
            border.color: root.draggingSelection && root.dragWorkspace === modelData.id && root.splitWarning !== "" ? "#e6aa4b"
              : root.draggingSelection && root.dragWorkspace === modelData.id ? root.accent
              : modelData.active ? "#bb83c0" : "#565656"
            border.width: root.draggingSelection && root.dragWorkspace === modelData.id ? 2 : fadedForScratchpad ? 0 : 1
            clip: true
            Accessible.role: Accessible.Button
            Accessible.name: pillLabel.accessibleName
            Accessible.onPressAction: root.workspaceActivated(modelData.id)
            Shared.WorkspaceLabel {
              id: pillLabel
              x: 7; anchors.verticalCenter: parent.verticalCenter
              width: implicitWidth
              entry: pill.modelData
              foreground: pill.modelData.active ? "white" : "#c0c0c0"
              fontSize: 11
              maximumWidth: root.vertical ? workspaceScroll.width - 14 : 160
            }
            Shared.ScratchpadOutline {
              anchors.fill: parent
              visible: pill.fadedForScratchpad
              accent: root.accent
            }
            MouseArea {
              id: pillMouse
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              onClicked: function(event) {
                if (event.button === Qt.RightButton) root.workspaceMenuRequested(pill.modelData.id, pillMouse.mapToItem(null, event.x, event.y));
                else root.workspaceActivated(pill.modelData.id);
              }
            }
          }
        }
        Shared.ScratchpadPill {
          id: scratchpadPill
          objectName: "scratchpad-pill"
          entry: root.scratchpad
          shortcutBinding: root.shortcutBinding
          open: root.scratchpadOpen
          showName: !root.vertical
          pillEnabled: !root.vertical || !root.collapsed || root.scratchpadOpen
          width: root.vertical ? workspaceScroll.width : implicitWidth
          onToggled: root.scratchpadToggleRequested()
          onMenuRequested: function(position) { root.scratchpadMenuRequested(position); }
        }
      }
    }
    Rectangle {
      id: selectionCount
      objectName: "mini-selection-count"
      // Portrait: centred in the count band below the divider.
      visible: root.selectedInOrder().length > 0 && (!root.vertical || countBand.height > 0)
      x: root.vertical ? (header.width - width) / 2 : (floatGroup.visible ? floatGroup.x : controls.x) - width - 6
      y: root.vertical ? countBand.y - header.y : workspaceScroll.y
      width: Math.min(header.width, countText.implicitWidth + 12)
      height: root.vertical ? countBand.height : 18
      radius: height / 2
      color: "#49344d"
      border.color: root.accent
      Text {
        id: countText
        objectName: "mini-selection-count-text"
        anchors.centerIn: parent
        width: Math.min(implicitWidth, parent.width - 12)
        elide: Text.ElideRight
        text: root.selectedInOrder().length + " selected"
        color: "#ead7ec"
        font.pixelSize: 10
        font.bold: true
      }
      Accessible.role: Accessible.StaticText
      Accessible.name: root.selectedInOrder().length + " selected"
    }
    Rectangle {
      id: remoteGroup
      objectName: "mini-remote-group"
      visible: root.vertical && remoteScroll.visible
      x: remoteScroll.x - 4; y: header.height - 2
      width: remoteScroll.width + 8; height: remoteScroll.y + remoteScroll.height + 4 - y
      radius: 7
      color: "#15121b"
      border.width: 0
      Accessible.role: Accessible.Grouping
      Accessible.name: remoteHeading.text
      Text {
        id: remoteHeading
        objectName: "mini-remote-heading"
        x: 7; y: 6
        width: parent.width - 14
        text: (root.remoteMonitorNames.length === 1 ? "Display " : "Displays ") + root.remoteMonitorNames.join(", ")
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        color: "#e0bde4"
        font.pixelSize: 11
        font.bold: true
        Accessible.role: Accessible.StaticText
        Accessible.name: text
      }
    }
    Flickable {
      id: remoteScroll
      objectName: "mini-remote-workspaces"
      visible: root.draggingSelection && root.offeredRemoteWorkspaces.length > 0
      x: root.vertical || root.remoteOverflow ? 0 : Math.max(pills.width + 8, (header.width - remotePills.width) / 2)
      y: root.vertical ? remoteGroup.y + remoteHeading.height + 12 : root.remoteOverflow ? 22 : 0
      width: root.vertical ? header.width : root.remoteOverflow
        ? Math.max(0, (floatGroup.visible ? floatGroup.x : controls.x) - 8) : remotePills.width
      height: root.vertical ? remotePills.height : 18
      contentWidth: root.vertical ? width : remotePills.width
      contentHeight: root.vertical ? remotePills.height : height
      flickableDirection: root.vertical ? Flickable.VerticalFlick : Flickable.HorizontalFlick
      interactive: !root.vertical
      clip: true
      Grid {
        id: remotePills
        columns: root.vertical ? 1 : root.offeredRemoteWorkspaces.length
        width: root.vertical ? remoteScroll.width : implicitWidth
        height: implicitHeight
        spacing: 4
        Repeater {
          id: remoteRepeater
          model: root.offeredRemoteWorkspaces
          delegate: Rectangle {
            id: remotePill
            required property var modelData
            objectName: "remote-workspace-" + modelData.id
            width: root.vertical ? remoteScroll.width : Math.max(18, Math.min(170, remoteLabel.width + 14))
            height: 18
            radius: height / 2
            color: root.dragWorkspace === modelData.id ? (root.splitWarning !== "" ? "#654825" : "#49344d") : "#34343a"
            border.color: root.dragWorkspace === modelData.id ? (root.splitWarning !== "" ? "#e6aa4b" : root.accent) : "#77777f"
            border.width: root.dragWorkspace === modelData.id ? 2 : 1
            Accessible.role: Accessible.Button
            Accessible.name: "Monitor " + modelData.monitor + ", " + remoteLabel.accessibleName + ". Drop selected windows here"
            Shared.WorkspaceLabel {
              id: remoteLabel
              x: 7; anchors.verticalCenter: parent.verticalCenter
              entry: remotePill.modelData
              foreground: "#dedee2"
              fontSize: 11
              maximumWidth: root.vertical ? remotePill.width - 14 : 160
            }
          }
        }
      }
    }
    Text {
      objectName: "mini-focused-name"
      anchors.centerIn: parent
      visible: !root.vertical && (!remoteScroll.visible || root.remoteOverflow)
        && pills.width < header.width / 2 - width / 2 - 12
        && header.width / 2 + width / 2 + 12 <= (floatGroup.visible ? floatGroup.x : controls.x)
      text: root.selectedInOrder().length ? "" : root.focusedWindow ? root.nameFor(root.focusedWindow.app) : ""
      textFormat: Text.PlainText
      width: Math.min(140, implicitWidth)
      elide: Text.ElideRight
      color: "#a0a0a0"
      font.pixelSize: 11
      font.bold: true
      Accessible.role: Accessible.StaticText
      Accessible.name: text
    }
    Rectangle {
      id: floatGroup
      objectName: "mini-floating-group"
      visible: root.floatMode === "group" || (root.draggingSelection && !root.vertical && root.floatMode !== "count")
      anchors.right: controls.left
      anchors.rightMargin: 6
      anchors.verticalCenter: controls.verticalCenter
      readonly property var split: MiniLayout.chipSplit(root.floatAddresses.length, 5)
      width: groupRow.width + 12
      height: 26
      radius: 7
      color: root.draggingSelection && root.dragWorkspace === -2 ? "#49344d" : Qt.rgba(1, 1, 1, 0.10)
      border.color: root.draggingSelection && root.dragWorkspace === -2 ? root.accent : Qt.rgba(1, 1, 1, 0.14)
      border.width: root.draggingSelection && root.dragWorkspace === -2 ? 2 : 1
      Accessible.role: Accessible.Grouping
      Accessible.name: root.draggingSelection ? "Floating. Drop selected windows here" : "Floating windows"
      Row {
        id: groupRow
        x: 6
        anchors.verticalCenter: parent.verticalCenter
        spacing: 4
        FloatLabel { id: floatLabel; anchors.verticalCenter: parent.verticalCenter }
        Repeater {
          model: floatGroup.visible ? root.floatAddresses.slice(0, floatGroup.split.shown) : []
          delegate: FloatChip { required property string modelData; address: modelData }
        }
        OverflowChip { visible: floatGroup.split.overflow > 0; hidden: root.floatAddresses.slice(floatGroup.split.shown) }
      }
    }
    // Landscape: one row of 18 px controls, 24 px apart, right of the pills. The
    // controls do not fit a 112-150 px rail, so it follows PaperMac's rail header
    // above the pills: pin, collapse, close and a move bar filling the row, then
    // +, Search, Settings and Peek share the second row.
    Item {
      id: controls
      anchors.right: parent.right
      // Not a top/bottom anchor swap: while both were briefly set on a strip
      // turning portrait, they sized this to the landscape header and the
      // height binding never returned, pushing the pills under the controls.
      y: root.vertical ? 0 : header.height - height
      width: root.vertical ? header.width : 162
      height: root.vertical ? 40 : 18
      NewWorkspaceControl { id: railNewPill; objectName: "mini-rail-new-workspace"; visible: root.vertical; y: 22 }
      MiniControl {
        objectName: "mini-search"
        kind: "search"
        x: root.vertical ? 22 : 0
        y: root.vertical ? 22 : 0
        tooltipText: "Search all windows"
        onClicked: root.overviewRequested()
      }
      MiniControl {
        objectName: "mini-settings"
        kind: "settings"
        x: root.vertical ? 44 : 24
        y: root.vertical ? 22 : 0
        tooltipText: "Open Paperland Settings"
        onClicked: root.settingsRequested()
      }
      MiniControl {
        objectName: "mini-peek"
        kind: "peek"
        x: root.vertical ? 66 : 48
        y: root.vertical ? 22 : 0
        selected: root.peek
        tooltipText: root.peek ? "Peek on: appears as you navigate, then hides"
          : "Peek off: stays until you show or hide it"
        onClicked: root.peekToggled()
      }
      MiniControl { objectName: "mini-pin"; x: root.vertical ? 0 : 72; kind: "pin"; selected: root.pinned; tooltipText: root.pinned ? "Unpin: fade after inactivity" : "Pin the minimap open"; onClicked: root.pinToggled(); }
      MiniControl { objectName: "mini-collapse"; x: root.vertical ? 22 : 96; kind: "collapse"; selected: root.collapsed; tooltipText: root.collapsed ? "Expand minimap" : "Collapse minimap"; onClicked: root.collapsed = !root.collapsed; }
      MiniControl { objectName: "mini-hide"; x: root.vertical ? 44 : 120; kind: "close"; tooltipText: "Hide this minimap"; onClicked: root.hideRequested(); }
      MiniControl {
        kind: "move"
        x: root.vertical ? 66 : 144
        width: root.vertical ? controls.width - 66 : 18
        tooltipText: "Drag to move the minimap"
        MouseArea {
          id: gripMouse
          objectName: "mini-grip"
          anchors.fill: parent
          cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
          // The parent surface covers the display; item drag coordinates stay
          // stable while the input region follows the moved card.
          drag.target: root
          drag.onActiveChanged: if (drag.active) root.moved = true
          drag.minimumX: 0
          drag.minimumY: root.topReach
          drag.maximumX: root.parent ? Math.max(0, root.parent.width - root.width) : 0
          drag.maximumY: root.parent ? Math.max(0, root.parent.height - root.height) : 0
          onReleased: function(event) { root.trackPointer(mapToItem(root, event.x, event.y)); }
        }
      }
    }
  }
  Rectangle {
    objectName: "mini-split-warning"
    z: 40
    visible: root.splitWarning !== ""
    x: header.x; y: root.warningBelow ? root.height + 4 : -root.warningHeight - 4
    width: header.width; height: root.warningHeight
    radius: 5
    color: "#654825"
    border.color: "#e6aa4b"
    Text {
      id: warningText
      anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 6 }
      text: root.splitWarning
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      horizontalAlignment: Text.AlignHCenter
      color: "#f5d098"
      font.pixelSize: 10
    }
    Accessible.role: Accessible.AlertMessage
    Accessible.name: warningText.text
  }

  Rectangle {
    id: canvasDivider
    objectName: "mini-canvas-divider"
    visible: root.vertical && !root.collapsed
    x: header.x; y: header.y + header.height - 2 + (root.vertical && remoteScroll.visible ? remoteHeading.height + remoteScroll.height + 22 : 0)
    width: header.width; height: 1
    color: Qt.rgba(1, 1, 1, 0.18)
  }
  // Reserved on an expanded rail whether or not cards are selected, so the
  // count appearing never moves the window preview.
  Item {
    id: countBand
    objectName: "mini-count-band"
    x: header.x; y: canvasDivider.y + 5
    width: header.width; height: root.vertical && !root.collapsed ? 14 : 0
  }
  Item {
    id: strip
    objectName: "mini-windows"
    visible: !root.collapsed
    x: 12; y: root.vertical ? countBand.y + countBand.height + 4 : header.y + header.height + 6
    width: root.width - 24 - (root.vertical ? 10 : 0)
    height: root.vertical ? Math.max(0, root.height - y - 10 - (railGroup.visible ? railGroup.height + 6 : 0)) : 50
    clip: !root.draggingSelection
    Repeater {
      id: cardRepeater
      model: root.addresses
      delegate: Rectangle {
        id: card
        required property string modelData
        readonly property var window: root.windowFor(modelData)
        readonly property var box: window && root.stripRow ? MiniLayout.box(root.stripRow, window, root.vertical ? strip.height : strip.width) : ({ position: 0, size: 0 })
        readonly property var cross: window && root.stripRow ? MiniLayout.crossBox(root.stripRow, window, root.vertical ? strip.width : 44) : ({ position: 0, size: 0 })
        readonly property bool focused: modelData === root.focusedAddress
        readonly property bool selected: root.selectedInOrder().indexOf(modelData) >= 0
        readonly property int selectedIndex: root.selectedInOrder().indexOf(modelData)
        readonly property int badgeNumber: root.badgeAddresses.indexOf(modelData) + 1
        // Where a release would land. Accent at reduced opacity reads as "not
        // yet focused" without inventing a second colour for a transient state.
        readonly property bool landing: !focused && modelData === root.pendingLanding
        readonly property real priorCaptionWidth: Math.max(0, width - (icon.source.toString() ? 34 : 10) - 9)
        // Preserve any caption that fit before; already elided text keeps a
        // useful reading area instead of surrendering it to the thumbnail.
        readonly property real captionNeeded: Math.max(
          appName.implicitWidth <= priorCaptionWidth ? appName.implicitWidth : Math.min(120, priorCaptionWidth),
          height >= 36 ? (windowTitle.implicitWidth <= priorCaptionWidth ? windowTitle.implicitWidth : Math.min(120, priorCaptionWidth)) : 0)
        objectName: "mini-window-" + modelData
        x: selected && root.draggingSelection
          ? Math.max(0, Math.min(strip.width - width, root.dragStart.x + root.dragDeltaX - strip.x + 14 + selectedIndex * 14))
          : root.vertical ? cross.position : box.position
        y: selected && root.draggingSelection
          ? root.dragStart.y + root.dragDeltaY - strip.y + 20 + selectedIndex * 4
          : root.vertical ? box.position : 3 + cross.position
        width: selected && root.draggingSelection ? Math.min(160, root.vertical ? cross.size : box.size)
          : root.vertical ? cross.size : box.size
        height: root.vertical ? box.size : cross.size
        z: selected && root.draggingSelection ? 20 + selectedIndex : focused ? 2 : 1
        radius: 5
        clip: true
        opacity: landing ? 0.6 : window && !window.inView && !focused ? 0.48 : 1
        color: focused || landing ? root.accent : cardMouse.containsMouse ? "#505050" : "#3d3d3d"
        border.color: focused || landing ? "#be89c3" : "#525252"
        border.width: 0.75
        Rectangle {
          visible: root.dragReorder && root.dragReorder.anchor === card.modelData
          x: root.vertical ? 0 : root.dragReorder && root.dragReorder.after ? card.width - 3 : 0
          y: root.vertical && root.dragReorder && root.dragReorder.after ? card.height - 3 : 0
          width: root.vertical ? card.width : 3
          height: root.vertical ? 3 : card.height
          color: root.accent
          z: 5
        }
        Shared.StripBadge {
          objectName: "mini-badge-" + card.modelData
          anchors { right: parent.right; top: parent.top; margins: 3 }
          z: 3
          visible: card.badgeNumber > 0 && card.badgeNumber <= 9
          number: card.badgeNumber
        }
        Accessible.role: Accessible.Button
        Accessible.selected: selected
        Accessible.name: window ? root.nameFor(window.app) + ", " + window.title
          + (window.inView ? ", in current view" : ", offscreen")
          + (badgeNumber > 0 && badgeNumber <= 9 ? ", number " + badgeNumber : "") : ""
        Accessible.onPressAction: root.activated(modelData)
        Rectangle {
          anchors.fill: parent
          anchors.margins: 2
          radius: 4
          color: "transparent"
          border.color: card.selected ? (card.focused ? "#f4e5f5" : root.accent) : "transparent"
          border.width: card.selected ? 2 : 0
          z: 4
        }
        Shared.ThumbnailSlot {
          id: thumbnail
          objectName: "mini-thumbnail-" + card.modelData
          readonly property bool tall: root.vertical && card.height >= 105
          x: 6; y: 4
          width: tall ? card.width - 12 : Math.min(64, card.width - card.captionNeeded - 23)
          height: tall ? Math.min(64, card.height - 44) : card.height - 8
          visible: root.thumbnailSource.toString() !== "" && (tall || width >= 32) && height >= 20
          address: card.modelData
          thumbnailSource: root.thumbnailSource
          iconSource: card.window ? root.iconFor(card.window.app) : ""
          captureEnabled: root.captureEnabled && !root.collapsed
          viewport: Qt.rect(-card.x - x, -card.y - y, strip.width, strip.height)
        }
        Image {
          id: icon
          x: 10; anchors.verticalCenter: parent.verticalCenter
          width: 16; height: 16
          visible: !thumbnail.visible && card.width >= 20 && card.height >= 20
          source: card.window ? root.iconFor(card.window.app) : ""
          sourceSize.width: 32; sourceSize.height: 32
          fillMode: Image.PreserveAspectFit
        }
        Column {
          x: thumbnail.visible && !thumbnail.tall ? thumbnail.x + thumbnail.width + 8 : icon.visible && icon.source.toString() ? 34 : 10
          y: thumbnail.visible && thumbnail.tall ? thumbnail.y + thumbnail.height + 4 : (parent.height - height) / 2
          width: parent.width - x - 9
          spacing: 2
          visible: card.width >= 70 && card.height >= 20
          Text {
            width: parent.width
            id: appName
            objectName: "mini-app-name"
            text: card.window ? root.nameFor(card.window.app) : ""
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: "#f4f4f4"
            font.pixelSize: 13
            font.bold: true
          }
          Text {
            width: parent.width
            visible: card.height >= 36
            id: windowTitle
            objectName: "mini-window-title"
            text: card.window ? card.window.title : ""
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: card.focused ? "#e0c7e3" : "#a0a0a0"
            font.pixelSize: 11
          }
        }
        MouseArea {
          id: cardMouse
          // Native wheel delivery targets the card's MouseArea; the strip's
          // WheelHandler alone does not receive these events on Wayland.
          onWheel: function(event) { root.scrollWheel(event); }
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.BackButton | Qt.ForwardButton
          property bool suppressClick: false
          onContainsMouseChanged: root.hoverCard(card.modelData, containsMouse)
          onPressed: function(event) {
            root.hidePreview();
            suppressClick = false;
            if (event.button === Qt.RightButton) return;
            root.dragStart = mapToItem(root, event.x, event.y);
          }
          onPositionChanged: function(event) {
            if (!(pressedButtons & (Qt.LeftButton | Qt.ForwardButton))) return;
            var position = mapToItem(root, event.x, event.y);
            var dx = position.x - root.dragStart.x, dy = position.y - root.dragStart.y;
            if (!root.draggingSelection && Math.hypot(dx, dy) >= 6) {
              if (!card.selected) {
                var ids = {}; ids[card.modelData] = card.window.stableId;
                root.selectedIds = ids; root.selectedAddresses = [card.modelData]; root.selectionAnchor = card.modelData;
              }
              root.dragDestinations = root.destinations.map(function(entry) { return Object.assign({}, entry); });
              root.dragRemoteWorkspaces = root.remoteWorkspaces.map(function(entry) { return Object.assign({}, entry); });
              root.dragSnapshotReady = true;
              root.draggingSelection = true;
            }
            if (root.draggingSelection) {
              root.dragDeltaX = dx; root.dragDeltaY = dy;
              root.dragPoint = position;
              root.trackRemoteEdge(position);
              root.dragWorkspace = root.targetAt(position);
              root.dragReorder = root.dragWorkspace === -1 ? root.reorderAt(position) : null;
            }
          }
          onReleased: function(event) {
            if (!root.draggingSelection) return;
            suppressClick = true;
            root.endSelectionDrag(mapToItem(root, event.x, event.y));
          }
          onCanceled: {
            suppressClick = true;
            root.draggingSelection = false; root.dragSnapshotReady = false; root.dragDestinations = []; root.dragRemoteWorkspaces = [];
            root.dragDeltaX = 0; root.dragDeltaY = 0; root.dragWorkspace = -1; root.dragReorder = null; root.remoteEdge = 0;
          }
          onClicked: function(event) {
            if (suppressClick) { suppressClick = false; return; }
            if (event.button === Qt.RightButton) root.windowMenuRequested(card.modelData, cardMouse.mapToItem(null, event.x, event.y));
            else if (event.button === Qt.BackButton || event.modifiers & Qt.ShiftModifier) root.extendSelection(card.modelData);
            else if (event.button === Qt.ForwardButton) root.toggleSelection(card.modelData);
            else { root.clearSelection(); root.activated(card.modelData); }
          }
          QQC.ToolTip {
            id: cardTip
            objectName: "mini-card-tooltip"
            // The passive popover takes no input, so its stopwatch tooltip is out of
            // reach; the card itself carries a cached frame's acquisition time.
            readonly property bool cachedPreview: preview.visible && root.previewAddress === card.modelData
              && previewImage.cached && previewImage.capturedAt > 0
            readonly property string label: cachedPreview
              ? "Last captured: " + Qt.formatDateTime(new Date(previewImage.capturedAt), "yyyy-MM-dd hh:mm:ss")
              : card.window ? card.window.title : ""
            // The popover carries the title wherever thumbnails exist.
            visible: cardMouse.containsMouse && (root.thumbnailSource.toString() === "" || cachedPreview)
            delay: 500
            // Open on the side away from the popover.
            x: !root.vertical ? (card.width - width) / 2 : preview.leading ? card.width + 4 : -width - 4
            y: root.vertical ? (card.height - height) / 2 : preview.leading ? card.height + 4 : -height - 4
            contentItem: Text { text: cardTip.label; textFormat: Text.PlainText; color: "white"; font.pixelSize: 12 }
            background: Rectangle { color: "#272727"; radius: 5; border.color: "#707070" }
          }
        }
      }
    }
    Text {
      anchors.centerIn: parent
      visible: root.addresses.length === 0
      text: root.floats.length ? "No tiled windows" : "No windows"
      color: "#a0a0a0"
      font.pixelSize: 12
    }
    WheelHandler {
      target: null
      onWheel: function(event) { root.scrollWheel(event); }
    }
  }
  Item {
    id: scrubber
    objectName: "mini-scrubber"
    visible: !root.collapsed && !!root.row && root.row.active
    x: root.vertical ? root.width - 16 : 12
    y: root.vertical ? strip.y : strip.y + strip.height + 6
    width: root.vertical ? 6 : root.width - 24
    height: root.vertical ? strip.height : 6
    readonly property real extent: root.vertical ? height : width
    readonly property var thumb: MiniLayout.thumb(root.stripRow, extent)
    Rectangle { anchors.fill: parent; anchors.margins: 1; radius: 3; color: "#4c4c4c" }
    Rectangle {
      objectName: "mini-thumb"
      x: root.vertical ? 0 : scrubber.thumb.position
      y: root.vertical ? scrubber.thumb.position : 0
      width: root.vertical ? 6 : scrubber.thumb.size
      height: root.vertical ? scrubber.thumb.size : 6
      radius: 3
      color: root.canPan ? "#aaaaaa" : "#737373"
    }
    MouseArea {
      id: scrubMouse
      anchors.fill: parent
      anchors.margins: -3
      enabled: root.canPan
      // Hover, not just press: the host window has to already hold exclusive
      // keyboard focus before the button goes down. See root.scrubEngaged.
      hoverEnabled: true
      onContainsMouseChanged: {
        if (containsMouse) armTimer.restart();
        else if (!pressed) { armTimer.stop(); root.scrubArmed = false; }
      }
      cursorShape: root.vertical ? Qt.SizeVerCursor : Qt.SizeHorCursor
      // Right button cancels an in-flight drag; the pointer is already here.
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      property real lastPosition: 0
      property real frozenRatio: 0
      property bool dragging: false
      onPressed: function(event) {
        if (event.button === Qt.RightButton) {
          if (dragging) { dragging = false; root.endScrub(true); }
          return;
        }
        dragging = true;
        root.scrubStarted();
        lastPosition = root.vertical ? event.y - 3 : event.x - 3;
        frozenRatio = scrubber.thumb.pixelsToCanvas;
        if (lastPosition < scrubber.thumb.position || lastPosition > scrubber.thumb.position + scrubber.thumb.size)
          root.scrubbed((lastPosition - scrubber.thumb.position - scrubber.thumb.size / 2) * frozenRatio);
      }
      onPositionChanged: function(event) {
        if (!pressed || !dragging) return;
        var position = root.vertical ? event.y - 3 : event.x - 3;
        root.scrubbed((position - lastPosition) * frozenRatio);
        lastPosition = position;
      }
      // HoverHandler stops updating during this MouseArea's exclusive grab.
      // Use the release point so an outside release resumes the fade timer.
      onReleased: function(event) {
        if (event.button === Qt.LeftButton && dragging) { dragging = false; root.endScrub(false); }
        else if (root.scrubHandoff) handoffTimer.restart();
        root.trackPointer(mapToItem(root, event.x, event.y));
      }
      onCanceled: { if (dragging) { dragging = false; root.endScrub(true); } }
      // The strip holds exclusive keyboard focus while the scrubber is engaged,
      // so Escape is actually deliverable here during a drag.
      Keys.onEscapePressed: function(event) {
        if (dragging) { dragging = false; root.endScrub(true); event.accepted = true; }
        else event.accepted = false;
      }
      focus: dragging
    }
  }
  Rectangle {
    id: railGroup
    objectName: "mini-floating-rail"
    visible: (root.floatMode === "rail" || root.draggingSelection && root.vertical) && !root.collapsed
    readonly property var split: MiniLayout.chipSplit(root.floatAddresses.length, MiniLayout.railSlots(width))
    x: 12
    y: root.height - 10 - height
    width: root.width - 24
    height: 44
    radius: 7
    color: root.draggingSelection && root.dragWorkspace === -2 ? "#49344d" : Qt.rgba(1, 1, 1, 0.10)
    border.color: root.draggingSelection && root.dragWorkspace === -2 ? root.accent : Qt.rgba(1, 1, 1, 0.14)
    border.width: root.draggingSelection && root.dragWorkspace === -2 ? 2 : 1
      Accessible.role: Accessible.Grouping
    Accessible.name: root.draggingSelection ? "Floating. Drop selected windows here" : "Floating windows"
    FloatLabel { x: 6; y: 4 }
    Row {
      x: 6; y: 18
      spacing: 4
      Repeater {
        model: railGroup.visible ? root.floatAddresses.slice(0, railGroup.split.shown) : []
        delegate: FloatChip { required property string modelData; address: modelData }
      }
      OverflowChip { visible: railGroup.split.overflow > 0; hidden: root.floatAddresses.slice(railGroup.split.shown) }
    }
  }

  // Condensed floats: a tab forming a row above the controls, right-aligned
  // with them. Drawn beneath the strip so the strip's border closes it off.
  Rectangle {
    id: countTab
    objectName: "mini-floating-tab"
    visible: root.floatMode === "count"
    z: -1
    x: root.width - 12 - width
    y: -24
    width: countChip.width + 8
    height: 30
    radius: 7
    color: root.color
    border.color: root.draggingSelection && root.dragWorkspace === -2 ? root.accent : root.border.color
    border.width: root.draggingSelection && root.dragWorkspace === -2 ? 2 : root.border.width
    HoverHandler { id: tabHover }
    Item {
      id: countChip
      objectName: "mini-floating-count"
      readonly property bool focused: root.floats.some(function(w) { return w.address === root.focusedAddress; })
      x: 4; y: 3
      width: countBody.width + 4
      height: 22
      Accessible.role: Accessible.Button
      Accessible.name: root.draggingSelection ? "Floating. Drop selected windows here" : "Floating windows, " + root.floats.length
      Accessible.selected: focused
      Accessible.onPressAction: root.floatListOpen = !root.floatListOpen
      Rectangle {
        id: countBody
        anchors.centerIn: parent
        width: countContent.width + 10
        height: 18
        radius: 4
        color: countChip.focused ? root.floatAccent : Qt.rgba(1, 1, 1, 0.10)
        // The fill as seen, lift included; the glyph's front square masks with it.
        readonly property color shown: Qt.tint(countChip.focused ? root.floatAccent : countTab.color, Qt.rgba(1, 1, 1, 0.10))
        border.width: 1
        border.color: countChip.focused ? Qt.rgba(1, 1, 1, 0.9) : Qt.rgba(1, 0.62, 0.22, 0.75)
        Rectangle { anchors.fill: parent; radius: 4; visible: countChip.focused; color: Qt.rgba(1, 1, 1, 0.10) }
        Row {
          id: countContent
          anchors.centerIn: parent
          spacing: 3
          // Two offset squares: the floating-windows glyph.
          Item {
            anchors.verticalCenter: parent.verticalCenter
            width: 10; height: 10
            readonly property color stroke: countChip.focused ? "#272727" : "#ffc38a"
            Rectangle { x: 0; y: 3; width: 7; height: 7; radius: 1.5; color: "transparent"; border.width: 1.1; border.color: parent.stroke }
            Rectangle { x: 3; y: 0; width: 7; height: 7; radius: 1.5; color: countBody.shown; border.width: 1.1; border.color: parent.stroke }
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: String(root.floats.length)
            color: countChip.focused ? "#272727" : "#e6e6e6"
            font.pixelSize: 10
            font.bold: true
          }
        }
      }
      MouseArea {
        id: countMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.floatListOpen = !root.floatListOpen
        Tip {
          objectName: "mini-floating-count-tip"
          visible: countMouse.containsMouse && !root.floatListOpen
          label: root.floats.map(function(w) { return w.title; }).join("\n")
        }
      }
    }
  }

  // Any click outside the list closes it, as the window menu does; the host
  // surface accepts input everywhere while the list is open.
  MouseArea {
    objectName: "mini-floating-dismiss"
    visible: root.floatListOpen
    z: 50
    x: root.parent ? -root.x : 0
    y: root.parent ? -root.y : 0
    width: root.parent ? root.parent.width : 0
    height: root.parent ? root.parent.height : 0
    acceptedButtons: Qt.AllButtons
    onPressed: root.floatListOpen = false
  }
  Rectangle {
    id: floatList
    objectName: "mini-floating-list"
    visible: root.floatListOpen
    z: 51
    // Capped to the room on its side of the strip and clamped onto the
    // display by MiniLayout; the rows scroll inside the clipped view.
    readonly property var placement: MiniLayout.floatListPlacement(
      { width: 240, height: listColumn.height + 8 },
      Qt.rect(root.x, root.y, root.width, root.height),
      Qt.rect(root.x + countTab.x, root.y + countTab.y, countTab.width, countTab.height),
      root.parent ? Qt.size(root.parent.width, root.parent.height) : Qt.size(0, 0))
    x: placement.x - root.x
    y: placement.y - root.y
    width: placement.width
    height: placement.height
    radius: 8
    color: "#f5272727"
    border.color: "#707070"
    border.width: 0.75
    Accessible.role: Accessible.List
    Accessible.name: "Floating windows"
    Flickable {
      id: listScroll
      objectName: "mini-floating-scroll"
      x: 4; y: 4
      width: parent.width - 8
      height: parent.height - 8
      contentWidth: listColumn.width
      contentHeight: listColumn.height
      boundsBehavior: Flickable.StopAtBounds
      clip: true
      Column {
        id: listColumn
        width: listScroll.width
        Repeater {
          model: root.floatListOpen ? root.floatAddresses : []
          delegate: Rectangle {
            id: listRow
            required property string modelData
            readonly property var window: root.windowFor(modelData)
            readonly property bool focused: modelData === root.focusedAddress
            objectName: "mini-floating-row-" + modelData
            width: listColumn.width
            height: 30
            radius: 5
            color: focused ? Qt.rgba(1, 0.62, 0.22, 0.28) : rowMouse.containsMouse ? "#454545" : "transparent"
            Accessible.role: Accessible.Button
            Accessible.name: window ? root.nameFor(window.app) + ", " + window.title : ""
            Accessible.selected: focused
            Accessible.onPressAction: root.pickFloat(modelData)
            FloatIcon { x: 8; anchors.verticalCenter: parent.verticalCenter; size: 16; app: listRow.window ? listRow.window.app : "" }
            Column {
              x: 32
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - 40
              Text {
                width: parent.width
                text: listRow.window ? root.nameFor(listRow.window.app) : ""
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: "#f4f4f4"
                font.pixelSize: 11
                font.bold: true
              }
              Text {
                width: parent.width
                text: listRow.window ? listRow.window.title : ""
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: listRow.focused || rowMouse.containsMouse ? "#e6e6e6" : "#a0a0a0"
                font.pixelSize: 10
              }
            }
            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              onClicked: function(event) {
                if (event.button === Qt.RightButton) {
                  root.floatListOpen = false;
                  root.windowMenuRequested(listRow.modelData, rowMouse.mapToItem(null, event.x, event.y));
                } else root.pickFloat(listRow.modelData);
              }
            }
          }
        }
      }
    }
  }
  readonly property color floatAccent: "#ff9e38"
  function pickFloat(address: string): void {
    floatListOpen = false;
    activated(address);
  }

  // Landscape keeps + in the pill grid; a portrait rail shows its own copy in
  // the header's second row. Both share the drop and warning state.
  component NewWorkspaceControl: MiniControl {
    kind: "add"
    selected: root.draggingSelection && root.dragWorkspace === 0
    warning: root.splitWarning !== ""
    tooltipText: root.draggingSelection && root.splitWarning !== ""
      ? "Drop to move selected windows. " + root.splitWarning + "."
      : root.draggingSelection ? "Drop to move selected windows to a new Desktop" : "New workspace"
    onClicked: root.newWorkspaceRequested()
  }
  Rectangle {
    id: preview
    objectName: "mini-hover-preview"
    readonly property var window: root.windowFor(root.previewAddress)
    readonly property Item card: {
      var index = root.addresses.indexOf(root.previewAddress);
      return index >= 0 ? cardRepeater.itemAt(index) : null;
    }
    readonly property Item host: root.parent || root
    // mapToItem is not reactive; the sums only register the geometry it depends on.
    readonly property real moves: root.x + root.y + strip.x + strip.y + (card ? card.x + card.y : 0)
    readonly property point cardOrigin: card ? card.mapToItem(host, moves * 0, 0) : Qt.point(0, 0)
    readonly property point stripOrigin: root.mapToItem(host, moves * 0, 0)
    // Room beside the strip, outside a 10 px gap and an 8 px screen margin.
    readonly property real before: (root.vertical ? stripOrigin.x : stripOrigin.y) - 18
    readonly property real after: (root.vertical ? host.width - stripOrigin.x - root.width : host.height - stripOrigin.y - root.height) - 18
    readonly property real chrome: footer.implicitHeight + 22
    // The popover is passive and cannot scroll, so the image shrinks to the room
    // on the larger side rather than keeping the scrollable preview's 160 px edge.
    readonly property var image: {
      var maxWidth = (root.vertical ? Math.max(before, after) : host.width - 16) - 16;
      var maxHeight = (root.vertical ? host.height - 16 : Math.max(before, after)) - chrome;
      var aspect = window && window.rect.height > 0 ? window.rect.width / window.rect.height : 0;
      return PreviewGeometry.fitWithin(PreviewGeometry.imageSize(aspect, maxWidth, 180), maxWidth, maxHeight);
    }
    readonly property real extent: root.vertical ? width : height
    readonly property bool leading: before >= extent || before >= after
    parent: host
    visible: !!window && !!card && !root.previewSuppressed
    z: 1000
    width: image.width + 16
    height: image.height + chrome
    x: Math.max(8, Math.min(host.width - width - 8, root.vertical
      ? (leading ? stripOrigin.x - width - 10 : stripOrigin.x + root.width + 10)
      : cardOrigin.x + (card ? card.width : 0) / 2 - width / 2))
    y: Math.max(8, Math.min(host.height - height - 8, root.vertical
      ? cardOrigin.y + (card ? card.height : 0) / 2 - height / 2
      : (leading ? stripOrigin.y - height - 10 : stripOrigin.y + root.height + 10)))
    radius: 8
    color: Theme.switcherSurface
    border.color: Theme.switcherSurfaceBorder
    Accessible.role: Accessible.ToolTip
    Accessible.name: window ? root.nameFor(window.app) + ", " + window.title : ""
    Shared.ThumbnailSlot {
      id: previewImage
      objectName: "mini-hover-preview-image"
      x: 8; y: 8
      width: preview.image.width; height: preview.image.height
      address: root.previewAddress
      thumbnailSource: root.thumbnailSource
      iconSource: preview.window ? root.iconFor(preview.window.app) : ""
      label: preview.window ? root.nameFor(preview.window.app) : ""
      captureEnabled: root.captureEnabled && preview.visible
    }
    Column {
      id: footer
      x: 10; y: preview.image.height + 14
      width: preview.width - 20
      spacing: 1
      Text {
        width: parent.width
        text: preview.window ? root.nameFor(preview.window.app) : ""
        textFormat: Text.PlainText; elide: Text.ElideRight
        color: Theme.switcherTextPrimary; font.pixelSize: 12; font.bold: true
      }
      Text {
        objectName: "mini-hover-preview-title"
        width: parent.width
        text: preview.window ? preview.window.title : ""
        textFormat: Text.PlainText; elide: Text.ElideRight
        color: Theme.switcherTextTertiary; font.pixelSize: 11
      }
    }
  }
  component Tip: QQC.ToolTip {
    id: tip
    property string label
    delay: 500
    contentItem: Text { text: tip.label; textFormat: Text.PlainText; color: "white"; font.pixelSize: 12 }
    background: Rectangle { color: "#272727"; radius: 5; border.color: "#707070" }
  }
  // 8.5 px label; font pixel sizes are integers, so a 9 px face is scaled down.
  component FloatLabel: Item {
    width: labelText.implicitWidth * 8.5 / 9
    height: labelText.implicitHeight * 8.5 / 9
    Text {
      id: labelText
      objectName: "mini-floating-label"
      // PaperMac's label is "Floating", drawn uppercase.
      text: "Floating"
      font.capitalization: Font.AllUppercase
      color: "#a0a0a0"
      font.pixelSize: 9
      font.weight: Font.DemiBold
      font.letterSpacing: 0.4
      scale: 8.5 / 9
      transformOrigin: Item.TopLeft
    }
  }
  // The app icon, or the app name's first letter when no icon loads.
  component FloatIcon: Item {
    id: floatIcon
    required property string app
    property real size: 13
    // Drawn on the orange focused fill, where light text falls short of contrast.
    property bool onAccent: false
    width: size; height: size
    Image {
      id: iconImage
      anchors.fill: parent
      source: root.iconFor(floatIcon.app)
      sourceSize.width: 32; sourceSize.height: 32
      fillMode: Image.PreserveAspectFit
      mipmap: true
    }
    Text {
      anchors.centerIn: parent
      visible: iconImage.status !== Image.Ready
      text: root.nameFor(floatIcon.app).charAt(0).toUpperCase()
      color: floatIcon.onAccent ? "#272727" : "#f4f4f4"
      font.pixelSize: Math.round(floatIcon.size * 0.8)
      font.bold: true
    }
  }
  component FloatChip: Item {
    id: floatChip
    required property string address
    readonly property var window: root.windowFor(address)
    readonly property bool focused: address === root.focusedAddress
    objectName: "mini-floating-" + address
    width: 22; height: 22
    Accessible.role: Accessible.Button
    Accessible.name: window ? root.nameFor(window.app) + ", " + window.title + ", floating window" : ""
    Accessible.selected: focused
    Accessible.onPressAction: root.activated(address)
    Rectangle {
      anchors.centerIn: parent
      width: 18; height: 18
      radius: 4
      color: floatChip.focused ? root.floatAccent : Qt.rgba(1, 1, 1, 0.10)
      border.width: 1
      border.color: floatChip.focused ? Qt.rgba(1, 1, 1, 0.9) : Qt.rgba(1, 0.62, 0.22, 0.75)
      Rectangle { anchors.fill: parent; radius: 4; visible: floatChip.focused; color: Qt.rgba(1, 1, 1, 0.10) }
      FloatIcon { anchors.centerIn: parent; app: floatChip.window ? floatChip.window.app : ""; onAccent: floatChip.focused }
    }
    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: function(event) {
        if (event.button === Qt.RightButton) root.windowMenuRequested(floatChip.address, chipMouse.mapToItem(null, event.x, event.y));
        else root.activated(floatChip.address);
      }
      Tip { objectName: "mini-floating-tip"; visible: chipMouse.containsMouse; label: floatChip.window ? floatChip.window.title : "" }
    }
  }
  // Summarises windows without chips; it is not a window, so it has no actions.
  component OverflowChip: Item {
    id: overflowChip
    // Addresses of the windows without chips.
    property var hidden: []
    readonly property var titles: hidden.map(function(address) { var w = root.windowFor(address); return w ? w.title : ""; })
    objectName: "mini-floating-overflow"
    width: 22; height: 22
    Accessible.role: Accessible.StaticText
    Accessible.name: hidden.length + " more floating windows: " + titles.join(", ")
    Rectangle {
      anchors.centerIn: parent
      width: 18; height: 18
      radius: 4
      color: Qt.rgba(1, 1, 1, 0.10)
      border.width: 0.5
      border.color: Qt.rgba(1, 1, 1, 0.14)
      Text {
        anchors.centerIn: parent
        text: "+" + overflowChip.hidden.length
        color: "#a0a0a0"
        font.pixelSize: 9
        font.bold: true
      }
    }
    HoverHandler { id: overflowHover }
    Tip { objectName: "mini-floating-overflow-tip"; visible: overflowHover.hovered; label: overflowChip.titles.join("\n") }
  }
}
