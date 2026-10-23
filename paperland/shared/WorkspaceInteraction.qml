pragma Singleton
import QtQuick

QtObject {
  id: root
  property var host: null
  property var anchor: null
  property var workspace: 0
  property string mode: ""
  property bool held: false
  property bool cardHovered: false
  property bool blockedUntilEntry: false
  property var blockedAnchor: null
  // The item the pointer last entered and has not left. The bar widget's relocation recovery
  // re-enters a pill on motion only when this is not that pill, so motion after a click does
  // not reopen the preview the click closed.
  property Item pointerAnchor: null
  readonly property bool opened: mode !== ""
  // Whether an open preview, menu or editor is anchored to this item. A vertical-bar pill hides
  // its tooltip while this holds, since the tooltip would draw over that popup.
  function owns(item: Item): bool { return opened && anchor === item; }
  // A relocated bar can leave a resting pointer on its pill with no leave, and the item would
  // then stay remembered and block the recovery that re-enters it.
  function forgetPointer(): void { pointerAnchor = null; }
  property Timer dwell: Timer { interval: 180; onTriggered: if (root.host && root.host.canPreview()) root.mode = "hover"; }
  property Timer dismiss: Timer { interval: 150; onTriggered: if (!root.held && !root.cardHovered && root.mode === "hover") root.close(); }
  onHeldChanged: {
    if (held) { dwell.stop(); dismiss.stop(); }
    else if (mode === "hover" && !cardHovered) dismiss.restart();
  }
  function enter(owner, item, id) {
    pointerAnchor = item;
    dismiss.stop();
    if (opened && mode !== "hover") return;
    if (blockedUntilEntry && blockedAnchor === item) return;
    blockedUntilEntry = false; blockedAnchor = null;
    if (!owner.canPreview()) return;
    var visible = mode === "hover";
    host = owner; anchor = item; workspace = id;
    if (!visible) dwell.restart();
  }
  function leave(owner, item) {
    if (pointerAnchor === item) pointerAnchor = null;
    if (blockedAnchor === item) { blockedUntilEntry = false; blockedAnchor = null; }
    if (host !== owner || anchor !== item) return;
    dwell.stop();
    if (mode === "hover" && !held) dismiss.restart();
  }
  function card(value) {
    cardHovered = value;
    if (value) dismiss.stop();
    else if (mode === "hover" && !held) dismiss.restart();
  }
  function explicitOpen(owner, item, id, nextMode) {
    dwell.stop(); dismiss.stop();
    host = owner; anchor = item; workspace = id; mode = nextMode;
    blockedUntilEntry = true; blockedAnchor = anchor;
  }
  function close() {
    var explicit = mode !== "" && mode !== "hover";
    dwell.stop(); dismiss.stop(); mode = ""; cardHovered = false; held = false;
    blockedUntilEntry = explicit; blockedAnchor = explicit ? anchor : null;
  }
}
