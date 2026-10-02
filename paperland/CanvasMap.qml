pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as QQC
import "Layout.js" as Layout
import "shared/PreviewGeometry.js" as PreviewGeometry
import "shared" as Shared

Item {
  id: root
  property url thumbnailSource
  property bool captureEnabled: false
  property rect captureViewport: Qt.rect(0, 0, width, height)
  readonly property rect captureArea: {
    var x = Math.max(0, captureViewport.x), y = Math.max(0, captureViewport.y);
    return Qt.rect(x, y, Math.max(0, Math.min(width, captureViewport.x + captureViewport.width) - x),
      Math.max(0, Math.min(height, captureViewport.y + captureViewport.height) - y));
  }
  property real minimumImageEdge: 0
  property bool fitToWidth: false
  property bool fixedLane: false
  property int density: 0
  property bool viewportTrackEnabled: false
  readonly property int trackSpace: fixedLane && viewportTrackEnabled && row && row.active ? 8 : 0
  readonly property real trackInset: fixedLane ? padX : 16
  readonly property real trackLength: Math.max(0, (row && row.vertical && !fixedLane ? flick.height : flick.width) - trackInset * 2)
  readonly property real thumbFraction: !row ? 1 : Math.max(0, Math.min(1,
    (row.vertical ? row.viewport.height : row.viewport.width) / (row.vertical ? row.bounds.height : row.bounds.width)))
  readonly property real thumbOffset: !row ? 0 : Math.max(0, Math.min(1 - thumbFraction,
    ((row.vertical ? row.viewport.y - row.bounds.y : row.viewport.x - row.bounds.x)
      / (row.vertical ? row.bounds.height : row.bounds.width))))
  readonly property bool spacious: minimumImageEdge > 0
  // Fit-to-width keeps one constant left edge across every overview strip;
  // centring would give each strip its own origin.
  readonly property real padX: fixedLane && fitToWidth && row ? 8 : 7
  readonly property real padY: fixedLane && fitToWidth && row ? 8 : 7
  property var sourceAspects: ({})
  property string revealAddress: ""
  // A newly loaded image can change fitted scale after selection revealed its slot.
  // Retain that reveal intent until the user starts inspecting the map manually.
  onSourceAspectsChanged: Qt.callLater(refreshReveal)
  function refreshReveal(): void { if (revealAddress) reveal(revealAddress); }
  readonly property real preferredScale: PreviewGeometry.requiredScale(row, 220, sourceAspects)
  readonly property real imageScaleX: row && spacious
      ? (fitToWidth ? Math.max(0, width - padX - (fixedLane ? padX : 8)) / row.bounds.width
      : Math.max(PreviewGeometry.requiredScale(row, minimumImageEdge, sourceAspects),
        Math.min(Math.max(0, width - 14) / row.bounds.width, Math.max(0, height - 14) / row.bounds.height))) * zoom : 1
  readonly property real imageScaleY: row && spacious
      ? (fitToWidth ? Math.max(0, height - trackSpace - padY * 2) / row.bounds.height
      : Math.max(PreviewGeometry.requiredScale(row, minimumImageEdge, sourceAspects),
        Math.min(Math.max(0, width - 14) / row.bounds.width, Math.max(0, height - 14) / row.bounds.height))) * (fixedLane && fitToWidth ? 1 : zoom) : 1
  property var pendingAspects: ({})
  function rememberAspect(address: string, ratio: real): void {
    if (!spacious || addresses.indexOf(address) < 0 || ratio <= 0) return;
    // Qt.callLater coalesces calls by function, so batch all identities explicitly.
    pendingAspects[address] = ratio;
    Qt.callLater(publishAspects);
  }
  function publishAspects(): void {
    var next = Object.assign({}, sourceAspects);
    var changed = false;
    Object.keys(pendingAspects).forEach(function(address) {
      if (root.addresses.indexOf(address) >= 0 && next[address] !== root.pendingAspects[address]) {
        next[address] = root.pendingAspects[address];
        changed = true;
      }
    });
    pendingAspects = {};
    if (changed) sourceAspects = next;
  }
  property var iconFor: function(app) { return ""; }
  property var nameFor: function(app) { return Layout.appName(app); }
  property var addresses: []
  property var badgeAddresses: []
  function syncAddresses(): void {
    var next = row ? row.windows.map(function(w) { return w.address; }) : [];
    if (JSON.stringify(next) !== JSON.stringify(addresses)) {
      addresses = next;
      var retained = {};
      next.forEach(function(address) { if (root.sourceAspects[address]) retained[address] = root.sourceAspects[address]; });
      sourceAspects = retained;
    }
  }
  property var row: null
  property string focusedAddress: ""
  property string selectedAddress: ""
  property string query: ""
  property bool live: false
  property bool externalControl: false
  property bool panEnabled: true
  readonly property bool canPan: panEnabled && row && row.active && !row.fullscreen
  property real zoom: 1
  property string hoveredAddress: ""
  property color foreground: "white"
  property color background: "black"
  property color accent: "cyan"
  signal activated(string address)
  function menuAnchor(address: string): point {
    var window = root.row ? root.row.windows.find(function(w) { return w.address === address; }) : null;
    if (window) {
      var r = canvas.rect(window.rect);
      var left = Math.max(r.x, flick.contentX), top = Math.max(r.y, flick.contentY);
      var right = Math.min(r.x + r.width, flick.contentX + flick.width);
      var bottom = Math.min(r.y + r.height, flick.contentY + flick.height);
      if (right > left && bottom > top) return flick.contentItem.mapToItem(null, left, top);
    }
    return root.mapToItem(null, width / 2, height / 2);
  }
  signal windowMenuRequested(string address, point position)
  signal panned(real delta)
  signal hovered(string address)

  function repaint() { canvas.requestPaint(); }
  function fit() { revealAddress = ""; zoom = 1; flick.contentX = 0; flick.contentY = 0; }
  function currentView() {
    revealAddress = "";
    if (!row) return;
    var center = row.vertical ? row.viewport.y + row.viewport.height / 2 : row.viewport.x + row.viewport.width / 2;
    if (row.vertical && !(fixedLane && fitToWidth)) flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, padY + (center - row.bounds.y) * canvas.sy - flick.height / 2));
    else flick.contentX = Math.max(0, Math.min(flick.contentWidth - flick.width, padX + (center - row.bounds.x) * canvas.sx - flick.width / 2));
  }
  function reveal(address) {
    revealAddress = address;
    if (!row) return;
    var window = row.windows.find(function(item) { return item.address === address; });
    if (!window) return;
    var box = canvas.rect(window.rect);
    if (box.width > flick.width)
      flick.contentX = root.badgeAddresses.indexOf(address) >= 0 ? box.x + box.width - flick.width : box.x;
    else if (box.x < flick.contentX) flick.contentX = box.x;
    else if (box.x + box.width > flick.contentX + flick.width) flick.contentX = box.x + box.width - flick.width;
    if (!(fixedLane && fitToWidth)) {
      if (box.height > flick.height) flick.contentY = box.y;
      else if (box.y < flick.contentY) flick.contentY = box.y;
      else if (box.y + box.height > flick.contentY + flick.height) flick.contentY = box.y + box.height - flick.height;
    }
    flick.contentX = Math.max(0, Math.min(flick.contentWidth - flick.width, flick.contentX));
    flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, flick.contentY));
  }
  function changeZoom(factor, anchorX, anchorY) {
    revealAddress = "";
    var previous = zoom;
    var previousScaleX = imageScaleX;
    var x = anchorX === undefined ? flick.width / 2 : anchorX;
    var y = anchorY === undefined ? flick.height / 2 : anchorY;
    if (!fitToWidth) {
      zoom = Math.max(1, Math.min(6, zoom * factor));
      flick.contentX = Math.max(0, Math.min(flick.contentWidth - flick.width, (flick.contentX + x) * zoom / previous - x));
      flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, (flick.contentY + y) * zoom / previous - y));
      return;
    }
    if (!(fixedLane && fitToWidth)) {
      zoom = Math.max(1, Math.min(6, zoom * factor));
      flick.contentX = Math.max(0, Math.min(flick.contentWidth - flick.width, (flick.contentX + x) * zoom / previous - x));
      flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, (flick.contentY + y) * zoom / previous - y));
      return;
    }
    var worldX = (flick.contentX + x - padX) / previousScaleX;
    zoom = Math.max(1, Math.min(6, zoom * factor));
    Qt.callLater(function() {
      flick.contentX = Math.max(0, Math.min(flick.contentWidth - flick.width, padX + worldX * imageScaleX - x));
      flick.contentY = 0;
    });
  }
  onRowChanged: { syncAddresses(); repaint(); }
  Component.onCompleted: syncAddresses()
  onFocusedAddressChanged: repaint()
  onSelectedAddressChanged: repaint()
  onQueryChanged: repaint()
  onHoveredAddressChanged: { repaint(); hovered(hoveredAddress); }
  onForegroundChanged: repaint()
  onBackgroundChanged: repaint()
  onAccentChanged: repaint()
  onCanPanChanged: repaint()

  Rectangle {
    objectName: "overview-canvas-surface"
    anchors.fill: parent
    visible: root.fixedLane
    radius: 10
    color: Theme.surfaceCanvas
    border.width: 1
    border.color: root.row && root.row.active ? Theme.borderCanvasCurrent : Theme.borderCanvas
  }
  Flickable {
    id: flick
    anchors { fill: parent; bottomMargin: root.fixedLane && root.fitToWidth && root.row && root.row.active ? root.trackSpace : 0 }
    objectName: "map-scroll"
    contentWidth: root.spacious && root.row ? Math.max(width, root.row.bounds.width * root.imageScaleX + (root.fitToWidth ? root.padX * 2 : 14)) : width * (root.row && root.row.vertical ? 1 : root.zoom)
    contentHeight: root.fixedLane && root.fitToWidth ? height : root.spacious && root.row ? Math.max(height, root.row.bounds.height * root.imageScaleY + 14) : height * (root.row && root.row.vertical ? root.zoom : 1)
    onContentXChanged: canvas.requestPaint()
    onContentYChanged: {
      if (root.fixedLane && root.fitToWidth && contentY !== 0) contentY = 0;
      canvas.requestPaint();
    }
    onContentWidthChanged: contentX = Math.max(0, Math.min(contentX, contentWidth - width))
    onContentHeightChanged: contentY = Math.max(0, Math.min(contentY, contentHeight - height))
    QQC.ScrollBar.horizontal: QQC.ScrollBar {
      objectName: "map-horizontal-scrollbar"
      onPressedChanged: if (pressed) root.revealAddress = ""
      active: root.zoom > 1.001 && size < 1
      policy: root.fixedLane ? (root.zoom > 1.001 ? QQC.ScrollBar.AsNeeded : QQC.ScrollBar.AlwaysOff) : QQC.ScrollBar.AsNeeded
      background: Item { }
      contentItem: Rectangle { implicitHeight: 6; radius: 3; color: Theme.alpha(Theme.foreground, 0.35) }
    }
    interactive: false
    clip: true
    Repeater {
      model: root.addresses
      delegate: Item {
        id: imageCard
        required property string modelData
        readonly property var window: root.row ? root.row.windows.find(function(w) { return w.address === imageCard.modelData; }) : null
        readonly property var box: window ? canvas.rect(window.rect) : ({x: 0, y: 0, width: 0, height: 0})
        readonly property bool matches: !!window && Layout.matches(window, root.query)
        // Cover fills the card, so its short edge is the useful capture floor.
        readonly property real fittedImageEdge: Math.min(width, height)
        readonly property bool selected: modelData === root.selectedAddress
        readonly property bool focused: modelData === root.focusedAddress
        readonly property bool hot: selected || modelData === root.hoveredAddress
        readonly property int badgeNumber: root.badgeAddresses.indexOf(modelData) + 1
        objectName: "map-card-" + modelData
        x: box.x; y: root.row && root.row.vertical ? box.y : root.padY
        width: root.row && root.row.vertical ? Math.max(0, flick.width - root.padX * 2) : box.width
        height: root.row && root.row.vertical ? box.height : Math.max(0, flick.height - root.padY * 2)
        z: focused ? 2 : 0
        visible: root.thumbnailSource.toString() !== ""
        // Selection is a ring outside the card; focus stays on the card itself.
        Accessible.role: Accessible.Button
        Accessible.selected: modelData === root.selectedAddress
        Accessible.name: window ? root.nameFor(window.app) + ", " + window.title
          + (badgeNumber > 0 && badgeNumber <= 9 ? ", number " + badgeNumber : "") : ""
        Accessible.onPressAction: root.activated(modelData)
        Rectangle {
          anchors.fill: parent
          anchors.margins: -2
          radius: 8
          color: "transparent"
          border.color: root.accent
          border.width: 2
          visible: imageCard.selected
        }
        Rectangle {
          anchors.fill: parent
          radius: 6
          color: Theme.thumbnailLetterbox
        }
        Shared.ThumbnailSlot {
          id: thumbnail
          objectName: "map-thumbnail-" + imageCard.modelData
          anchors.fill: parent
          visible: width >= 34 && height >= 20
          imageOpacity: imageCard.matches ? 1 : Theme.unmatchedThumbnailOpacity
          // Publish after Loader evaluation: changing scale here can unload another slot.
          onAspectRatioChanged: root.rememberAspect(imageCard.modelData, aspectRatio)
          address: imageCard.modelData
          thumbnailSource: root.density === 1 || (root.fitToWidth && root.minimumImageEdge > 0 && imageCard.fittedImageEdge < root.minimumImageEdge) ? "" : root.thumbnailSource
          cover: root.density === 0
          showCachedBadge: false
          cornerRadius: 6
          cornerColor: Theme.thumbnailLetterbox
          iconSource: imageCard.window ? root.iconFor(imageCard.window.app) : ""
          label: imageCard.window ? root.nameFor(imageCard.window.app) : ""
          foreground: root.foreground
          labelColor: Theme.textTertiary
          fontFamily: Theme.fontFamily
          captureEnabled: root.captureEnabled
          viewport: Qt.rect(flick.contentX + root.captureArea.x - imageCard.x - x, flick.contentY + root.captureArea.y - imageCard.y - y, root.captureArea.width, root.captureArea.height)
        }
        Rectangle {
          anchors.fill: parent
          radius: 6
          color: "transparent"
          border.width: 1
          border.color: imageCard.hot ? Theme.alpha(root.foreground, 0.40) : Theme.alpha(root.foreground, 0.22)
        }
        Rectangle {
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: 24
          visible: parent.height >= 64
          topLeftRadius: 6
          topRightRadius: 6
          color: Qt.tint(root.background, Theme.alpha(root.foreground, 0.14))
          Row {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            spacing: 5
            Rectangle {
              visible: imageCard.focused
              anchors.verticalCenter: parent.verticalCenter
              width: 6; height: 6; radius: 3
              color: root.accent
            }
            Image {
              visible: imageCard.window && root.iconFor(imageCard.window.app).toString() !== ""
              source: imageCard.window ? root.iconFor(imageCard.window.app) : ""
              sourceSize.width: 28
              sourceSize.height: 28
              anchors.verticalCenter: parent.verticalCenter
              width: 14; height: 14
              fillMode: Image.PreserveAspectFit
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: imageCard.window ? root.nameFor(imageCard.window.app) : ""
              textFormat: Text.PlainText
              color: imageCard.focused ? root.accent : Theme.textSecondary
              font { family: Theme.fontFamily; pixelSize: 12; weight: Font.DemiBold }
            }
            Text {
              width: visible ? parent.width - x : 0
              anchors.verticalCenter: parent.verticalCenter
              visible: imageCard.window && imageCard.window.title !== ""
              text: imageCard.window ? imageCard.window.title : ""
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: Theme.textSecondary
              font { family: Theme.fontFamily; pixelSize: 12 }
            }
          }
        }
        Rectangle {
          id: cachedSnapshot
          objectName: "map-cached-snapshot-" + imageCard.modelData
          anchors { top: parent.top; right: parent.right; margins: 4 }
          width: 18; height: 18; radius: 9
          color: Theme.alpha("#000000", 0.55)
          visible: thumbnail.cached
          Accessible.role: Accessible.StaticText
          Accessible.name: "Snapshot — window is off screen"
          Item {
            anchors.centerIn: parent
            width: 10; height: 10
            Rectangle { anchors.fill: parent; radius: 5; color: "transparent"; border.width: 1; border.color: "white" }
            Rectangle { x: 4.5; y: 2; width: 1; height: 4; color: "white" }
            Rectangle { x: 4.5; y: 5; width: 3; height: 1; rotation: -35; transformOrigin: Item.Left; color: "white" }
          }
          MouseArea {
            id: cacheMouse
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
            QQC.ToolTip { visible: cacheMouse.containsMouse; text: "Snapshot — window is off screen"; delay: 300 }
          }
        }
      }
    }
    Canvas {
      id: canvas
      z: 2
      objectName: "map-bitmap"
      x: root.spacious ? flick.contentX : 0
      y: root.spacious ? flick.contentY : 0
      width: root.spacious ? flick.width : flick.contentWidth
      height: root.spacious ? flick.height : flick.contentHeight
      readonly property real pad: 7
      readonly property real sx: root.spacious ? root.imageScaleX : root.row ? (width - pad * 2) / root.row.bounds.width : 1
      readonly property real sy: root.spacious ? root.imageScaleY : root.row ? (height - pad * 2) / root.row.bounds.height : 1
      // The visible viewport in canvas coordinates; card badges and the vector fallback use it.
      readonly property var viewRect: root.row ? rect(root.row.viewport) : ({x: 0, y: 0, width: 0, height: 0})
      function rect(r) {
        return { x: root.spacious ? root.padX + (r.x - root.row.bounds.x) * sx : pad + (r.x - root.row.bounds.x) * sx,
          y: root.spacious ? root.padY + (r.y - root.row.bounds.y) * sy : pad + (r.y - root.row.bounds.y) * sy,
          width: r.width * sx, height: r.height * sy };
      }
      function box(ctx, r, fill, stroke, lineWidth) {
        ctx.fillStyle = fill; ctx.fillRect(r.x, r.y, r.width, r.height);
        ctx.strokeStyle = stroke; ctx.lineWidth = lineWidth;
        ctx.strokeRect(r.x + lineWidth / 2, r.y + lineWidth / 2, Math.max(0, r.width - lineWidth), Math.max(0, r.height - lineWidth));
      }
      onSxChanged: requestPaint()
      onSyChanged: requestPaint()
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()
      onPaint: {
        var ctx = getContext("2d");
        ctx.clearRect(0, 0, width, height);
        if (!root.row) return;
        ctx.save();
        if (root.spacious) ctx.translate(-flick.contentX, -flick.contentY);
        // This canvas paints the vector card fallback.
        // Match hit testing: focused windows are painted above overlaps.
        var ordered = root.row.windows.filter(function(w) { return w.address !== root.focusedAddress; });
        var focusedWindow = root.row.windows.find(function(w) { return w.address === root.focusedAddress; });
        if (focusedWindow) ordered.push(focusedWindow);
        if (!root.thumbnailSource.toString()) ordered.forEach(function(w) {
          var r = rect(w.rect);
          var focused = w.address === root.focusedAddress;
          var hot = w.address === root.hoveredAddress || w.address === root.selectedAddress;
          box(ctx, r, hot ? Theme.surfaceSelected : (w.inView ? Theme.surfaceControl : Theme.surfaceStrip),
            Theme.alpha(root.foreground, hot ? 0.40 : 0.22), 1);
          if (r.width > 44 && r.height > 26) {
            ctx.save(); ctx.beginPath(); ctx.rect(r.x + 7, r.y + 5, Math.max(0, r.width - 14), Math.max(0, r.height - 10)); ctx.clip();
            if (focused) {
              ctx.fillStyle = root.accent;
              ctx.beginPath(); ctx.arc(r.x + 10, r.y + 16, 3, 0, Math.PI * 2); ctx.fill();
            }
            ctx.fillStyle = focused ? root.accent : Theme.textSecondary;
            ctx.font = "600 11px " + Theme.fontFamily;
            ctx.fillText(root.nameFor(w.app), r.x + (focused ? 18 : 9), r.y + 20);
            if (r.height > 48) {
              ctx.font = "11px " + Theme.fontFamily;
              ctx.fillStyle = Theme.textTertiary;
              ctx.fillText(w.title, r.x + 9, r.y + 39);
            }
            ctx.restore();
          }
        });
        ctx.restore();
      }
    }
  Rectangle {
    objectName: "overview-viewport-track"
    parent: root
    visible: root.viewportTrackEnabled && !!root.row && root.row.active
    x: root.row && root.row.vertical && !root.fixedLane ? root.width - 5 : root.trackInset
    y: root.row && root.row.vertical && !root.fixedLane ? root.trackInset : root.height - 5
    width: root.row && root.row.vertical && !root.fixedLane ? 1 : root.trackLength
    height: root.row && root.row.vertical && !root.fixedLane ? root.trackLength : 1
    radius: 0.5
    color: Theme.alpha(root.foreground, 0.14)
    Rectangle {
      objectName: "overview-viewport-thumb"
      x: root.row && root.row.vertical && !root.fixedLane ? -1.5 : parent.width * root.thumbOffset
      y: root.row && root.row.vertical && !root.fixedLane ? parent.height * root.thumbOffset : -1.5
      width: root.row && root.row.vertical && !root.fixedLane ? 4 : parent.width * root.thumbFraction
      height: root.row && root.row.vertical && !root.fixedLane ? parent.height * root.thumbFraction : 4
      radius: 2
      color: root.accent
    }
  }
  Item {
    id: trackHitArea
    objectName: "overview-viewport-hit-area"
    parent: root
    visible: root.viewportTrackEnabled && !!root.row && root.row.active
    x: root.row && root.row.vertical && !root.fixedLane ? root.width - 16 : 0
    y: root.row && root.row.vertical && !root.fixedLane ? 0 : root.height - 16
    width: root.row && root.row.vertical && !root.fixedLane ? 16 : root.width
    height: root.row && root.row.vertical && !root.fixedLane ? root.height : 16
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton
      cursorShape: pressed ? Qt.ClosedHandCursor : root.canPan ? Qt.OpenHandCursor : Qt.ArrowCursor
      property real lastPosition: 0
      property real frozenScale: 1
      onPressed: function(event) {
        if (!root.canPan) { event.accepted = false; return; }
        root.revealAddress = "";
        var p = mapToItem(root, event.x, event.y);
        lastPosition = root.row.vertical && !root.fixedLane ? p.y : p.x;
        frozenScale = root.trackLength / (root.row.vertical && !root.fixedLane ? root.row.bounds.height : root.row.bounds.width);
      }
      onPositionChanged: function(event) {
        if (!pressed || !root.canPan || frozenScale <= 0) return;
        var p = mapToItem(root, event.x, event.y);
        var position = root.row.vertical && !root.fixedLane ? p.y : p.x;
        root.panned((position - lastPosition) / frozenScale);
        lastPosition = position;
      }
    }
  }
  Repeater {
      model: root.badgeAddresses.slice(0, 9)
      delegate: Shared.StripBadge {
        id: badge
        required property string modelData
        required property int index
        readonly property var window: root.row
          ? root.row.windows.find(function(item) { return item.address === badge.modelData; }) : null
        readonly property var box: window ? canvas.rect(window.rect) : ({ x: 0, y: 0, width: 0, height: 0 })
        objectName: "map-badge-" + modelData
        // Badges remain attached to their cards even when the window list is open.
        x: box.x + box.width - badge.width - 3
        y: box.y + 3
        z: 2.5
        visible: !!window
        number: index + 1
      }
    }
    Item {
      // Input coordinates remain in world-content space while the bitmap follows the viewport.
      z: 3
      width: flick.contentWidth
      height: flick.contentHeight
      MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
        cursorShape: draggingMap ? Qt.ClosedHandCursor : (root.hoveredAddress ? Qt.PointingHandCursor : Qt.ArrowCursor)
        property bool draggingMap: false
        property real lastPosition: 0
        property real lastX: 0
        property real lastY: 0
        property real startX: 0
        property real startY: 0
        property real frozenScale: 1
        property string pressedAddress: ""
        function hit(x, y) {
          return root.row ? Layout.hitTest(root.row, (x - (root.spacious ? root.padX : canvas.pad)) / canvas.sx + root.row.bounds.x,
            (y - (root.spacious ? root.padY : canvas.pad)) / canvas.sy + root.row.bounds.y, root.focusedAddress) : null;
        }
        onPressed: function(event) {
          if (!root.row) return;
          if (event.button === Qt.RightButton) {
            var target = hit(event.x, event.y);
            pressedAddress = target ? target.address : "";
            startX = event.x; startY = event.y;
            draggingMap = false;
            return;
          }
          var position = mapToItem(flick, event.x, event.y);
          var along = root.row.vertical ? position.y : position.x;
          root.revealAddress = "";
          draggingMap = !root.live && (event.button === Qt.MiddleButton || !hit(event.x, event.y));
          lastPosition = along; lastX = position.x; lastY = position.y; startX = event.x; startY = event.y;
          frozenScale = root.row.vertical ? canvas.sy : canvas.sx;
          var window = hit(event.x, event.y); pressedAddress = window ? window.address : "";
        }
        onPositionChanged: function(event) {
          if (!root.row) return;
          var position = mapToItem(flick, event.x, event.y);
          var along = root.row.vertical ? position.y : position.x;
          if (pressed && draggingMap) {
          if (root.fixedLane && root.fitToWidth) {
              flick.contentX = Math.max(0, Math.min(flick.contentWidth - flick.width, flick.contentX - (position.x - lastX)));
              flick.contentY = 0;
              lastX = position.x;
            } else if (root.spacious) {
              flick.contentX = Math.max(0, Math.min(flick.contentWidth - flick.width, flick.contentX - (position.x - lastX)));
              flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, flick.contentY - (position.y - lastY)));
              lastX = position.x; lastY = position.y;
            } else if (root.row.vertical) flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, flick.contentY - (along - lastPosition)));
            else flick.contentX = Math.max(0, Math.min(flick.contentWidth - flick.width, flick.contentX - (along - lastPosition)));
            lastPosition = along;
          } else {
            var window = hit(event.x, event.y); root.hoveredAddress = window ? window.address : "";
          }
        }
        onReleased: function(event) {
          if (event.button === Qt.RightButton && pressedAddress
              && Math.abs(event.x - startX) + Math.abs(event.y - startY) < 8)
            root.windowMenuRequested(pressedAddress, mouse.mapToItem(null, event.x, event.y));
          if (!draggingMap && event.button === Qt.LeftButton
            && Math.abs(event.x - startX) + Math.abs(event.y - startY) < 8 && pressedAddress)
            root.activated(pressedAddress);
          draggingMap = false;
        }
        onCanceled: { draggingMap = false; }
        onExited: root.hoveredAddress = ""
        onWheel: function(event) {
          root.revealAddress = "";
          var pixels = event.pixelDelta.x || event.pixelDelta.y;
          var delta = pixels || (event.angleDelta.x || event.angleDelta.y) / 120 * 180;
          var oldX = flick.contentX;
          if (((event.modifiers & Qt.ControlModifier) || root.externalControl) && !root.live) root.changeZoom(delta > 0 ? 1.2 : 1 / 1.2, event.x - flick.contentX, event.y - flick.contentY);
          else if (root.live && root.canPan) root.panned(-delta);
          else if (root.fitToWidth) flick.contentX = Math.max(0, Math.min(flick.contentWidth - flick.width, flick.contentX - delta));
          else if (root.row && root.row.vertical) flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, flick.contentY - delta));
          else flick.contentX = Math.max(0, Math.min(flick.contentWidth - flick.width, flick.contentX - delta));
          // At fit or a browse edge, let the surrounding workspace list scroll.
          event.accepted = !!(((event.modifiers & Qt.ControlModifier) || root.externalControl) && !root.live)
            || !!(root.live && root.canPan) || flick.contentX !== oldX;
        }
        QQC.ToolTip {
          id: tooltip
          objectName: "map-window-tooltip"
          visible: mouse.containsMouse && root.hoveredAddress !== "" && !mouse.pressed
          delay: 450
          text: {
            if (!root.row) return "";
            var window = root.row.windows.find(function(w) { return w.address === root.hoveredAddress; });
            return window ? window.title + "\n" + window.monitor + " · " + (window.inView ? (window.visible ? "In current view" : "Within viewport · covered or grouped") : "Outside current view") : "";
          }
          contentItem: Text {
            text: tooltip.text
            textFormat: Text.PlainText
            color: root.foreground
            font { family: Theme.fontFamily; pixelSize: 12 }
          }
          background: Rectangle { color: root.background; radius: 5; border.color: Theme.borderStrong }
        }
      }
    }
  }
}
