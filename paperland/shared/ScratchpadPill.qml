import QtQuick

Item {
  id: root
  property var entry: null
  property bool open: false
  property bool pillEnabled: true
  property bool barStyle: false
  property real barHeight: 32
  // Horizontal pill rows (landscape minimap header, Omarchy bar) name the
  // pill; the portrait rail passes false and keeps the compact count label.
  property bool showName: false
  property var shortcutBinding: null
  property color accent: "#a55eab"
  property color foreground: "#c0c0c0"
  property string fontFamily: "sans-serif"
  property real fontSize: 11
  readonly property string accessibleName: label.accessibleName
  readonly property bool shown: pillEnabled && !!entry && (entry.count > 0 || open)
  implicitWidth: label.implicitWidth + 14
  implicitHeight: 18
  width: implicitWidth
  height: barStyle ? barHeight : implicitHeight
  visible: shown
  signal toggled()
  signal menuRequested(point position)

  Accessible.role: Accessible.Button
  Accessible.name: accessibleName
  Accessible.selected: open
  Accessible.onPressAction: root.toggled()

  Rectangle {
    id: background
    objectName: "scratchpad-background"
    anchors.centerIn: parent
    width: parent.width - (root.barStyle ? 4 : 0)
    height: root.barStyle ? Math.min(parent.height - 6, 26) : parent.height
    radius: height / 2
    color: root.open ? root.accent : root.entry && root.entry.count > 0 && !root.barStyle ? "#414141" : "transparent"
    border.width: root.open ? 1 : root.barStyle ? 0 : 1
    border.color: root.open ? root.accent : "#565656"
  }
  WorkspaceLabel {
    id: label
    objectName: "scratchpad-label"
    anchors.verticalCenter: background.verticalCenter
    anchors.left: root.barStyle ? undefined : background.left
    anchors.leftMargin: root.barStyle ? 0 : 7
    anchors.horizontalCenter: root.barStyle ? background.horizontalCenter : undefined
    entry: root.entry
    shortcutBinding: root.shortcutBinding
    specialName: root.showName
    foreground: root.open ? "white" : root.foreground
    fontFamily: root.fontFamily
    fontSize: root.fontSize
    maximumWidth: 180
  }
  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: function(event) {
      if (event.button === Qt.RightButton)
        root.menuRequested(mapToItem(null, event.x, event.y));
      else root.toggled();
    }
  }
}
