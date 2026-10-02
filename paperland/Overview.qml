pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import "Layout.js" as CanvasLayout
import "MiniLayout.js" as MiniLayout
import "native" as Native

Item {
  id: root
  property var service: null
  property bool suppressed: false
  property bool startupHidden: false
  property bool opened: false
  property int peekSeconds: 3
  property bool peekEnabled: true
  // Pauses Peek's hide timer, like hovering the strip.
  property bool coachHold: false
  property string opacityMode: "background"
  property int backgroundOpacity: 96
  property int entireOpacity: 100
  signal peekSecondsRequested(int seconds)
  signal peekRequested(bool value)
  signal settingsRequested()
  signal welcomeRequested()
  signal showRequested()
  signal hideRequested()
  property var displayVisibility: ({})
  // Count displays with a visible strip, not rows: a following display has
  // both its desktop and the scratchpad row active at once. A display whose
  // remembered visibility is revealed but that has no displayed row (it sits
  // on a non-scrolling workspace) draws nothing and must not be counted, or
  // the minimap toggle hides into nothing.
  readonly property int visibleMinimaps: opened || suppressed || !service ? 0
    : CanvasLayout.countVisibleDisplays(root.displayVisibility, function(monitor) {
        return root.service.rowForScreen(monitor) !== null;
      })
  function reportVisibility(monitor, revealed) {
    if (!!displayVisibility[monitor] === revealed) return;
    displayVisibility = Object.assign({}, displayVisibility, { [monitor]: revealed });
  }
  function showMinimap() { workspaceDialog.close(); opened = false; showRequested(); }
  function hideMinimap() { workspaceDialog.close(); opened = false; hideRequested(); }
  function toggleMinimap() { if (opened) close(); else if (visibleMinimaps) hideMinimap(); else showMinimap(); }
  function activateFromMinimap(address) { if (service) service.activate(address); }
  readonly property var overviewItem: board
  readonly property bool workspaceActionsOpened: workspaceDialog.opened
  readonly property bool searchFocused: board.searchFocused
  property var overviewScreen: null
  // Docked window-list preference; shell binds this to the saved setting.
  property bool windowListEnabled: true
  property int density: 0
  signal windowListToggleRequested(bool value)
  signal densityChangeRequested(int value)
  property alias query: board.query
  property var previewIds: []
  readonly property var orderedPreviewIds: service ? CanvasLayout.overviewOrder(service.rows, service.rowIds, scopeMonitor) : []
  onOrderedPreviewIdsChanged: {
    if (JSON.stringify(previewIds) !== JSON.stringify(orderedPreviewIds)) previewIds = orderedPreviewIds;
  }
  property alias selectedAddress: board.selectedAddress
  readonly property var matchIds: board.matchIds
  property alias scope: board.scope
  property string scopeMonitor: ""
  property int scopeWorkspace: -1
  function open(): void {
    if (Native.Runtime.sendMenu.opened) return;
    workspaceDialog.close();
    var monitor = Hyprland.focusedMonitor;
    overviewScreen = Quickshell.screens.find(function(s) { return monitor && s.name === monitor.name; }) || Quickshell.screens[0];
    // Freeze the opening context; the exclusive layer may clear native focus.
    scopeMonitor = monitor ? monitor.name : (overviewScreen ? overviewScreen.name : "");
    var snapshot = monitor ? monitor.lastIpcObject : null;
    scopeWorkspace = snapshot && snapshot.activeWorkspace ? snapshot.activeWorkspace.id : -1;
    scope = "all";
    opened = true;
    if (service) service.refresh();
    Qt.callLater(board.resetSearch);
  }
  function pauseActivation(): void { activation.stop(); workspaceDialog.pauseActivation(); }
  function close(): void { activation.stop(); workspaceDialog.close(); opened = false; }
  function dismiss() { close(); }
  function activate(address) {
    if (!address) return;
    activation.address = address;
    dismiss();
    // Release layer keyboard focus before focusing a real client.
    activation.restart();
  }
  function selectNext(direction: int): void { board.selectNext(direction); }
  onOpenedChanged: updatePolling()
  onVisibleMinimapsChanged: updatePolling()
  onPeekEnabledChanged: updatePolling()
  onServiceChanged: updatePolling()
  onWorkspaceActionsOpenedChanged: {
    updatePolling();
    // Reclaim keyboard ownership when the popover closes over a live overview.
    if (!workspaceActionsOpened && opened) Qt.callLater(function() { if (root.opened) board.forceActiveFocus(); });
  }
  // Viewport moves have no focus event; keep geometry fresh while Peek waits.
  function updatePolling(): void { if (service) service.expanded = opened || workspaceActionsOpened || visibleMinimaps > 0 || peekEnabled; }
  Timer {
    id: activation
    property string address: ""
    interval: 40
    onTriggered: if (root.service) root.service.activate(address);
  }

  Variants {
    model: Quickshell.screens
    PanelWindow {
      id: compact
      required property var modelData
      readonly property var row: root.service ? root.service.rowForScreen(modelData.name) : null
      property string navigationFocus: ""
      function updateNavigationFocus(): void {
        var address = root.service ? root.service.nativeFocus : "";
        if (compact.row && compact.row.windows.some(function(window) { return window.address === address; }))
          navigationFocus = address;
      }
      onRowChanged: updateNavigationFocus()
      Connections {
        target: root.service
        function onNativeFocusChanged() { compact.updateNavigationFocus(); }
      }
      // Scrolling moves windows rather than the viewport, so a window's canvas
      // position is what makes a pan observable. Following this row's most
      // recently focused window keeps focus changes on another display out of
      // this display's navigation, and still tracks panning with no focus here.
      readonly property var navigationState: {
        var snapshot = compact.monitorSnapshot;
        var workspace = snapshot && snapshot.activeWorkspace ? String(snapshot.activeWorkspace.id) : "";
        var row = compact.row;
        if (!workspace || !row) return { token: workspace, suppress: false };
        // Focus events precede the polled history; remember this display's
        // latest client so rapid navigation and remote focus cannot erase it.
        var recent = row.windows.find(function(window) { return window.address === compact.navigationFocus; }) || null;
        if (!recent) for (var i = 0; i < row.windows.length; i++)
          if (!recent || row.windows[i].focusOrder < recent.focusOrder) recent = row.windows[i];
        return {
          token: workspace + "|" + row.windows.length + "|" + row.vertical + "|" + row.fullscreen + "|"
            + (recent ? recent.address + "@" + Math.round(recent.rect.x) + "," + Math.round(recent.rect.y) : ""),
          suppress: !!row.fullscreen
        };
      }
      readonly property var monitorSnapshot: {
        var monitor = Hyprland.monitors.values.find(function(m) { return m.name === compact.modelData.name; });
        return monitor ? monitor.lastIpcObject : null;
      }
      function publishCardBoxes(): void {
        if (mini.hitMonitorId < 0) return;
        var boxes = mini.enabled ? mini.cardHitBoxes : [];
        var data = [mini.hitMonitorId, boxes.length];
        boxes.forEach(function(box) { data = data.concat(box); });
        Hyprland.dispatch('function() if hl.plugin and hl.plugin.paperland then hl.plugin.paperland.set_cards("'
          + data.join(" ") + '") end end');
      }
      Timer { id: cardBoxSync; interval: 0; onTriggered: compact.publishCardBoxes() }
      screen: modelData
      visible: !lifecycle.suspended && (lifecycle.revealed || mini.opacity > 0)
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "paperland-minimap"
      WlrLayershell.layer: WlrLayer.Overlay
      // Exclusive only while the scrubber is engaged; see MiniStrip.scrubEngaged.
      // The strip must not hold keyboard focus the rest of the time.
      WlrLayershell.keyboardFocus: mini.scrubEngaged ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
      // Remove input immediately when fading starts; an invisible layer must
      // never cover the application beneath the strip.
      // The floating count tab sits above the strip; an open floating list takes
      // the whole surface so a click anywhere else dismisses it.
      mask: Region {
        x: mini.floatListOpen ? 0 : mini.x
        y: mini.floatListOpen ? 0 : mini.y
        width: !lifecycle.revealed ? 0 : mini.floatListOpen ? compact.width : mini.width
        height: !lifecycle.revealed ? 0 : mini.floatListOpen ? compact.height : mini.height
        Region {
          x: mini.x + mini.floatTabRect.x; y: mini.y + mini.floatTabRect.y
          width: lifecycle.revealed ? mini.floatTabRect.width : 0
          height: lifecycle.revealed ? mini.floatTabRect.height : 0
        }
      }
      MinimapVisibility {
        id: lifecycle
        initiallyHidden: root.startupHidden
        pinned: !!root.service && root.service.pinned
        // The workspace action popover keeps its source strip in view; its
        // centered windows and rename panels still suspend the strips.
        held: mini.interacting || Native.Runtime.sendMenu.opened || workspaceDialog.mode === "menu" || root.coachHold
        suspended: root.suppressed || root.opened || (workspaceDialog.opened && workspaceDialog.mode !== "menu") || compact.row === null
        // Track native navigation even while this display uses a non-scrolling
        // workspace, so returning to the previous scrolling workspace reveals it.
        navigation: compact.navigationState
        peek: root.peekEnabled
        delayMs: root.peekSeconds * 1000
        onRevealedChanged: root.reportVisibility(compact.modelData.name, revealed)
        Component.onCompleted: root.reportVisibility(compact.modelData.name, revealed)
        Component.onDestruction: root.reportVisibility(compact.modelData.name, false)
      }
      Connections {
        target: root
        function onShowRequested() { lifecycle.show(); }
        function onHideRequested() { lifecycle.hide(); }
      }
      MiniStrip {
        id: mini
        onCardHitBoxesChanged: cardBoxSync.restart()
        onEnabledChanged: cardBoxSync.restart()
        Component.onCompleted: cardBoxSync.restart()
        opacity: lifecycle.revealed ? (root.opacityMode === "entire" ? root.entireOpacity / 100 : 1) : 0
        // Suspension (overview, switcher, workspace editor) must also close the
        // floating list, which would otherwise return open and swallow a click.
        enabled: lifecycle.revealed && !lifecycle.suspended
        Behavior on opacity { NumberAnimation { duration: 180 } }
        width: row && row.vertical ? Math.min(150, Math.max(112, compact.screen.width * 0.085)) : Math.min(1000, Math.max(360, compact.screen.width * 0.55), compact.screen.width - 24)
        height: MiniLayout.stripHeight(collapsed, vertical, implicitHeight, compact.screen.height)
          + (remoteOverflow ? 22 : 0)
        x: vertical ? parent.width - width - 18 : (parent.width - width) / 2
        y: vertical ? (parent.height - height) / 2 : parent.height - height - 18
        thumbnailSource: Qt.resolvedUrl("native/WindowThumbnail.qml")
        captureEnabled: compact.visible
        row: compact.row
        badgeAddresses: root.service ? root.service.stripBadgeAddresses : []
        hitMonitorId: compact.monitorSnapshot ? compact.monitorSnapshot.id : -1
        hitMonitorX: compact.monitorSnapshot ? compact.monitorSnapshot.x : 0
        hitMonitorY: compact.monitorSnapshot ? compact.monitorSnapshot.y : 0
        workspaces: root.service ? root.service.workspacesFor(compact.modelData.name) : []
        destinations: root.service ? root.service.destinations : []
        remoteWorkspaces: root.service ? root.service.destinations.filter(function(entry) {
          return entry.kind === "existing" && entry.id > 0 && entry.monitor !== compact.modelData.name;
        }) : []
        scratchpad: root.service ? root.service.scratchpadForMonitor(compact.modelData.name) : null
        shortcutBinding: root.service ? root.service.scratchpadBinding : null
        scratchpadOpen: scratchpad ? scratchpad.active : false
        focusedAddress: root.service ? root.service.focusedAddress : ""
        pinned: root.service && root.service.pinned
        peek: root.peekEnabled
        backgroundOpacity: root.opacityMode === "background" ? root.backgroundOpacity : 96
        panEnabled: compact.row && root.service.canPan(compact.row.id)
        iconFor: Native.Runtime.iconFor
        nameFor: Native.Runtime.nameFor
        onActivated: function(address) { root.activateFromMinimap(address); }
        onSelectionDropRequested: function(addresses, workspace, reorder, ids, offered) {
          if (root.service && compact.row) root.service.moveGroup(addresses, workspace, compact.row.id, reorder, ids, offered);
        }
        onWindowMenuRequested: function(address, position) { Native.Runtime.sendMenu.openForSelection(address, compact.modelData, position, mini); }
        onWorkspaceMenuRequested: function(workspace, position) { workspaceDialog.openFor(workspace, compact.modelData, position, position.y); }
        onScratchpadMenuRequested: function(position) { workspaceDialog.openScratchpadFor(compact.modelData, position, position.y); }
        onNewWorkspaceRequested: root.service.openNewWorkspace(compact.modelData.name)
        onWorkspaceActivated: function(workspace) { root.service.activateWorkspace(workspace); }
        onScratchpadToggleRequested: root.service.toggleScratchpad(compact.modelData.name)
        onScrubbed: function(delta) { root.service.pan(compact.row.id, delta); }
        onScrubStarted: if (compact.row) root.service.beginPan(compact.row.id);
        onScrubLanded: root.service.endPan()
        onScrubCancelled: root.service.cancelPan()
        // Scoped to this display's workspace: an unscoped binding would preview
        // the landing on every strip while one of them is being dragged.
        pendingLanding: root.service && compact.row && root.service.pendingWorkspace === compact.row.id
          ? root.service.panCandidate : ""
        onPinToggled: root.service.setPinned(!root.service.pinned)
        onPeekToggled: root.peekRequested(!root.peekEnabled)
        onHideRequested: lifecycle.hide()
        onOverviewRequested: root.open()
        onSettingsRequested: root.settingsRequested()
      }
    }
  }

  PanelWindow {
    id: overview
    screen: root.overviewScreen
    visible: root.opened && !root.suppressed
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    // Keep the overview rendered behind the workspace popover and the send
    // menu, but hand them its input region and keyboard ownership.
    readonly property bool deferring: Native.Runtime.sendMenu.opened || workspaceDialog.opened
    mask: Region { width: overview.deferring ? 0 : overview.width; height: overview.deferring ? 0 : overview.height }
    WlrLayershell.namespace: "paperland-overview"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened && !root.suppressed && !overview.deferring ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    Rectangle {
      anchors.fill: parent
      color: Theme.scrim
      MouseArea { anchors.fill: parent; onClicked: root.dismiss(); }
      OverviewBoard {
        id: board
        anchors.fill: parent
        listEnabled: root.windowListEnabled
        density: root.density
        onListToggleRequested: function(value) { root.windowListToggleRequested(value); }
        onDensityChangeRequested: function(value) { root.densityChangeRequested(value); }
        rows: root.service ? root.service.rows : ({})
        rowIds: root.previewIds
        windows: root.service ? root.service.windows : ({})
        catalog: root.service ? root.service.catalog : null
        scopeMonitor: root.scopeMonitor
        scopeWorkspace: root.scopeWorkspace
        focusedAddress: root.service ? root.service.focusedAddress : ""
        badgeAddresses: root.service ? root.service.stripBadgeAddresses : []
        captureEnabled: overview.visible && !root.suppressed
        iconFor: Native.Runtime.iconFor
        nameFor: Native.Runtime.nameFor
        canPanRow: function(row) { return root.service ? root.service.canPan(row.id) : false; }
        onActivated: function(address) { root.activate(address); }
        onDismissed: root.dismiss()
        onWindowMenuRequested: function(address, position) { Native.Runtime.sendMenu.openFor(address, root.overviewScreen, position); }
        onPanned: function(workspaceId, delta) { if (root.service) root.service.pan(workspaceId, delta); }
        onWorkspaceActionsRequested: function(workspaceId, position, aboveY) {
          workspaceDialog.openFor(workspaceId, root.overviewScreen, position, aboveY);
        }
      }
    }
  }
  WorkspaceDialog {
    id: workspaceDialog
    service: root.service
    peekSeconds: root.peekSeconds
    onActivating: root.close()
    onPeekSecondsRequested: function(seconds) { root.peekSecondsRequested(seconds); }
    onWelcomeRequested: root.welcomeRequested()
  }
}
