import QtQuick
import QtQuick.Controls as QQC

QQC.AbstractButton {
  id: root
  property string kind: "close"
  property bool selected: false
  property bool warning: false
  property string tooltipText: ""
  // Shown right of the glyph on a control wider than it is tall.
  property string label: ""
  // A move control stretched along its row: a filled bar rather than a bare glyph.
  readonly property bool bar: kind === "move" && width > height
  implicitWidth: 18
  implicitHeight: 18
  focusPolicy: Qt.NoFocus
  hoverEnabled: true
  Accessible.name: tooltipText
  background: Rectangle {
    radius: root.bar ? 5 : Math.min(width, height) / 2
    color: root.kind === "add" && root.selected ? (root.warning ? "#654825" : "#49344d") : root.bar ? "#3c3c3c" : root.kind === "move" || root.kind === "add" ? "transparent" : root.hovered || root.selected ? "#555555" : "#3c3c3c"
    border.color: root.kind === "add" && root.selected ? (root.warning ? "#e6aa4b" : "#a55eab") : !root.bar && (root.kind === "move" || root.kind === "add") ? "transparent" : "#555555"
    border.width: root.kind === "add" && root.selected ? 2 : 0.6
  }
  contentItem: Item {
    Canvas {
      id: glyph
      // Square, so a wide control keeps the glyph's proportions.
      width: height; height: parent.height
      x: root.label ? 0 : (parent.width - width) / 2
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()
      Connections { target: root; function onSelectedChanged() { glyph.requestPaint(); } function onHoveredChanged() { glyph.requestPaint(); } }
      onPaint: {
        var c = getContext("2d");
        c.clearRect(0, 0, width, height);
        c.save(); c.scale(width / 18, height / 18);
        c.strokeStyle = root.selected ? "#eeeeee" : "#aaaaaa";
        c.lineWidth = 1.3; c.lineCap = "round"; c.lineJoin = "round";
        c.beginPath();
        if (root.kind === "close") {
          c.moveTo(6, 6); c.lineTo(12, 12); c.moveTo(12, 6); c.lineTo(6, 12);
        } else if (root.kind === "collapse") {
          c.moveTo(5, root.selected ? 7 : 11); c.lineTo(9, root.selected ? 11 : 7); c.lineTo(13, root.selected ? 7 : 11);
        } else if (root.kind === "pin") {
          c.moveTo(6, 4); c.lineTo(12, 4); c.lineTo(11, 8); c.lineTo(13, 10); c.lineTo(5, 10); c.lineTo(7, 8); c.closePath();
          c.moveTo(9, 10); c.lineTo(9, 14);
          if (!root.selected) { c.moveTo(4, 3); c.lineTo(14, 15); }
        } else if (root.kind === "peek") {
          // A round pupil fills the lens at 18 logical pixels; the slit stays legible.
          c.moveTo(3, 9); c.bezierCurveTo(6, 4.5, 12, 4.5, 15, 9);
          c.bezierCurveTo(12, 13.5, 6, 13.5, 3, 9); c.closePath();
          c.moveTo(9, 7.2); c.lineTo(9, 10.8);
          if (!root.selected) { c.moveTo(4, 3); c.lineTo(14, 15); }
        } else if (root.kind === "settings") {
          c.arc(9, 9, 4.3, 0, 2 * Math.PI);
          for (var tooth = 0; tooth < 8; tooth++) {
            var angle = tooth * Math.PI / 4;
            c.moveTo(9 + 4.3 * Math.cos(angle), 9 + 4.3 * Math.sin(angle));
            c.lineTo(9 + 6.2 * Math.cos(angle), 9 + 6.2 * Math.sin(angle));
          }
          c.moveTo(11, 9); c.arc(9, 9, 2, 0, 2 * Math.PI);
        } else if (root.kind === "add") {
          // Creating a workspace is not one of the numbered pills: a dashed,
          // quieter ring keeps it legible without competing with them.
          c.strokeStyle = root.hovered ? "#b4b4b4" : "#7c7c7c";
          c.setLineDash([2.2, 2.2]);
          c.arc(9, 9, 8, 0, 2 * Math.PI);
          c.stroke();
          c.setLineDash([]);
          c.beginPath();
          c.moveTo(9, 5.5); c.lineTo(9, 12.5); c.moveTo(5.5, 9); c.lineTo(12.5, 9);
        } else if (root.kind === "move") {
          c.moveTo(3, 9); c.lineTo(15, 9); c.moveTo(9, 3); c.lineTo(9, 15);
          c.moveTo(5, 7); c.lineTo(3, 9); c.lineTo(5, 11);
          c.moveTo(13, 7); c.lineTo(15, 9); c.lineTo(13, 11);
          c.moveTo(7, 5); c.lineTo(9, 3); c.lineTo(11, 5);
          c.moveTo(7, 13); c.lineTo(9, 15); c.lineTo(11, 13);
        } else {
          c.arc(8, 8, 3.5, 0, 2 * Math.PI); c.moveTo(11, 11); c.lineTo(14, 14);
        }
        c.stroke(); c.restore();
      }
    }
    Text {
      visible: root.label !== ""
      x: glyph.width + 2
      anchors.verticalCenter: parent.verticalCenter
      text: root.label
      color: "#aaaaaa"
      font.pixelSize: 11
    }
  }
  QQC.ToolTip.visible: hovered && tooltipText !== ""
  QQC.ToolTip.text: tooltipText
  QQC.ToolTip.delay: 500
}
