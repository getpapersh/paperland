import QtQuick
import QtQuick.Shapes

// The dashed accent outline marking the active desktop pill while the scratchpad
// is open on its display; shared by the minimap and bar pill rows. Fill this
// Shape with the pill's visual rectangle. Both pills are stadiums, so the path
// takes its radii from the Shape's own height; the stroke insets half a logical
// px to stay inside the pill and the arcs follow its rounded ends. Deriving the
// geometry only from width and height keeps the path independent of any
// consumer-set property, which misrendered in the bar's scene.
Shape {
  id: outline
  objectName: "active-workspace-scratchpad-outline"
  property color accent: "#a55eab"
  z: 2
  ShapePath {
    strokeColor: outline.accent
    strokeWidth: 1
    strokeStyle: ShapePath.DashLine
    dashPattern: [3, 2]
    fillColor: "transparent"
    startX: outline.height / 2; startY: 0.5
    PathLine { x: outline.width - outline.height / 2; y: 0.5 }
    PathArc {
      x: outline.width - outline.height / 2; y: outline.height - 0.5
      radiusX: outline.height / 2 - 0.5; radiusY: outline.height / 2 - 0.5
      direction: PathArc.Clockwise
    }
    PathLine { x: outline.height / 2; y: outline.height - 0.5 }
    PathArc {
      x: outline.height / 2; y: 0.5
      radiusX: outline.height / 2 - 0.5; radiusY: outline.height / 2 - 0.5
      direction: PathArc.Clockwise
    }
  }
}
