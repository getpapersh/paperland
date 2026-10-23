import QtQuick
import QtQuick.Shapes
import "PillColumn.js" as PillColumn

// The dashed accent outline for the rounded-rectangle pill on vertical bars; the
// capsule's twin is ScratchpadOutline. The radius comes from the shared geometry,
// not from a consumer-set property, so the path depends only on width and height.
Shape {
  id: outline
  objectName: "active-workspace-scratchpad-outline"
  property color accent: "#a55eab"
  readonly property real corner: Math.min(PillColumn.VERTICAL_PILL_RADIUS, height / 2)
  z: 2
  ShapePath {
    strokeColor: outline.accent
    strokeWidth: 1
    strokeStyle: ShapePath.DashLine
    dashPattern: [3, 2]
    fillColor: "transparent"
    startX: outline.corner; startY: 0.5
    PathLine { x: outline.width - outline.corner; y: 0.5 }
    PathArc {
      x: outline.width - 0.5; y: outline.corner
      radiusX: outline.corner - 0.5; radiusY: outline.corner - 0.5
      direction: PathArc.Clockwise
    }
    PathLine { x: outline.width - 0.5; y: outline.height - outline.corner }
    PathArc {
      x: outline.width - outline.corner; y: outline.height - 0.5
      radiusX: outline.corner - 0.5; radiusY: outline.corner - 0.5
      direction: PathArc.Clockwise
    }
    PathLine { x: outline.corner; y: outline.height - 0.5 }
    PathArc {
      x: 0.5; y: outline.height - outline.corner
      radiusX: outline.corner - 0.5; radiusY: outline.corner - 0.5
      direction: PathArc.Clockwise
    }
    PathLine { x: 0.5; y: outline.corner }
    PathArc {
      x: outline.corner; y: 0.5
      radiusX: outline.corner - 0.5; radiusY: outline.corner - 0.5
      direction: PathArc.Clockwise
    }
  }
}
