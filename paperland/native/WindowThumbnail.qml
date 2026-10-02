pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import Quickshell.Wayland
import Quickshell.Hyprland
import "../shared" as Shared
import "../Layout.js" as Layout
import "../shared/PreviewGeometry.js" as PreviewGeometry

Shared.ThumbnailContent {
  id: root
  readonly property var toplevel: Hyprland.toplevels.values.find(function(window) {
    return "0x" + window.address.replace(/^0x/, "") === root.address;
  }) || null
  readonly property Toplevel handle: toplevel ? toplevel.wayland : null
  readonly property var snapshot: toplevel ? toplevel.lastIpcObject : null
  readonly property var cacheEntry: Runtime.thumbnails.entry(address, handle)
  readonly property bool liveContent: capture.item ? (capture.item as Shared.ThumbnailContent).hasContent : false
  property var sampleToken: null
  readonly property bool renderable: {
    if (!snapshot || !snapshot.at || !snapshot.size) return false;
    var monitor = Hyprland.monitors.values.find(function(m) { return m.lastIpcObject.id === root.snapshot.monitor; });
    if (!monitor) return false;
    // Hyprland 0.56.2 skips pending exports outside the owning monitor.
    // Release capture there; a detached snapshot can remain independently.
    return Layout.intersects({x: snapshot.at[0], y: snapshot.at[1], width: snapshot.size[0], height: snapshot.size[1]}, Layout.monitorRect(monitor.lastIpcObject));
  }
  onRenderableChanged: restart()
  hasContent: liveContent || cached
  cached: !liveContent && cachedImage.status === Image.Ready
  capturedAt: cacheEntry ? cacheEntry.capturedAt : 0
  aspectRatio: liveContent ? (capture.item as Shared.ThumbnailContent).aspectRatio
    : cached && cachedImage.sourceSize.height > 0 ? cachedImage.sourceSize.width / cachedImage.sourceSize.height : 0
  onHandleChanged: restart()
  Component.onCompleted: restart()
  Component.onDestruction: cancelSample()
  function cancelSample(): void {
    Runtime.thumbnails.cancel(sampleToken);
    sampleToken = null;
  }
  function restart(): void {
    cancelSample();
    capture.active = false;
    restartTimer.restart();
  }
  Timer {
    id: restartTimer
    interval: 0
    // A pending restart must die with its thumbnail's QML creation context.
    onTriggered: capture.active = !!root.handle && root.renderable
  }
  Loader {
    id: capture
    anchors.fill: parent
    active: false
    sourceComponent: Shared.ThumbnailContent {
      hasContent: view.hasContent
      aspectRatio: view.hasContent ? view.ratio : 0
      ScreencopyView {
        id: view
        anchors.centerIn: parent
        readonly property real ratio: sourceSize.height > 0 ? sourceSize.width / sourceSize.height : 1
        width: root.cover ? Math.max(parent.width, parent.height * ratio)
          : Math.min(parent.width, parent.height * ratio)
        height: width / ratio
        captureSource: root.handle
        // Keep the displayed frame while a context action can remove its source.
        live: !Runtime.sendMenu.opened
        paintCursor: false
        onHasContentChanged: { if (hasContent) sample(); }
        function sample(): void {
          if (!live || !hasContent || !root.renderable || root.sampleToken || width <= 0 || height <= 0) return;
          var dpr = Screen.devicePixelRatio;
          var target = PreviewGeometry.captureSize(width, height, dpr, Runtime.thumbnails.maxEdge);
          var size = Qt.size(target.width, target.height);
          var token = Runtime.thumbnails.begin(root.address, root.handle, Math.round(size.width * dpr), Math.round(size.height * dpr));
          if (!token) return;
          root.sampleToken = token;
          var started = view.grabToImage(function(result) {
            if (root.sampleToken !== token) return;
            root.sampleToken = null;
            Runtime.thumbnails.finish(token, result);
          }, size);
          if (!started) root.cancelSample();
        }
        Timer {
          interval: 250
          running: view.hasContent
          repeat: true
          onTriggered: view.sample()
        }
        onStopped: {
          Runtime.thumbnails.invalidate(root.address, root.handle);
          root.cancelSample();
          capture.active = false;
        }
      }
    }
  }
  Image {
    id: cachedImage
    anchors.fill: parent
    source: !root.liveContent && root.cacheEntry ? root.cacheEntry.result.url : ""
    fillMode: root.cover ? Image.PreserveAspectCrop : Image.PreserveAspectFit
    cache: false
    visible: root.cached
  }
  Rectangle {
    anchors { right: parent.right; bottom: parent.bottom; margins: 3 }
    width: 19; height: 19; radius: 5
    color: "#d0202020"
    visible: root.cached && root.showCachedBadge
    readonly property string description: "Last captured: " + Qt.formatDateTime(new Date(root.capturedAt), "yyyy-MM-dd hh:mm:ss")
    Accessible.role: Accessible.StaticText
    Accessible.name: "Cached thumbnail. " + description
    Text { anchors.centerIn: parent; text: "⏱"; color: "white"; font.pixelSize: 14 }
    HoverHandler { id: hover }
    ToolTip.visible: hover.hovered
    ToolTip.delay: 500
    ToolTip.text: description
  }
}
