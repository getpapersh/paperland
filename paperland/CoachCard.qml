pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts

// One First Flow lesson card; the host observes native state and advances it.
Item {
  id: root
  property string title: ""
  property string instruction: ""
  property var keys: []
  property int position: 1
  property int total: 3
  property string feedback: ""
  // Empty hides the cold-start jump button.
  property string jumpLabel: ""
  signal skipped()
  signal closed()
  signal jumpRequested()
  implicitWidth: 400
  implicitHeight: content.implicitHeight + 32
  Accessible.role: Accessible.Pane
  Accessible.name: title
  Rectangle {
    anchors.fill: parent
    radius: 12
    color: Theme.surfaceRaised
    border.color: root.feedback ? Theme.accent : Theme.borderStrong
  }
  ColumnLayout {
    id: content
    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 16 }
    spacing: 10
    RowLayout {
      Layout.fillWidth: true
      Text {
        Layout.fillWidth: true
        text: root.title
        elide: Text.ElideRight
        color: Theme.textPrimary
        font { family: Theme.fontFamily; pixelSize: 15; bold: true }
      }
      Button { objectName: "coach-close"; text: "×"; tooltipText: "Close tutorial"; verticalPadding: 2; onClicked: root.closed() }
    }
    Text {
      Layout.fillWidth: true
      text: root.instruction
      wrapMode: Text.Wrap
      color: Theme.textSecondary
      font { family: Theme.fontFamily; pixelSize: 12 }
    }
    Row {
      visible: root.keys.length > 0
      spacing: 4
      Repeater {
        model: root.keys
        delegate: Rectangle {
          required property string modelData
          width: Math.max(26, cap.implicitWidth + 14)
          height: 24
          radius: 5
          color: Theme.surfaceControl
          border.color: Theme.borderStrong
          Text {
            id: cap
            anchors.centerIn: parent
            text: parent.modelData
            color: Theme.textPrimary
            font { family: Theme.fontFamily; pixelSize: 12 }
          }
        }
      }
    }
    Text {
      objectName: "coach-feedback"
      visible: root.feedback !== ""
      text: root.feedback
      color: Theme.accent
      font { family: Theme.fontFamily; pixelSize: 15; bold: true }
      Accessible.role: Accessible.AlertMessage
      Accessible.name: text
    }
    RowLayout {
      Layout.fillWidth: true
      spacing: 6
      Text {
        objectName: "coach-progress"
        text: "Step " + root.position + " of " + root.total
        color: Theme.textTertiary
        font { family: Theme.fontFamily; pixelSize: 11 }
      }
      Repeater {
        model: root.total
        delegate: Rectangle {
          required property int index
          width: 6; height: 6; radius: 3
          color: index < root.position ? Theme.accent : Theme.borderStrong
        }
      }
      Item { Layout.fillWidth: true }
      Button { objectName: "coach-jump"; visible: root.jumpLabel !== ""; text: root.jumpLabel; fontSize: 11; verticalPadding: 4; onClicked: root.jumpRequested() }
      Button { objectName: "coach-skip"; text: "Skip"; fontSize: 11; verticalPadding: 4; onClicked: root.skipped() }
    }
  }
}
