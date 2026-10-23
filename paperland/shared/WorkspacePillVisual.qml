import QtQuick
import "PillColumn.js" as PillColumn

// The painted desktop pill for a bar cell: the highlight, the scratchpad-open outline
// and the label row; children declared on it join that row after the label. A capsule on horizontal bars, a rounded rectangle filling the slab on
// vertical ones. The fade sits here because the button that hosts it owns its own opacity.
Item {
  id: root
  property var entry: null
  property bool vertical: false
  property bool scratchpadShown: false
  property color color: entry && entry.active ? "#a55eab" : "transparent"
  property color foreground: "#dddddd"
  property string fontFamily: "sans-serif"
  property real fontSize: 12
  // Label parts, as WorkspaceLabel; a vertical bar never shows the name.
  property bool showId: true
  property bool showCount: true
  property bool showName: true
  property string title: ""
  property real maximumWidth: 180
  default property alias content: pillRow.data
  readonly property alias labelItem: label
  readonly property var shape: PillColumn.pillShape(vertical, width, height)
  opacity: scratchpadShown ? 0.55 : 1
  Rectangle {
    anchors.centerIn: parent
    width: root.shape.width
    height: root.shape.height
    radius: root.shape.radius
    color: root.color
    // The dashed outline replaces this border while the scratchpad is open, as on the
    // minimap's faded pill.
    border.width: root.entry && root.entry.focused && !root.scratchpadShown ? 1 : 0
    border.color: "#e4b0e8"
  }
  // Siblings bound to the highlight's exact geometry, not children of it: the outline must
  // trace the pill's real edge inside the bar's scene, where nesting it distorted the path.
  ScratchpadOutline {
    anchors.centerIn: parent
    width: root.shape.width
    height: root.shape.height
    visible: root.scratchpadShown && !root.vertical
  }
  ScratchpadOutlineRect {
    anchors.centerIn: parent
    width: root.shape.width
    height: root.shape.height
    visible: root.scratchpadShown && root.vertical
  }
  Row {
    id: pillRow
    anchors.centerIn: parent
    spacing: 8
    WorkspaceLabel {
      id: label
      anchors.verticalCenter: parent.verticalCenter
      width: implicitWidth
      // An empty label drops out of the row, so no gap is left before the icons.
      visible: implicitWidth > 0
      entry: root.entry
      showId: root.showId
      showCount: root.showCount
      showName: root.showName && !root.vertical
      title: root.title
      maximumWidth: root.maximumWidth
      foreground: root.entry && root.entry.active ? "white" : root.foreground
      fontFamily: root.fontFamily
      fontSize: root.fontSize
    }
  }
}
