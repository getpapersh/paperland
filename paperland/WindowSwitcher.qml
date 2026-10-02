pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import "shared" as Shared
import "native" as Native
import "Switcher.js" as Logic
import "shared/WorkspaceCatalog.js" as Catalog
import "shared/PreviewGeometry.js" as Geometry

Item {
  id: root
  required property var service
  signal starting()
  property bool opened: false
  property bool leftAlt: false
  property bool rightAlt: false
  property bool ignoreAltRelease: false
  property var recentIds: []
  property var ids: []
  // What the grid lists: the frozen MRU ids, or ranked matches ("ws:<id>" for workspaces) while a query is set.
  property var shown: []
  property string query: ""
  // Typing makes the gesture sticky: Alt release no longer commits.
  property bool typed: false
  property string searchMode: "fuzzy"
  // The surface maps (and owns the keyboard) as the gesture opens so the first
  // typed keys reach the query; painting waits so a quick tap does not flash.
  property bool presented: false
  // Whether the panels are mapped; the keyboard display's panel then owns the keyboard.
  property bool mapped: false
  // Card size preset (Switcher.js SIZES) and whether openings mirror onto every display.
  property string sizePreset: "large"
  property bool allDisplays: false
  signal sizeRequested(string preset)
  // allDisplays as read at opening; PaperMac applies the setting from the next Option+Tab.
  property bool mirrored: false
  // Desktop whose name editor is open inside the switcher (0: none).
  property int renameId: 0
  property bool renameClearing: false
  property string selected: ""
  property string pendingTarget: ""
  property var commands: []
  property var switchScreen: null
  readonly property bool active: opened || pendingTarget !== "" || commands.length > 0
  readonly property var windows: service.allWindows
  property var aspects: ({})
  property var pendingAspects: ({})
  // The keyboard display's panel; mirrors only repeat its state.
  readonly property var primaryPanel: panels.instances.find(function(panel) { return panel.primary; }) || panels.instances[0] || null
  readonly property var viewItem: primaryPanel ? primaryPanel.gridItem : null
  readonly property int columns: viewItem ? Math.max(1, Math.floor(viewItem.width / viewItem.cellWidth)) : 1

  function rememberFocus(): void {
    recentIds = Logic.recent(windows, recentIds, service.nativeFocus);
  }
  onWindowsChanged: syncWindows()
  function syncWindows(): void {
    rememberFocus();
    if (opened) {
      var index = shown.indexOf(selected);
      var remaining = ids.filter(function(id) { return !!root.windows[id]; });
      if (remaining.length !== ids.length) ids = remaining;
      shown = matches();
      if (shown.indexOf(selected) < 0) selected = shown[Math.min(Math.max(0, index), shown.length - 1)] || "";
      if (!hasTargets()) cancel();
    }
  }
  Connections {
    target: root.service
    function onCatalogChanged() {
      if (root.opened && root.query.trim()) root.refilter(true);
      root.checkPending();
    }
    function onNativeFocusChanged() {
      root.rememberFocus();
      root.checkPending();
    }
  }
  function hasTargets(): bool {
    return ids.length > 0 || Object.keys(service.catalog.entries).length > 0;
  }
  function pendingReached(): bool {
    if (pendingTarget.indexOf("ws:") !== 0) return service.nativeFocus === pendingTarget;
    // A workspace switch has landed once it is the focused workspace and native
    // focus is on one of its windows. Empty focus counts only for an empty
    // workspace: Hyprland can report no active client mid-switch.
    var id = Number(pendingTarget.slice(3)), entry = service.catalog.entries[id];
    if (!entry || !entry.focused) return false;
    if (!service.nativeFocus) return entry.windows.length === 0;
    var focused = windows[service.nativeFocus];
    return !!focused && focused.workspaceId === id;
  }
  function checkPending(): void {
    if (pendingTarget && !activation.running && pendingReached()) completePending();
  }
  function workspaceLabel(entry: var): string {
    return Catalog.customName(entry) || "Desktop " + entry.id;
  }
  function matches(): var {
    if (!query.trim()) return ids;
    var entries = service.catalog.entries;
    var candidates = ids.map(function(id) {
      var w = root.windows[id] || { app: "", title: "" };
      return { id: id, fields: [Native.Runtime.nameFor(w.app), w.title] };
    }).concat(Object.keys(entries).map(Number).sort(function(a, b) { return a - b; }).map(function(id) {
      return { id: "ws:" + id, fields: [root.workspaceLabel(entries[id])] };
    }));
    return Logic.search(query, searchMode, candidates);
  }
  function refilter(keep: bool): void {
    shown = matches();
    if (!keep || shown.indexOf(selected) < 0) selected = shown[0] || "";
  }
  function edit(next: string): void {
    if (!opened || next === query) return;
    typed = true;
    query = next;
    // A query edit follows the ranking; clearing it keeps a still-listed selection.
    refilter(!next.trim());
  }
  function dismiss(): void {
    if (query) edit("");
    else cancel();
  }
  function menuAnchor(): point {
    var grid = viewItem;
    var card = grid.itemAtIndex(root.shown.indexOf(root.selected));
    if (card && card.y + card.height > grid.contentY && card.y < grid.contentY + grid.height)
      return card.mapToItem(null, 0, Math.max(0, grid.contentY - card.y));
    return grid.mapToItem(null, grid.width / 2, grid.height / 2);
  }
  function cycle(delta: int): void {
    if (Native.Runtime.sendMenu.opened) return;
    if (pendingTarget) { commands = commands.concat([delta]); return; }
    if (!opened) {
      starting();
      rememberFocus();
      ids = recentIds.slice();
      if (!hasTargets()) return;
      shown = ids;
      query = "";
      typed = false;
      selected = ids[0] || "";
      switchScreen = Quickshell.screens.find(function(s) {
        return Hyprland.focusedMonitor && s.name === Hyprland.focusedMonitor.name;
      }) || Quickshell.screens[0];
      mirrored = allDisplays;
      renameId = 0;
      opened = true;
      aspects = {};
      pendingAspects = {};
      presented = false;
      mapped = true;
      present.restart();
      service.refresh();
    }
    selected = Logic.step(shown, selected, delta, columns);
  }
  function alt(code: int, down: bool): void {
    if (down && !Native.Runtime.sendMenu.opened) ignoreAltRelease = false;
    if (code === 64) leftAlt = down; else rightAlt = down;
    if (!leftAlt && !rightAlt && !ignoreAltRelease && !typed) commit();
  }
  function commit(): void {
    if (Native.Runtime.sendMenu.opened) return;
    if (pendingTarget) { commands = commands.concat([0]); return; }
    if (!opened) return;
    if (!selected) {
      // An untyped gesture with no windows has nothing to switch to; a search keeps waiting.
      if (!typed) cancel();
      return;
    }
    pendingTarget = selected;
    opened = false;
    typed = false;
    present.stop();
    presented = false;
    mapped = false;
    renameId = 0;
    activation.restart();
  }
  function choose(address: string): void {
    if (shown.indexOf(address) < 0) return;
    selected = address;
    commit();
  }
  function cancel(): void {
    commands = [];
    opened = false;
    typed = false;
    present.stop();
    presented = false;
    mapped = false;
    renameId = 0;
  }
  function suspendForMenu(): void {
    // Cancelling the release gesture must not hide the preview behind its menu.
    ignoreAltRelease = true;
    commands = [];
    activation.stop();
    focusWait.stop();
    pendingTarget = "";
  }
  function abort(): void {
    cancel();
    activation.stop();
    focusWait.stop();
    pendingTarget = "";
  }
  function completePending(): void {
    focusWait.stop();
    pendingTarget = "";
    drain();
  }
  function drain(): void {
    // Input received while layer focus is being released belongs to the next gesture.
    while (!pendingTarget && commands.length) {
      var command = commands[0];
      commands = commands.slice(1);
      if (command === 0) commit(); else cycle(command);
    }
  }
  function closeSelected(): void {
    if (opened) service.closeWindow(selected);
  }
  function activatePending(): void {
    var workspace = pendingTarget.indexOf("ws:") === 0;
    // A workspace match switches Desktop through native focus; no window is raised.
    if (workspace) service.activateWorkspace(Number(pendingTarget.slice(3)));
    else service.activate(pendingTarget);
    if ((!workspace && !windows[pendingTarget]) || pendingReached()) completePending();
    else focusWait.restart();
  }
  function pendingTimedOut(): void {
    // Only a workspace that never became focused is an error; a pinned window can keep focus.
    var entry = service.catalog.entries[Number(pendingTarget.slice(3))];
    if (pendingTarget.indexOf("ws:") === 0 ? !(entry && entry.focused) : service.nativeFocus !== pendingTarget)
      service.activationError = pendingTarget.indexOf("ws:") === 0
        ? "The selected Desktop could not be shown. It may have been removed."
        : "The selected window could not be focused. It may have closed.";
    completePending();
  }
  Timer { id: present; interval: 80; onTriggered: if (root.opened) root.presented = true }
  Timer {
    id: activation; interval: 40
    onTriggered: root.activatePending()
  }
  Timer {
    id: focusWait; interval: 400
    onTriggered: root.pendingTimedOut()
  }
  GlobalShortcut { appid: "paperland-switcher"; name: "next"; onPressed: root.cycle(1) }
  GlobalShortcut { appid: "paperland-switcher"; name: "previous"; onPressed: root.cycle(-1) }
  GlobalShortcut { appid: "paperland-switcher"; name: "64-1"; onPressed: root.alt(64, true); onReleased: root.alt(64, true) }
  GlobalShortcut { appid: "paperland-switcher"; name: "64-0"; onPressed: root.alt(64, false); onReleased: root.alt(64, false) }
  GlobalShortcut { appid: "paperland-switcher"; name: "108-1"; onPressed: root.alt(108, true); onReleased: root.alt(108, true) }
  GlobalShortcut { appid: "paperland-switcher"; name: "108-0"; onPressed: root.alt(108, false); onReleased: root.alt(108, false) }

  function imageSize(address: string, cardWidth: real): var {
    return Geometry.imageSize(aspects[address] || (windows[address] ? windows[address].aspect : 0),
      Math.max(280, Math.floor((cardWidth - 32) / 3) - 24), 220);
  }
  function rememberAspect(address: string, ratio: real): void {
    if (ratio <= 0 || ids.indexOf(address) < 0) return;
    pendingAspects[address] = ratio;
    Qt.callLater(publishAspects);
  }
  function publishAspects(): void {
    var next = Object.assign({}, aspects), changed = false;
    Object.keys(pendingAspects).forEach(function(id) {
      if (root.ids.indexOf(id) >= 0 && next[id] !== root.pendingAspects[id]) {
        next[id] = root.pendingAspects[id]; changed = true;
      }
    });
    pendingAspects = {};
    if (changed) aspects = next;
  }
  signal revealRequested()
  function reveal(): void {
    revealRequested();
  }
  function beginRename(id: int, clearing: bool): void {
    if (!opened || !service.catalog.entries[id]) return;
    typed = true;
    renameClearing = clearing;
    renameId = id;
  }
  function screensChanged(): void {
    // Only the opening display's panel takes input; if it disconnects, no surviving
    // panel could finish or dismiss the gesture, so cancel it.
    var screen = switchScreen;
    if (opened && !(screen && Quickshell.screens.some(function(s) { return s.name === screen.name; }))) cancel();
  }
  Connections {
    target: Quickshell
    function onScreensChanged() { root.screensChanged(); }
  }
  onShownChanged: Qt.callLater(reveal)
  onSelectedChanged: Qt.callLater(reveal)
  onAspectsChanged: Qt.callLater(reveal)

  // One panel per display: the opening display's panel takes the keyboard, the others mirror it when enabled.
  Variants {
    id: panels
    model: Quickshell.screens
    PanelWindow {
      id: popup
      required property var modelData
      readonly property bool primary: !!root.switchScreen && modelData.name === root.switchScreen.name
      readonly property Item gridItem: grid
      readonly property int columns: Math.max(1, Math.floor(grid.width / grid.cellWidth))
      visible: root.mapped && (primary || root.mirrored)
      screen: modelData
      anchors { top: true; bottom: true; left: true; right: true }
      exclusionMode: ExclusionMode.Ignore
      color: root.presented ? Theme.switcherScrim : "transparent"
      WlrLayershell.namespace: "paperland-switcher"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: visible && primary && !Native.Runtime.sendMenu.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
      onVisibleChanged: if (visible) { keyFocus.forceActiveFocus(); Qt.callLater(grid.revealSelected); }
      // Hyprland sends pointer input only to the layer holding exclusive keyboard focus, so mirrors are view-only.
      readonly property bool interactive: primary && !Native.Runtime.sendMenu.opened
      mask: Region { width: popup.interactive ? popup.width : 0; height: popup.interactive ? popup.height : 0 }
      MouseArea { anchors.fill: parent; onClicked: root.cancel() }
      Rectangle {
        id: surface
        readonly property var caps: Logic.cardSize(root.sizePreset, popup.width, popup.height)
        readonly property bool renaming: popup.primary && root.renameId > 0
        anchors.centerIn: parent
        width: caps.width
        height: caps.fill ? caps.height : Math.min(caps.height,
          Math.max(renaming ? 360 : 0, Math.ceil(root.shown.length / popup.columns) * grid.cellHeight + 96))
        radius: 14; color: Theme.switcherSurface; border.color: Theme.switcherSurfaceBorder
        // Opacity, not visibility: hidden items cannot hold the keyboard focus.
        opacity: root.presented ? 1 : 0
        MouseArea { anchors.fill: parent }
        FocusScope {
          id: keyFocus; anchors.fill: parent; focus: true
          Keys.onPressed: function(event) {
            // Plain letters type into the query, so vim keys need Ctrl as in PaperMac.
            var ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
            if (event.key === Qt.Key_Menu || (event.key === Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier))) {
              if (root.windows[root.selected]) Native.Runtime.sendMenu.openFor(root.selected, root.switchScreen, root.menuAnchor());
            }
            else if (event.key === Qt.Key_Escape) root.dismiss();
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.commit();
            else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Right || (ctrl && (event.key === Qt.Key_L || event.key === Qt.Key_N))) root.cycle(1);
            else if (event.key === Qt.Key_Backtab || event.key === Qt.Key_Left || (ctrl && (event.key === Qt.Key_H || event.key === Qt.Key_P))) root.cycle(-1);
            else if (event.key === Qt.Key_Down || (ctrl && event.key === Qt.Key_J)) root.cycle(root.columns);
            else if (event.key === Qt.Key_Up || (ctrl && event.key === Qt.Key_K)) root.cycle(-root.columns);
            else if (event.key === Qt.Key_Delete) root.closeSelected();
            else if (event.key === Qt.Key_Backspace) root.edit(root.query.slice(0, -1));
            else if (!ctrl && !(event.modifiers & Qt.MetaModifier) && Logic.printable(event.text)) root.edit(root.query + event.text);
            else return;
            event.accepted = true;
          }
          Item {
            id: header
            objectName: "switcher-search"
            x: 20; y: 8; width: parent.width - 40; height: 36
            Accessible.role: Accessible.EditableText
            Accessible.name: "Type to filter windows or Desktops"
            Accessible.description: root.query
            Item {
              anchors.verticalCenter: parent.verticalCenter
              width: 16; height: 16
              Rectangle { x: 1; y: 1; width: 9; height: 9; radius: 5; color: "transparent"; border.width: 1.5; border.color: Theme.switcherTextTertiary }
              Rectangle { x: 9.5; y: 9.5; width: 5.5; height: 1.5; radius: 0.75; rotation: 45; color: Theme.switcherTextTertiary }
            }
            Text {
              id: queryText
              x: 26; anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, status.x - x - 16)
              text: root.query || "Type to filter windows or Desktops…"
              textFormat: Text.PlainText; elide: Text.ElideLeft
              color: root.query ? Theme.switcherTextPrimary : Theme.switcherTextHint; font.pixelSize: 15
            }
            Rectangle {
              x: root.query ? queryText.x + queryText.width + 1 : queryText.x - 2
              anchors.verticalCenter: parent.verticalCenter
              width: 2; height: 18; color: Theme.switcherCardBorderSelected
            }
            Rectangle {
              id: status
              anchors { right: parent.right; verticalCenter: parent.verticalCenter }
              radius: height / 2; color: Theme.switcherKeycap; border.color: Theme.switcherCardBorder
              width: statusText.implicitWidth + 20; height: 24
              Text {
                id: statusText; objectName: "switcher-search-status"
                anchors.centerIn: parent; font.pixelSize: 12
                color: root.query.trim() && !root.shown.length ? Theme.switcherTextDanger : Theme.switcherTextTertiary
                text: surface.renaming ? "Renaming desktop · ↩ save · esc cancel"
                  : !root.query.trim() ? (root.shown.indexOf(root.selected) + 1) + " / " + root.shown.length
                  : !root.shown.length ? "No matches"
                  : root.shown.length === 1 ? "1 match · ↩" : root.shown.length + " matches · ⇥ ↩"
              }
            }
          }
          GridView {
            id: grid; objectName: "switcher-grid"
            x: 16; y: 52; width: parent.width - 32; height: parent.height - 96
            clip: true; cacheBuffer: 0
            function revealSelected(): void {
              var index = root.shown.indexOf(root.selected);
              if (index >= 0) positionViewAtIndex(index, cellHeight > height ? GridView.Beginning : GridView.Contain);
            }
            Connections { target: root; function onRevealRequested() { grid.revealSelected(); } }
            onWidthChanged: Qt.callLater(grid.revealSelected)
            onHeightChanged: Qt.callLater(grid.revealSelected)
            onCellWidthChanged: Qt.callLater(grid.revealSelected)
            onCellHeightChanged: Qt.callLater(grid.revealSelected)
            // Hidden mirrors build no cards.
            model: popup.primary || popup.visible ? root.shown : []
            cellWidth: root.shown.reduce(function(size, id) { return Math.max(size, root.imageSize(id, surface.width).width + 24); }, 300)
            cellHeight: root.shown.reduce(function(size, id) { return Math.max(size, root.imageSize(id, surface.width).height + 88); }, 250)
            contentWidth: Math.max(width, cellWidth)
            flickableDirection: Flickable.AutoFlickIfNeeded
            QQC.ScrollBar.vertical: QQC.ScrollBar {}
            QQC.ScrollBar.horizontal: QQC.ScrollBar {}
            delegate: QQC.ItemDelegate {
              id: tile
              required property string modelData
              required property int index
              readonly property var window: root.windows[modelData] || ({app: "", title: "", monitor: "", workspaceId: 0, workspaceName: ""})
              readonly property bool isWorkspace: modelData.indexOf("ws:") === 0
              readonly property var entry: isWorkspace ? root.service.catalog.entries[Number(modelData.slice(3))] || null : null
              readonly property var imageSize: root.imageSize(modelData, surface.width)
              objectName: "switcher-card-" + index
              width: grid.cellWidth - 8; height: grid.cellHeight - 8
              focusPolicy: Qt.NoFocus
              Accessible.name: entry ? Catalog.accessibleName(entry)
                : Native.Runtime.nameFor(window.app) + ", " + window.title + ", " + Logic.location(window).split(" · ").join(", ")
              onClicked: root.choose(modelData)
              TapHandler { acceptedButtons: Qt.RightButton; enabled: !tile.isWorkspace; onTapped: eventPoint => Native.Runtime.sendMenu.openFor(tile.modelData, popup.modelData, tile.mapToItem(null, eventPoint.position.x, eventPoint.position.y)) }
              background: Rectangle {
                radius: 10
                color: root.selected === tile.modelData ? Theme.switcherCardSelected : tile.hovered ? Theme.switcherCardHover : Theme.switcherCard
                border.width: root.selected === tile.modelData ? 2 : 1
                border.color: root.selected === tile.modelData ? Theme.switcherCardBorderSelected : Theme.switcherCardBorder
              }
              contentItem: Item {
                Shared.ThumbnailSlot {
                  id: image
                  objectName: "switcher-thumbnail-" + tile.index
                  x: 4; y: identity.height + 12
                  width: tile.imageSize.width; height: tile.imageSize.height
                  visible: !tile.isWorkspace
                  address: tile.isWorkspace ? "" : tile.modelData
                  thumbnailSource: Qt.resolvedUrl("native/WindowThumbnail.qml")
                  iconSource: Native.Runtime.iconFor(tile.window.app)
                  captureEnabled: root.presented && popup.visible
                  viewport: Qt.rect(grid.contentX - tile.x - tile.leftPadding - x,
                    grid.contentY - tile.y - tile.topPadding - y, grid.width, grid.height)
                  onAspectRatioChanged: root.rememberAspect(tile.modelData, aspectRatio)
                }
                Text {
                  visible: !!tile.entry
                  x: image.x; y: image.y; width: image.width; height: image.height
                  text: tile.entry ? root.workspaceLabel(tile.entry) : ""
                  textFormat: Text.PlainText; elide: Text.ElideRight
                  horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                  color: Theme.switcherTextSecondary; font.pixelSize: 22; font.bold: true
                }
                Column {
                  id: identity
                  objectName: "switcher-identity-" + tile.index
                  x: 4; y: 4; width: parent.width - 8; spacing: 2
                  Item {
                    width: parent.width; height: Math.max(nameText.implicitHeight, naming.visible ? naming.height : 0)
                    Text { id: nameText; width: parent.width - (naming.visible ? naming.width + 6 : 0); anchors.verticalCenter: parent.verticalCenter; text: tile.entry ? root.workspaceLabel(tile.entry) : Native.Runtime.nameFor(tile.window.app); textFormat: Text.PlainText; elide: Text.ElideRight; color: Theme.switcherTextPrimary; font.bold: true; font.pixelSize: 13 }
                    // PaperMac's Desktop header actions: rename, and clear when a custom name is set.
                    Row {
                      id: naming
                      visible: !!tile.entry
                      anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                      spacing: 2
                      Repeater {
                        model: !tile.entry ? [] : [{ key: "rename", glyph: "✎", help: "Rename " + root.workspaceLabel(tile.entry) }]
                          .concat(Catalog.customName(tile.entry) ? [{ key: "clear-name", glyph: "⌫", help: "Clear custom name" }] : [])
                        QQC.ToolButton {
                          id: action
                          required property var modelData
                          objectName: "switcher-" + modelData.key + "-" + tile.index
                          width: 22; height: 22; padding: 0
                          focusPolicy: Qt.NoFocus
                          text: modelData.glyph
                          Accessible.name: modelData.help
                          QQC.ToolTip.text: modelData.help
                          QQC.ToolTip.visible: hovered
                          QQC.ToolTip.delay: 300
                          contentItem: Text { text: action.text; color: action.hovered ? Theme.switcherTextPrimary : Theme.switcherTextTertiary; font.pixelSize: 13; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                          background: Rectangle { radius: 5; color: action.hovered ? Theme.switcherControlHover : "transparent"; border.color: action.hovered ? Theme.switcherCardBorderSelected : "transparent" }
                          onClicked: root.beginRename(tile.entry.id, action.modelData.key === "clear-name")
                        }
                      }
                    }
                  }
                  Text { width: parent.width; text: tile.entry ? (tile.entry.count === null ? "Desktop" : tile.entry.count + (tile.entry.count === 1 ? " window" : " windows")) : tile.window.title; textFormat: Text.PlainText; elide: Text.ElideRight; color: Theme.switcherTextSecondary; font.pixelSize: 12 }
                  Text { objectName: "switcher-location-" + tile.index; width: parent.width; text: tile.entry ? tile.entry.monitor + (tile.entry.active ? " · Current" : "") : Logic.location(tile.window); textFormat: Text.PlainText; elide: Text.ElideRight; color: Theme.switcherTextTertiary; font.pixelSize: 11 }
                }
              }
            }
          }
          // Hint footer: keycap chips on a subdued strip, echoing the card borders.
          Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 1 }
            height: 36
            radius: 13; topLeftRadius: 0; topRightRadius: 0
            clip: true
            color: Theme.switcherFooter
            Accessible.role: Accessible.StaticText
            Accessible.name: "Type to filter, Tab: next, Shift+Tab: previous, " + (root.typed ? "Enter" : "release Alt") + ": switch, Escape: " + (root.query ? "clear search" : "cancel") + ", Delete: close window"
            Rectangle { width: parent.width; height: 1; color: Theme.switcherCardBorder }
            Row {
              anchors { left: parent.left; leftMargin: 20; verticalCenter: parent.verticalCenter }
              spacing: 18
              Repeater {
                model: [
                  { cap: "Tab", label: "Next" },
                  { cap: "⇧ Tab", label: "Previous" },
                  { cap: root.typed ? "↩" : "Release Alt", label: "Switch" },
                  { cap: "Esc", label: root.query ? "Clear" : "Cancel" },
                  { cap: "Del", label: "Close window" }
                ]
                Row {
                  id: hint
                  required property var modelData
                  spacing: 5
                  Rectangle {
                    radius: 4; color: Theme.switcherKeycap; border.color: Theme.switcherCardBorder
                    width: cap.implicitWidth + 9; height: 17
                    Text { id: cap; anchors.centerIn: parent; text: hint.modelData.cap; color: Theme.switcherTextKeycap; font.pixelSize: 10; Accessible.ignored: true }
                  }
                  Text { anchors.verticalCenter: parent.verticalCenter; text: hint.modelData.label; color: Theme.switcherTextHint; font.pixelSize: 11; Accessible.ignored: true }
                }
              }
            }
            // PaperMac's size cycler: a click advances the preset; hovering lists them.
            Rectangle {
              id: sizeButton
              objectName: "switcher-size"
              readonly property bool open: sizeHover.hovered || tipHover.hovered || tipLinger.running
              anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
              width: 22; height: 22; radius: 11
              color: Theme.switcherKeycap; border.color: open ? Theme.switcherCardBorderSelected : Theme.switcherCardBorder
              Accessible.role: Accessible.Button
              Accessible.name: "Switcher size: " + Logic.SIZE_LABELS[root.sizePreset] + ". Activate for the next size"
              Accessible.onPressAction: root.sizeRequested(Logic.nextSize(root.sizePreset))
              Text { anchors.centerIn: parent; text: "⤢"; color: sizeButton.open ? Theme.switcherCardBorderSelected : Theme.switcherTextTertiary; font.pixelSize: 13; Accessible.ignored: true }
              HoverHandler { id: sizeHover; onHoveredChanged: if (!hovered) tipLinger.restart() }
              TapHandler { onTapped: root.sizeRequested(Logic.nextSize(root.sizePreset)) }
            }
          }
        }
        Timer { id: tipLinger; interval: 250 }
        Rectangle {
          id: sizeTip
          objectName: "switcher-size-panel"
          visible: sizeButton.open
          x: parent.width - width - 8; y: parent.height - 37 - height - 4
          width: 172; height: sizeRows.implicitHeight + 14
          radius: 10; color: Theme.switcherPopover; border.color: Theme.switcherCardBorder
          HoverHandler { id: tipHover; onHoveredChanged: if (!hovered) tipLinger.restart() }
          Column {
            id: sizeRows
            x: 5; y: 7; width: parent.width - 10; spacing: 3
            Text { leftPadding: 6; bottomPadding: 2; text: "SWITCHER SIZE"; color: Theme.switcherTextHint; font.pixelSize: 9; font.bold: true; font.letterSpacing: 0.7 }
            Repeater {
              model: Logic.SIZES
              Rectangle {
                id: sizeRow
                required property string modelData
                readonly property bool active: root.sizePreset === modelData
                objectName: "switcher-size-" + modelData
                width: parent.width; height: 22; radius: 6
                color: active ? Theme.switcherPopoverRowSelected : rowHover.hovered ? Theme.switcherPopoverRowHover : "transparent"
                Accessible.role: Accessible.RadioButton
                Accessible.name: Logic.SIZE_LABELS[modelData] + ", " + Logic.SIZE_HINTS[modelData]
                Accessible.checked: active
                Accessible.onPressAction: root.sizeRequested(modelData)
                HoverHandler { id: rowHover }
                TapHandler { onTapped: root.sizeRequested(sizeRow.modelData) }
                Text { x: 6; anchors.verticalCenter: parent.verticalCenter; text: sizeRow.active ? "◉" : "○"; color: sizeRow.active ? Theme.switcherCardBorderSelected : Theme.switcherTextTertiary; font.pixelSize: 10; Accessible.ignored: true }
                Text { x: 22; anchors.verticalCenter: parent.verticalCenter; text: Logic.SIZE_LABELS[sizeRow.modelData]; color: sizeRow.active ? Theme.switcherTextPrimary : Theme.switcherTextTertiary; font.pixelSize: 11; font.bold: sizeRow.active; Accessible.ignored: true }
                Text { anchors { right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter } text: Logic.SIZE_HINTS[sizeRow.modelData]; color: Theme.switcherTextTertiary; font.pixelSize: 9; Accessible.ignored: true }
              }
            }
          }
        }
        // Paperland's workspace name editor and writer, shown in place of the grid on the keyboard display.
        Rectangle {
          objectName: "switcher-rename"
          visible: surface.renaming
          x: 1; y: 52; width: parent.width - 2; height: parent.height - 52 - 37
          color: surface.color
          MouseArea { anchors.fill: parent }
          onVisibleChanged: if (visible) {
            var entry = root.service.catalog.entries[root.renameId];
            editor.begin(root.renameId, entry ? entry.name : String(root.renameId), root.renameClearing);
          }
          Shared.WorkspaceEditor {
            id: editor
            anchors.fill: parent; anchors.margins: 16
            client: Native.Runtime.names
            onCancelled: { root.renameId = 0; keyFocus.forceActiveFocus(); }
          }
        }
      }
    }
  }
}
