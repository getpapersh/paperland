pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Hyprland

QtObject {
  id: root
  property bool leftPressed: false
  property bool rightPressed: false
  readonly property bool pressed: leftPressed || rightPressed

  // Explicit Lua dispatches can signal either edge; the shortcut name carries
  // the state so release after another Ctrl chord cannot leave a key stuck.
  property GlobalShortcut leftDown: GlobalShortcut {
    appid: "paperland-preview"; name: "37-1"
    onPressed: root.leftPressed = true
    onReleased: root.leftPressed = true
  }
  property GlobalShortcut leftUp: GlobalShortcut {
    appid: "paperland-preview"; name: "37-0"
    onPressed: root.leftPressed = false
    onReleased: root.leftPressed = false
  }
  property GlobalShortcut rightDown: GlobalShortcut {
    appid: "paperland-preview"; name: "105-1"
    onPressed: root.rightPressed = true
    onReleased: root.rightPressed = true
  }
  property GlobalShortcut rightUp: GlobalShortcut {
    appid: "paperland-preview"; name: "105-0"
    onPressed: root.rightPressed = false
    onReleased: root.rightPressed = false
  }
}
