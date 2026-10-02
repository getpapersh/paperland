pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes

Item {
  id: root
  property string address: ""
  property url thumbnailSource
  property url iconSource
  // App name shown beside the fallback icon; empty keeps the compact
  // icon-only fallback used by the compact strips.
  property string label: ""
  property color foreground: "#dddddd"
  property color labelColor: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.72)
  property color cornerColor: "#222222"
  property string fontFamily: "sans-serif"
  property real imageOpacity: 1
  property bool cover: false
  property bool showCachedBadge: true
  property real cornerRadius: 0
  property bool captureEnabled: false
  // The host supplies its clipping viewport in this slot's local coordinates.
  property rect viewport: Qt.rect(0, 0, width, height)
  readonly property bool intersectsViewport: width > 0 && height > 0
    && viewport.width > 0 && viewport.height > 0
    && viewport.x < width && viewport.y < height
    && viewport.x + viewport.width > 0 && viewport.y + viewport.height > 0
  readonly property bool capturing: loader.active
  readonly property bool hasContent: loader.item ? (loader.item as ThumbnailContent).hasContent : false
  readonly property bool cached: loader.item ? (loader.item as ThumbnailContent).cached : false
  readonly property real aspectRatio: loader.item ? (loader.item as ThumbnailContent).aspectRatio : 0
  readonly property double capturedAt: loader.item ? (loader.item as ThumbnailContent).capturedAt : 0
  clip: true
  Shape {
    id: corners
    objectName: "thumbnail-cover-corners"
    anchors.fill: parent
    visible: root.cover && root.cornerRadius > 0
    readonly property real r: Math.min(root.cornerRadius, root.width / 2, root.height / 2)
    ShapePath {
      fillColor: root.cornerColor; strokeWidth: 0; startX: 0; startY: 0
      PathLine { x: corners.r; y: 0 }
      PathCubic { x: 0; y: corners.r; control1X: corners.r * 0.448; control1Y: 0; control2X: 0; control2Y: corners.r * 0.448 }
      PathLine { x: 0; y: 0 }
    }
    ShapePath {
      fillColor: root.cornerColor; strokeWidth: 0; startX: root.width; startY: 0
      PathLine { x: root.width - corners.r; y: 0 }
      PathCubic { x: root.width; y: corners.r; control1X: root.width - corners.r * 0.448; control1Y: 0; control2X: root.width; control2Y: corners.r * 0.448 }
      PathLine { x: root.width; y: 0 }
    }
    ShapePath {
      fillColor: root.cornerColor; strokeWidth: 0; startX: 0; startY: root.height
      PathLine { x: corners.r; y: root.height }
      PathCubic { x: 0; y: root.height - corners.r; control1X: corners.r * 0.448; control1Y: root.height; control2X: 0; control2Y: root.height - corners.r * 0.448 }
      PathLine { x: 0; y: root.height }
    }
    ShapePath {
      fillColor: root.cornerColor; strokeWidth: 0; startX: root.width; startY: root.height
      PathLine { x: root.width - corners.r; y: root.height }
      PathCubic { x: root.width; y: root.height - corners.r; control1X: root.width - corners.r * 0.448; control1Y: root.height; control2X: root.width; control2Y: root.height - corners.r * 0.448 }
      PathLine { x: root.width; y: root.height }
    }
  }
  Loader {
    id: loader
    anchors.fill: parent
    opacity: root.imageOpacity
    active: root.captureEnabled && root.visible && root.intersectsViewport && root.thumbnailSource.toString() !== ""
    source: root.thumbnailSource
  }
  Binding {
    target: loader.item
    property: "address"
    value: root.address
    when: !!loader.item
  }
  Binding {
    target: loader.item
    property: "cover"
    value: root.cover
    when: !!loader.item
  }
  Binding {
    target: loader.item
    property: "showCachedBadge"
    value: root.showCachedBadge
    when: !!loader.item
  }
  // Large centred fallback for preview cards without a frame.
  Column {
    id: fallback
    readonly property int iconSize: root.height >= 120 ? 48 : 32
    anchors.centerIn: parent
    anchors.verticalCenterOffset: -parent.height * 0.05
    spacing: 8
    visible: !root.hasContent && root.label !== "" && root.width >= 44
    Image {
      anchors.horizontalCenter: parent.horizontalCenter
      width: fallback.iconSize
      height: fallback.iconSize
      source: root.iconSource
      sourceSize: Qt.size(96, 96)
      fillMode: Image.PreserveAspectFit
      opacity: root.imageOpacity
      visible: root.iconSource.toString() !== ""
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      width: Math.min(implicitWidth, root.width - 16)
      visible: fallback.iconSize >= 48 && text !== ""
      text: root.label
      textFormat: Text.PlainText
      elide: Text.ElideRight
      horizontalAlignment: Text.AlignHCenter
      color: root.labelColor
      font { family: root.fontFamily; pixelSize: 13; weight: Font.DemiBold }
    }
  }
  // Compact icon-only fallback for the minimap and tiny slots.
  Image {
    anchors.centerIn: parent
    width: Math.min(24, parent.width)
    height: Math.min(24, parent.height)
    source: root.iconSource
    sourceSize: Qt.size(32, 32)
    fillMode: Image.PreserveAspectFit
    opacity: root.imageOpacity
    visible: !root.hasContent && root.label === ""
  }
}
