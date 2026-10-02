pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC
import "Layout.js" as CanvasLayout
import "shared/WorkspaceCatalog.js" as WorkspaceCatalog

// PAPLA-30 overview board: a display-filling board with one vertical lane list.
// No Quickshell imports, so component
// tests and offscreen renders can instantiate it with fixture rows.
Item {
  id: board

  // Everything lives inside the content box so
  // no child touches the board border or crosses its rounded corners.
  readonly property int boardPadding: 16
  readonly property int densityFull: 0
  readonly property int densityIcons: 1
  readonly property int densityTimeline: 2
  readonly property int stripCanvasMaxHeight: density === densityFull ? 2147483647 : density === densityIcons ? 240 : 88
  readonly property int stripCanvasMinHeight: density === densityTimeline ? 56 : 160
  readonly property int stripPaddingTop: 0
  readonly property int stripPaddingBottom: 0
  readonly property int stripPaddingX: 0
  readonly property int stripLabelHeight: 32
  readonly property int stripHeaderCanvasGap: 6
  readonly property int stripGap: 10
  readonly property int displayDividerHeight: 28
  // Per-lane share reserves every lane's header, divider, and inter-lane gap.
  readonly property int stripChrome: stripPaddingTop + stripLabelHeight + stripHeaderCanvasGap + stripPaddingBottom
  readonly property int sidebarHeaderHeight: 136
  readonly property int sidebarWidth: 360
  readonly property int sidebarGap: 16

  readonly property real boardX: 12
  readonly property real boardY: 12
  readonly property real boardWidth: width - boardX * 2
  readonly property real boardHeight: height - boardY * 2

  property var rows: ({})
  property var rowIds: []
  property var windows: ({})
  property var catalog: null
  property string query: ""
  property string scopeMonitor: ""
  property int scopeWorkspace: -1
  property string focusedAddress: ""
  property var badgeAddresses: []
  property bool captureEnabled: false
  // Docked-list preference; Overview binds it to the saved setting.
  property bool listEnabled: true
  property int density: densityFull
  readonly property string densityLabel: density === densityIcons ? "Icons" : density === densityTimeline ? "Timeline" : "Full"
  property var iconFor: function(app) { return ""; }
  property var nameFor: function(app) { return CanvasLayout.appName(app); }
  // Row panning eligibility needs the service's focus checks; injected so the
  // board itself stays service-free.
  property var canPanRow: function(row) { return false; }

  signal activated(string address)
  signal dismissed()
  signal windowMenuRequested(string address, point position)
  signal panned(int workspaceId, real delta)
  signal workspaceActionsRequested(int workspaceId, point position, real aboveY)
  signal listToggleRequested(bool value)
  signal densityChangeRequested(int value)

  property bool searchListDismissed: false
  property string _previousQuery: ""
  onQueryChanged: {
    var wasEmpty = _previousQuery === "";
    var isEmpty = query === "";
    if (wasEmpty !== isEmpty)
      searchListDismissed = false;
    _previousQuery = query;
  }

  // The docked list honors the off preference, but a query reveals it for
  // the search's duration: searching is where the list earns its place.
  readonly property bool sidebarOpen: listEnabled || (query !== "" && !searchListDismissed)
  // Tests and harnesses drive the field directly; the query follows the text.
  property alias searchText: search.text
  property alias selectedAddress: sidebar.selectedAddress
  readonly property var matchIds: sidebar.matchIds
  property alias scope: sidebar.scope
  readonly property bool searchFocused: search.activeFocus
  // Row records paired with their monitor so ListView sections can group them.
  readonly property var stripModel: rowIds.filter(function(id) { return !!rows[id]; })
    .map(function(id) { return { id: id, monitor: rows[id].monitor }; })
  readonly property int monitorCount: {
    var monitors = [];
    stripModel.forEach(function(item) { if (monitors.indexOf(item.monitor) < 0) monitors.push(item.monitor); });
    return monitors.length;
  }
  readonly property int displayDividerCount: monitorCount > 1 ? monitorCount : 0
  readonly property real canvasHeightShare: stripModel.length > 0
    ? (stripList.height - stripModel.length * stripChrome
      - Math.max(0, stripModel.length - 1) * stripGap
      - displayDividerCount * (displayDividerHeight + stripHeaderCanvasGap)) / stripModel.length
    : stripCanvasMinHeight

  function focusSearch(): void { search.forceActiveFocus(); }
  function resetSearch(): void {
    search.text = "";
    stripList.contentY = 0;
    sidebar.resetSelection();
    searchListDismissed = false;
    Qt.callLater(board.focusSearch);
  }
  function selectNext(direction: int): void { sidebar.selectNext(direction); }

  Keys.onEscapePressed: {
    if (board.query !== "") {
      search.text = "";
      board.query = "";
      return;
    }
    board.dismissed();
  }
  Keys.onDownPressed: board.selectNext(1)
  Keys.onUpPressed: board.selectNext(-1)
  Keys.onReturnPressed: if (board.selectedAddress) board.activated(board.selectedAddress)
  Keys.onEnterPressed: if (board.selectedAddress) board.activated(board.selectedAddress)
  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Menu || (event.key === Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier))) {
      board.windowMenuRequested(board.selectedAddress, sidebar.menuAnchor());
      event.accepted = true;
    }
  }

  component Keycap: Rectangle {
    property string label: ""
    implicitWidth: keyLabel.implicitWidth + 10
    implicitHeight: 20
    radius: 4
    color: Theme.surfaceControl
    border.color: Theme.borderStrong
    Text {
      id: keyLabel
      anchors.centerIn: parent
      text: parent.label
      textFormat: Text.PlainText
      color: Theme.textSecondary
      font { family: Theme.fontFamily; pixelSize: 11; weight: Font.DemiBold }
    }
  }

  component DensityGlyph: Item {
    id: glyph
    required property int mode
    property color ink: Theme.textSecondary
    readonly property int size: 16
    implicitWidth: size
    implicitHeight: size
    Rectangle {
      visible: glyph.mode === board.densityFull
      x: 1; y: 1; width: 14; height: 10; radius: 1
      color: "transparent"; border.width: 1.5; border.color: glyph.ink
      Rectangle { anchors.horizontalCenter: parent.horizontalCenter; y: 9; width: 2; height: 3; color: glyph.ink }
      Rectangle { anchors.horizontalCenter: parent.horizontalCenter; y: 12; width: 8; height: 1.5; color: glyph.ink }
    }
    Repeater {
      model: glyph.mode === board.densityIcons ? 4 : 0
      Rectangle {
        required property int index
        width: 5; height: 5; radius: 1
        x: 1 + (index % 2) * 8; y: 1 + Math.floor(index / 2) * 8
        color: glyph.ink
      }
    }
    Item {
      objectName: "density-timeline-icon"
      visible: glyph.mode === board.densityTimeline
      width: 16; height: 10
      anchors.centerIn: parent
      Rectangle { objectName: "density-timeline-clip-0"; x: 0.5; y: 1; width: 9; height: 3; radius: 1; color: glyph.ink }
      Rectangle { objectName: "density-timeline-clip-1"; x: 10.5; y: 1; width: 5; height: 3; radius: 1; color: glyph.ink }
      Rectangle { objectName: "density-timeline-clip-2"; x: 0.5; y: 6; width: 4; height: 3; radius: 1; color: glyph.ink }
      Rectangle { objectName: "density-timeline-clip-3"; x: 5.5; y: 6; width: 10; height: 3; radius: 1; color: glyph.ink }
    }
  }

  component SearchGlyph: Item {
    implicitWidth: 16
    implicitHeight: 16
    Rectangle { x: 1; y: 1; width: 9; height: 9; radius: 5; color: "transparent"; border.width: 1.5; border.color: Theme.textSecondary }
    Rectangle { x: 9.5; y: 9.5; width: 5.5; height: 1.5; radius: 0.75; rotation: 45; color: Theme.textSecondary }
  }

  component SidebarGlyph: Item {
    id: sidebarGlyph
    property bool open: false
    implicitWidth: 16
    implicitHeight: 16
    Rectangle {
      x: 1; y: 1; width: 14; height: 14; radius: 1
      color: "transparent"; border.width: 1.5; border.color: Theme.textSecondary
      Rectangle { x: 8; y: 0; width: 1.5; height: 14; color: Theme.textSecondary }
      Rectangle { x: 9.5; y: 1.5; width: 4; height: 11; radius: 0.5; color: sidebarGlyph.open ? Theme.accentSoft : "transparent" }
    }
  }

  Rectangle {
    objectName: "overview-panel-background"
    x: board.boardX
    y: board.boardY
    width: board.boardWidth
    height: board.boardHeight
    radius: 14
    color: Theme.background
    border.color: Theme.borderStrong
  }

  // Clicks inside the board keep typing routed to search; margin clicks still
  // fall through to the scrim so an outside click dismisses.
  MouseArea {
    x: board.boardX
    y: board.boardY
    width: board.boardWidth
    height: board.boardHeight
    onClicked: board.focusSearch()
  }

  Item {
    id: content
    objectName: "overview-content"
    x: board.boardX + board.boardPadding
    y: board.boardY + board.boardPadding
    width: board.boardWidth - board.boardPadding * 2
    height: board.boardHeight - board.boardPadding * 2
    // The docked panel animates in from outside its right edge; clipping
    // keeps that animation inside the board. Its field remains focusable while
    // transparent so typing can reveal the list without another focus change.
    clip: true

    ListView {
      id: stripList
      objectName: "overview-workspaces"
      x: 0
      y: 0
      width: content.width - (board.sidebarOpen ? board.sidebarWidth + board.sidebarGap : 48 + 12)
      height: content.height
      clip: true
      model: board.stripModel
      spacing: board.stripGap
      boundsBehavior: Flickable.StopAtBounds
      Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
      flickableDirection: Flickable.VerticalFlick
      snapMode: ListView.SnapToItem
      QQC.ScrollBar.vertical: QQC.ScrollBar { }
      delegate: Rectangle {
        id: strip
        required property var modelData
        required property int index
        readonly property int workspaceId: modelData.id
        readonly property var row: board.rows[workspaceId] || null
        readonly property var entry: {
          if (!strip.row) return null;
          return board.catalog && board.catalog.entries[strip.row.id]
            ? board.catalog.entries[strip.row.id]
            : { id: strip.row.id, name: strip.row.name, monitor: strip.row.monitor,
                active: strip.row.active, count: null, windows: strip.row.windows };
        }
        readonly property bool special: WorkspaceCatalog.isSpecial(strip.entry)
        readonly property string title: WorkspaceCatalog.customName(strip.entry)
        readonly property bool showsDisplayDivider: board.displayDividerCount > 0
          && (strip.index === 0 || board.stripModel[strip.index - 1].monitor !== strip.modelData.monitor)
        readonly property real canvasHeight: Math.max(board.stripCanvasMinHeight,
          Math.min(board.stripCanvasMaxHeight, board.canvasHeightShare))
        readonly property int trackExtra: 0
        readonly property bool zoomVisible: stripHover.hovered || stripCanvas.zoom !== 1
        readonly property bool headerControlsFit: !board.sidebarOpen || strip.width >= 600

        objectName: "overview-strip-" + workspaceId
        width: ListView.view.width
        height: board.stripPaddingTop + (showsDisplayDivider ? board.displayDividerHeight + board.stripHeaderCanvasGap : 0)
          + board.stripLabelHeight + board.stripHeaderCanvasGap + canvasHeight + board.stripPaddingBottom
        radius: 0
        color: "transparent"
        HoverHandler { id: stripHover }
        ColumnLayout {
          anchors.fill: parent
          anchors.leftMargin: board.stripPaddingX
          anchors.rightMargin: board.stripPaddingX
          anchors.topMargin: board.stripPaddingTop
          anchors.bottomMargin: board.stripPaddingBottom
          spacing: board.stripHeaderCanvasGap
          Rectangle {
            objectName: strip.showsDisplayDivider ? "overview-display-divider-" + strip.modelData.monitor : ""
            visible: strip.showsDisplayDivider
            Layout.fillWidth: true
            Layout.preferredHeight: board.displayDividerHeight
            color: "transparent"
            RowLayout {
              anchors.fill: parent
              spacing: 10
              Text {
                text: strip.modelData.monitor
                textFormat: Text.PlainText
                color: Theme.textSecondary
                font { family: Theme.fontFamily; pixelSize: 12; weight: Font.DemiBold; capitalization: Font.AllUppercase; letterSpacing: 0.6 }
              }
              Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.alpha(Theme.foreground, 0.12) }
            }
          }
          RowLayout {
            objectName: "overview-strip-header-" + strip.workspaceId
            Layout.fillWidth: true
            Layout.preferredHeight: board.stripLabelHeight
            spacing: 8
            Rectangle {
              visible: !strip.special
              Layout.preferredWidth: 22
              Layout.preferredHeight: 22
              Layout.alignment: Qt.AlignVCenter
              radius: 6
              color: Theme.surfaceControl
              Text {
                anchors.centerIn: parent
                text: strip.entry && !strip.special ? String(strip.entry.id) : ""
                textFormat: Text.PlainText
                color: Theme.textPrimary
                font { family: Theme.fontFamily; pixelSize: 12; weight: Font.DemiBold }
              }
            }
            Text {
              objectName: "overview-strip-name"
              text: strip.title
              visible: strip.title !== ""
              textFormat: Text.PlainText
              elide: Text.ElideRight
              Layout.preferredWidth: implicitWidth
              Layout.maximumWidth: Math.max(120, strip.width - 420)
              Layout.alignment: Qt.AlignVCenter
              color: Theme.textPrimary
              font { family: Theme.fontFamily; pixelSize: 16; weight: Font.DemiBold }
            }
            Rectangle {
              visible: strip.row && strip.row.active
              Layout.alignment: Qt.AlignVCenter
              radius: 9
              implicitHeight: 18
              implicitWidth: chipText.implicitWidth + 16
              color: Theme.accentSoft
              Text {
                id: chipText
                anchors.centerIn: parent
                text: "Current"
                textFormat: Text.PlainText
                color: Theme.accent
                font { family: Theme.fontFamily; pixelSize: 11; weight: Font.DemiBold }
              }
            }
            Text {
              objectName: "overview-strip-meta"
              text: {
                var count = strip.entry && strip.entry.count !== null && strip.entry.count !== undefined
                  ? strip.entry.count : (strip.row ? strip.row.windows.length : 0);
                return count + (count === 1 ? " window" : " windows");
              }
              textFormat: Text.PlainText
              Layout.alignment: Qt.AlignVCenter
              color: Theme.textTertiary
              font { family: Theme.fontFamily; pixelSize: 13 }
            }
            Item { Layout.fillWidth: true }
            Rectangle {
              id: zoomGroup
              objectName: "overview-zoom-group-" + strip.workspaceId
              visible: opacity > 0 && strip.headerControlsFit
              opacity: strip.zoomVisible ? 1 : 0
              Behavior on opacity { NumberAnimation { duration: 120 } }
              Layout.alignment: Qt.AlignVCenter
              Layout.preferredHeight: 24
              Layout.preferredWidth: zoomRow.implicitWidth
              radius: 6
              color: Theme.surfaceControl
              border.color: Theme.border
              RowLayout {
                id: zoomRow
                anchors.fill: parent
                spacing: 0
                Button { objectName: "overview-zoom-out-" + strip.workspaceId; text: "−"; tooltipText: "Zoom out"; fontSize: 13; verticalPadding: 0; leftPadding: 0; rightPadding: 0; focusable: false; Layout.fillHeight: true; Layout.preferredWidth: 24; onClicked: stripCanvas.changeZoom(1 / 1.25); }
                Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true; Layout.topMargin: 4; Layout.bottomMargin: 4; color: Theme.border }
                Text {
                  text: Math.round(stripCanvas.zoom * 100) + "%"
                  textFormat: Text.PlainText
                  horizontalAlignment: Text.AlignHCenter
                  verticalAlignment: Text.AlignVCenter
                  Layout.preferredWidth: 44
                  Layout.fillHeight: true
                  color: Theme.textSecondary
                  font { family: Theme.fontFamily; pixelSize: 12; weight: Font.Medium }
                }
                Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true; Layout.topMargin: 4; Layout.bottomMargin: 4; color: Theme.border }
                Button { objectName: "overview-zoom-in-" + strip.workspaceId; text: "+"; tooltipText: "Zoom in"; fontSize: 13; verticalPadding: 0; leftPadding: 0; rightPadding: 0; focusable: false; Layout.fillHeight: true; Layout.preferredWidth: 24; onClicked: stripCanvas.changeZoom(1.25); }
              }
            }
            Button { objectName: "overview-fit-" + strip.workspaceId; text: "Fit"; tooltipText: "Fit all"; fontSize: 12; verticalPadding: 2; focusable: false; visible: stripCanvas.zoom > 1 && strip.headerControlsFit; Layout.alignment: Qt.AlignVCenter; Layout.preferredHeight: 24; onClicked: stripCanvas.fit(); }
            Button { objectName: "overview-current-view-" + strip.workspaceId; text: "Current view"; fontSize: 12; verticalPadding: 2; focusable: false; visible: strip.row && strip.row.active && stripCanvas.zoom > 1 && strip.headerControlsFit; Layout.alignment: Qt.AlignVCenter; Layout.preferredHeight: 24; onClicked: stripCanvas.currentView(); }
            Button {
              id: actionsButton
              objectName: "overview-actions-" + strip.workspaceId
              text: "⋯"
              tooltipText: "Workspace actions"
              fontSize: 12
              verticalPadding: 2
              leftPadding: 0
              rightPadding: 0
              focusable: false
              visible: strip.headerControlsFit
              Layout.alignment: Qt.AlignVCenter
              Layout.preferredWidth: 24
              Layout.preferredHeight: 24
              onClicked: board.workspaceActionsRequested(strip.workspaceId,
                actionsButton.mapToItem(null, 0, actionsButton.height), actionsButton.mapToItem(null, 0, 0).y);
            }
          }
          Text {
            visible: !strip.row || strip.row.windows.length === 0
            Layout.fillWidth: true
            Layout.fillHeight: true
            text: strip.entry && strip.entry.count === 0 ? "No windows on this workspace." : "No previewable windows."
            textFormat: Text.PlainText
            color: Theme.textSecondary
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: Text.AlignHCenter
            font { family: Theme.fontFamily; pixelSize: 13; weight: Font.Medium }
          }
          CanvasMap {
            id: stripCanvas
            objectName: "workspace-preview-map"
            Layout.fillWidth: true
            Layout.preferredHeight: strip.canvasHeight + strip.trackExtra
            visible: !!strip.row && strip.row.windows.length > 0
            row: strip.row
            // Live window images: without this the canvas stays in its vector
            // fallback and the slots never request a capture.
            thumbnailSource: Qt.resolvedUrl("native/WindowThumbnail.qml")
            minimumImageEdge: board.density === board.densityFull ? 64 : 0
            fitToWidth: true
            fixedLane: true
            density: board.density
            viewportTrackEnabled: true
            badgeAddresses: board.badgeAddresses
            query: board.query
            focusedAddress: board.focusedAddress
            selectedAddress: board.selectedAddress
            captureEnabled: board.captureEnabled
            // Visible region of this strip in the map's own coordinates; slots
            // fully outside it release native capture (thumbnail lifetime rule).
            captureViewport: {
              var mapLeft = stripCanvas.mapToItem(strip, 0, 0).x;
              var left = Math.max(0, -strip.x - mapLeft);
              var right = Math.min(width, stripList.width - strip.x - mapLeft);
              return Qt.rect(left, stripList.contentY - strip.y - y, Math.max(0, right - left), stripList.height);
            }
            iconFor: board.iconFor
            nameFor: board.nameFor
            panEnabled: !!strip.row && board.canPanRow(strip.row)
            foreground: Theme.foreground
            background: Theme.background
            accent: Theme.accent
            onActivated: function(address) { board.activated(address); }
            onWindowMenuRequested: function(address, position) { board.windowMenuRequested(address, position); }
            onPanned: function(delta) { board.panned(strip.workspaceId, delta); }
          }
        }
        // Keyboard selection reveals the window inside its strip, mirroring the
        // WorkspacePreview behavior the strips replace.
        function revealSelection(): void {
          if (!visible || !strip.row) return;
          if (!strip.row.windows.some(function(w) { return w.address === board.selectedAddress; })) return;
          stripCanvas.reveal(board.selectedAddress);
        }
        Component.onCompleted: strip.revealSelection()
        Connections {
          target: board
          function onSelectedAddressChanged() { strip.revealSelection(); }
        }
      }
    }

    Rectangle {
      id: sidebarPanel
      objectName: "overview-sidebar"
      x: stripList.width + board.sidebarGap
      y: 0
      width: board.sidebarWidth
      height: content.height
      radius: 12
      z: 4
      color: Theme.surfaceRaised
      border.color: Theme.border
      visible: true
      opacity: board.sidebarOpen ? 1 : 0
      Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
      Behavior on opacity { NumberAnimation { duration: 120 } }
      ColumnLayout {
        id: sidebarHeader
        anchors {
          left: parent.left
          top: parent.top
          right: parent.right
          leftMargin: 16
          topMargin: 16
          rightMargin: 16
        }
        spacing: 8
        RowLayout {
          Layout.fillWidth: true
          spacing: 8
          Text {
            objectName: "overview-title"
            Layout.fillWidth: true
            text: "Windows"
            textFormat: Text.PlainText
            color: Theme.textPrimary
            font { family: Theme.fontFamily; pixelSize: 15; weight: Font.DemiBold }
          }
          Rectangle {
            objectName: "overview-density-control"
            Layout.preferredWidth: 100
            Layout.preferredHeight: 32
            radius: 8
            color: Theme.surfaceControl
            RowLayout {
              anchors.fill: parent
              anchors.margins: 2
              spacing: 0
              Repeater {
                model: [board.densityFull, board.densityIcons, board.densityTimeline]
                delegate: Button {
                  id: densityButton
                  required property int modelData
                  objectName: "overview-density-" + modelData
                  Layout.preferredWidth: 32
                  Layout.preferredHeight: 28
                  focusable: true
                  selected: board.density === modelData
                  Accessible.role: Accessible.RadioButton
                  Accessible.name: modelData === board.densityFull ? "Full density"
                    : modelData === board.densityIcons ? "Icons density" : "Timeline density"
                  Accessible.checked: selected
                  tooltipText: Accessible.name
                  background: Rectangle {
                    radius: 6
                    color: densityButton.selected ? Theme.surfaceSelected : densityButton.hovered ? Theme.surfaceHover : "transparent"
                  }
                  contentItem: DensityGlyph {
                    anchors.centerIn: parent
                    mode: densityButton.modelData
                    ink: densityButton.selected ? Theme.accent : Theme.textSecondary
                  }
                  onClicked: board.densityChangeRequested(modelData)
                }
              }
            }
          }
          Rectangle {
            objectName: "overview-density-list-divider"
            Layout.preferredWidth: 1
            Layout.preferredHeight: 16
            color: Theme.alpha(Theme.foreground, 0.14)
          }
          Button {
            objectName: "overview-list-toggle"
            text: ""
            tooltipText: board.listEnabled ? "Hide the window list" : "Show the window list"
            selected: board.sidebarOpen
            focusable: false
            fontSize: 13
            Layout.preferredWidth: 24
            Layout.preferredHeight: 24
            Accessible.name: board.listEnabled ? "Hide the window list" : "Show the window list"
            contentItem: Item {
              SidebarGlyph { anchors.centerIn: parent; open: board.sidebarOpen }
            }
            // A search-revealed list can be dismissed without changing its saved preference.
            onClicked: {
              if (!board.listEnabled && board.sidebarOpen)
                board.searchListDismissed = true;
              else
                board.listToggleRequested(!board.listEnabled);
            }
          }
        }
        Item {
          id: fieldBox
          Layout.fillWidth: true
          Layout.preferredHeight: 40
          TextField {
            id: search
            objectName: "overview-search"
            anchors.fill: parent
            placeholderText: "Find a window, app, or display…"
            font { family: Theme.fontFamily; pixelSize: 15 }
            placeholderTextColor: Theme.textTertiary
            topPadding: 8
            bottomPadding: 8
            leftPadding: 36
            rightPadding: clearButton.visible ? 32 : 12
            background: Rectangle {
              radius: 8
              color: Theme.surfaceControl
              border.color: Theme.border
            }
            onTextChanged: board.query = text
            onAccepted: if (board.selectedAddress) board.activated(board.selectedAddress)
            Keys.onEscapePressed: {
              if (text !== "") { text = ""; return; }
              board.dismissed();
            }
            Keys.onDownPressed: board.selectNext(1)
            Keys.onUpPressed: board.selectNext(-1)
            Accessible.name: "Find a window, app, or display"
          }
          Rectangle {
            anchors.fill: fieldBox
            anchors.margins: -2
            radius: 10
            color: "transparent"
            border.color: Theme.accent
            border.width: 2
            visible: search.activeFocus
          }
          Item {
            x: 12
            anchors.verticalCenter: parent.verticalCenter
            width: 16
            height: 16
            Rectangle {
              x: 1; y: 1
              width: 9; height: 9
              radius: 5
              color: "transparent"
              border.width: 1.5
              border.color: Theme.textTertiary
            }
            Rectangle {
              x: 9.5; y: 9.5
              width: 5.5; height: 1.5
              radius: 0.75
              rotation: 45
              color: Theme.textTertiary
            }
          }
          Item {
            id: clearButton
            objectName: "overview-search-clear"
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            width: 24
            height: 24
            visible: search.text !== ""
            Item {
              anchors.centerIn: parent
              width: 12
              height: 12
              Rectangle {
                anchors.centerIn: parent
                width: 15
                height: 1.5
                radius: 1
                rotation: 45
                color: Theme.textSecondary
              }
              Rectangle {
                anchors.centerIn: parent
                width: 15
                height: 1.5
                radius: 1
                rotation: -45
                color: Theme.textSecondary
              }
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                search.text = "";
                search.forceActiveFocus();
              }
            }
            Accessible.role: Accessible.Button
            Accessible.name: "Clear search"
          }
        }
        RowLayout {
          Layout.alignment: Qt.AlignRight
          spacing: 4
          RowLayout {
            spacing: 4
            Keycap { label: "↵" }
            Text { text: "open"; textFormat: Text.PlainText; color: Theme.textTertiary; font { family: Theme.fontFamily; pixelSize: 12 } }
          }
          RowLayout {
            spacing: 4
            Keycap { label: "Esc" }
            Text { text: "close"; textFormat: Text.PlainText; color: Theme.textTertiary; font { family: Theme.fontFamily; pixelSize: 12 } }
          }
        }
      }
      WindowSidebar {
        id: sidebar
        anchors {
          left: parent.left
          top: parent.top
          right: parent.right
          bottom: parent.bottom
          leftMargin: 16
          topMargin: board.sidebarHeaderHeight
          bottomMargin: 16
        }
        rows: board.rows
        rowIds: board.rowIds
        windows: board.windows
        badgeAddresses: board.badgeAddresses
        query: board.query
        scopeMonitor: board.scopeMonitor
        scopeWorkspace: board.scopeWorkspace
        focusedAddress: board.focusedAddress
        iconFor: board.iconFor
        nameFor: board.nameFor
        onActivated: function(address) { board.activated(address); }
        onScopeSelected: board.focusSearch()
      }
    }
  }

  Rectangle {
    objectName: "overview-collapsed-rail"
    x: content.x + content.width - width
    y: content.y
    width: 48
    height: content.height
    radius: 12
    color: Theme.surfaceRaised
    border.color: Theme.border
    visible: !board.sidebarOpen
    z: 5
    ColumnLayout {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: 16
      spacing: 8
      Button {
        id: railSearch
        objectName: "overview-search-rail"
        Layout.alignment: Qt.AlignHCenter
        Layout.preferredWidth: 32
        Layout.preferredHeight: 32
        text: ""
        tooltipText: "Search windows"
        focusable: false
        Accessible.name: "Search windows"
        contentItem: Item { SearchGlyph { anchors.centerIn: parent } }
        background: Rectangle { radius: 8; color: railSearch.hovered ? Theme.surfaceHover : "transparent" }
        onClicked: {
          board.searchListDismissed = false;
          if (!board.listEnabled) board.listToggleRequested(true);
          Qt.callLater(board.focusSearch);
        }
      }
      Button {
        id: railList
        objectName: "overview-list-rail"
        Layout.alignment: Qt.AlignHCenter
        Layout.preferredWidth: 32
        Layout.preferredHeight: 32
        text: ""
        tooltipText: "Show the window list"
        focusable: false
        Accessible.name: "Show the window list"
        contentItem: Item { SidebarGlyph { anchors.centerIn: parent; open: false } }
        background: Rectangle { radius: 8; color: railList.hovered ? Theme.surfaceHover : "transparent" }
        onClicked: {
          board.searchListDismissed = false;
          if (!board.listEnabled) board.listToggleRequested(true);
        }
      }
      Rectangle {
        Layout.alignment: Qt.AlignHCenter
        Layout.preferredWidth: 24
        Layout.preferredHeight: 1
        color: Theme.alpha(Theme.foreground, 0.12)
      }
      Repeater {
        model: [board.densityFull, board.densityIcons, board.densityTimeline]
        delegate: Button {
          id: railDensityButton
          required property int modelData
          objectName: "overview-density-rail-" + modelData
          Layout.alignment: Qt.AlignHCenter
          Layout.preferredWidth: 32
          Layout.preferredHeight: 32
          focusable: true
          selected: board.density === modelData
          Accessible.role: Accessible.RadioButton
          Accessible.name: modelData === board.densityFull ? "Full density"
            : modelData === board.densityIcons ? "Icons density" : "Timeline density"
          Accessible.checked: selected
          tooltipText: Accessible.name
          background: Rectangle {
            radius: 8
            color: railDensityButton.selected ? Theme.accentSoft : railDensityButton.hovered ? Theme.surfaceHover : "transparent"
          }
          contentItem: DensityGlyph {
            anchors.centerIn: parent
            mode: railDensityButton.modelData
            ink: railDensityButton.selected ? Theme.accent : Theme.textSecondary
          }
          onClicked: board.densityChangeRequested(modelData)
        }
      }
    }
  }
}
