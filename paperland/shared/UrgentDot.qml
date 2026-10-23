import QtQuick
import ".." as Paper

// The one attention-mark shape: a small filled dot in the urgent hue with a
// fixed dark ring, so it separates from every fill it can sit on (purple
// pills, light bar themes, white thumbnails). Static by contract — no
// animation, and never the focused window's mark. Two sizes: 8 px on cards,
// rows and floating chips with a 1.5 px ring, and 6 px on pill badges with a
// 1 px ring so the urgent core stays 4 px wide.
Rectangle {
  id: dot
  property real diameter: 8
  // Set only where no accessible parent conveys the state, such as a map's
  // vector fallback, which has no accessible card item at all.
  property string accessName: ""
  width: diameter
  height: diameter
  radius: diameter / 2
  color: Paper.Theme.urgent
  border.color: "#111111"
  border.width: diameter < 8 ? 1 : 1.5
  Accessible.role: Accessible.StaticText
  Accessible.name: accessName
  Accessible.ignored: accessName === ""
}
