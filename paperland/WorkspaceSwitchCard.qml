pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import "SwitchCard.js" as SwitchCard

// Confirms where a workspace switch landed with a brief card on the display
// that changed. Decides from settled monitor snapshots, not raw events, so a
// Paperland action that focuses another workspace and returns within one
// compositor call never shows a card.
Scope {
  id: root
  property bool showCards: true
  // Last workspace ID per display.
  property var baseline: ({})
  readonly property var snapshot: SwitchCard.displays(
    Hyprland.monitors.values.map(function(m) { return m.lastIpcObject; }))
  // Per-screen card windows, for native checks; Scope children are not enumerable.
  readonly property alias windows: cards.instances
  signal flash(string monitor, string headline, string subtitle)
  signal dismiss(string monitor)

  onSnapshotChanged: apply()
  Component.onCompleted: apply()
  function apply(): void {
    var result = SwitchCard.plan(baseline, snapshot);
    baseline = result.baseline;
    result.actions.forEach(function(action) {
      if (action.kind === "hide") root.dismiss(action.monitor);
      else if (root.showCards) root.flash(action.monitor, action.headline, action.subtitle);
    });
  }

  Variants {
    id: cards
    model: Quickshell.screens
    PanelWindow {
      id: window
      required property ShellScreen modelData
      screen: modelData
      visible: view.active
      color: "transparent"
      implicitWidth: view.implicitWidth
      implicitHeight: view.implicitHeight
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "paperland-switch-card"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      // A confirmation must never take clicks meant for the window beneath.
      mask: Region {}
      SwitchCardView {
        id: view
        maxWidth: Math.max(120, Math.min(window.modelData.width - 80, 560))
      }
      Connections {
        target: root
        function onFlash(monitor, headline, subtitle) {
          if (monitor === window.modelData.name) view.show(headline, subtitle);
        }
        function onDismiss(monitor) {
          if (monitor === window.modelData.name) view.hide();
        }
      }
    }
  }
}
