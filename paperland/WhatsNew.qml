import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import "WhatsNew.js" as Logic

Item {
  id: root
  property var releases: []
  property bool opened: false
  // Automatic display must not take typing from the focused application; a
  // press inside the window, or on-demand opening, makes it focusable. It is
  // never exclusive, so focusing another window takes the keyboard back.
  property bool takeFocus: false
  property var targetScreen: null

  /** Show releases newer than lastSeen at startup; returns the version to save as last seen. */
  function showUnseen(lastSeen: string): string {
    var currentVersion = versionFile.text().trim();
    if (Logic.parseVersion(currentVersion) === null) {
      console.warn("Paperland: version.txt is missing or not a version; What's New disabled");
      return lastSeen;
    }
    present(Logic.unseen(Logic.parseNotes(notesFile.text()), lastSeen, currentVersion), false);
    return currentVersion;
  }
  /** Show the full history on demand; false when there is nothing to show. */
  function showHistory(): bool {
    return present(Logic.history(Logic.parseNotes(notesFile.text()), versionFile.text().trim()), true);
  }
  function present(list: var, focus: bool): bool {
    if (!list.length) return false;
    // Reuse an open window, but show what was asked for: history replaces upgrade notes.
    releases = list;
    if (!opened) {
      targetScreen = Quickshell.screens.find(function(screen) {
        return Hyprland.focusedMonitor && screen.name === Hyprland.focusedMonitor.name;
      }) || Quickshell.screens[0] || null;
    }
    // takeFocus only records eligibility; another window may hold the keyboard now.
    if (focus && opened) {
      claimFocus();
      return true;
    }
    if (focus) takeFocus = true;
    opened = true;
    return true;
  }
  /** Hyprland grants an on-demand layer the keyboard when it maps, not when its
   * interactivity changes, so remap the open window to hand it focus. */
  function claimFocus(): void {
    opened = false;
    takeFocus = true;
    Qt.callLater(function() { root.opened = true; });
  }
  function close(): void { opened = false; takeFocus = false; }

  // blockLoading makes text() wait for the read; a missing file reads as "".
  FileView { id: versionFile; path: Quickshell.shellPath("version.txt"); blockLoading: true; printErrors: false }
  FileView { id: notesFile; path: Quickshell.shellPath("release-notes.json"); blockLoading: true; printErrors: false }

  PanelWindow {
    screen: root.targetScreen
    visible: root.opened
    // No anchors: the compositor centers the surface on its display.
    // Logical pixels, with a 16-pixel margin on each side of a small display.
    implicitWidth: Math.min(480, root.targetScreen ? root.targetScreen.width - 32 : 480)
    implicitHeight: Math.min(520, root.targetScreen ? root.targetScreen.height - 32 : 520)
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "paperland-whats-new"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: !root.opened ? WlrKeyboardFocus.None
      : root.takeFocus ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    WhatsNewPanel {
      id: panel
      anchors.fill: parent
      focus: true
      releases: root.releases
      onDismissed: root.close()
    }
    // Automatic display starts without the keyboard. The first click above the
    // footer claims it, like click-to-focus; "Got it" stays a single click.
    MouseArea {
      anchors { fill: parent; bottomMargin: panel.footerHeight }
      enabled: !root.takeFocus
      onClicked: root.claimFocus()
    }
  }
}
