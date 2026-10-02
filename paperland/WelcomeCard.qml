import QtQuick
import QtQuick.Layouts

// PaperMac's welcome window content; the host decides where it appears.
FocusScope {
  id: root
  // Rows from Onboarding.shortcutRows().
  property var rows: []
  signal skipped()
  signal started()
  implicitWidth: 460
  implicitHeight: content.implicitHeight + 40
  Keys.onEscapePressed: root.skipped()
  Accessible.role: Accessible.Dialog
  Accessible.name: "Welcome to Paperland"
  Rectangle {
    anchors.fill: parent
    radius: 12
    color: Theme.surfaceRaised
    border.color: Theme.borderStrong
  }
  ColumnLayout {
    id: content
    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 20 }
    spacing: 12
    Text {
      text: "Welcome to Paperland"
      color: Theme.textPrimary
      font { family: Theme.fontFamily; pixelSize: 20; bold: true }
    }
    Text {
      Layout.fillWidth: true
      text: "A minimap and search for Hyprland's scrolling canvas — see every Desktop's strip at a glance and flow through it with the keyboard."
      wrapMode: Text.Wrap
      color: Theme.textSecondary
      font { family: Theme.fontFamily; pixelSize: 13 }
    }
    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }
    Text {
      text: "Shortcut style"
      color: Theme.textPrimary
      font { family: Theme.fontFamily; pixelSize: 13; bold: true }
    }
    Repeater {
      model: root.rows
      delegate: RowLayout {
        id: row
        required property var modelData
        Layout.fillWidth: true
        spacing: 4
        objectName: "welcome-row-" + modelData.id
        Accessible.role: Accessible.StaticText
        Accessible.name: modelData.label + ", " + (modelData.keys.length ? modelData.keys.join(" ") : modelData.hint)
        Text {
          Layout.fillWidth: true
          text: row.modelData.label
          elide: Text.ElideRight
          color: Theme.textSecondary
          font { family: Theme.fontFamily; pixelSize: 12 }
        }
        Repeater {
          model: row.modelData.keys
          delegate: Rectangle {
            required property string modelData
            implicitWidth: Math.max(24, cap.implicitWidth + 12)
            implicitHeight: 22
            radius: 5
            color: Theme.surfaceControl
            border.color: Theme.borderStrong
            Text {
              id: cap
              anchors.centerIn: parent
              text: parent.modelData
              color: Theme.textPrimary
              font { family: Theme.fontFamily; pixelSize: 11 }
            }
          }
        }
        Text {
          visible: row.modelData.keys.length === 0
          text: row.modelData.hint
          color: Theme.textTertiary
          font { family: Theme.fontFamily; pixelSize: 11; italic: true }
        }
      }
    }
    Text {
      Layout.fillWidth: true
      text: "Change these any time: run paperland setup in a terminal."
      wrapMode: Text.Wrap
      color: Theme.textTertiary
      font { family: Theme.fontFamily; pixelSize: 11 }
    }
    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }
    RowLayout {
      Layout.fillWidth: true
      Button { objectName: "welcome-skip"; text: "Skip setup"; focusable: true; fontSize: 12; onClicked: root.skipped() }
      Item { Layout.fillWidth: true }
      Button { objectName: "welcome-start"; text: "Start Flowing"; focusable: true; focus: true; selected: true; onClicked: root.started() }
    }
  }
}
