pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as QQC
import "WorkspaceCatalog.js" as Catalog

// Remove Desktop: pick where the windows go, confirm, then read the outcome.
// The counted windows and destination rows are fixed when the card opens, and the
// card keeps its own copy because the Desktop disappears while the card is showing.
FocusScope {
  id: root
  // Host tokens, like QuickMenu: the host draws the panel; the card only needs ink and accent.
  property color foreground: "#eeeeee"
  property color accent: "#a55eab"
  property color accentInk: "white"
  property int source: 0
  property var targets: []
  property var rows: []
  property int selectedIndex: -1
  property var entry: null
  property var allEntries: []
  // "choose", "working" or "result"
  property string stage: "choose"
  property var outcome: null
  readonly property var destination: selectedIndex >= 0 && rows[selectedIndex] ? rows[selectedIndex].destination : null
  readonly property int landing: destination && entry ? Catalog.removeLanding(entry, allEntries, destination) : 0
  readonly property var wording: Catalog.removeConfirmation(source, targets.length, destination ? destination.id : 0,
    entry && !targets.length ? Catalog.nearestOther(allEntries, entry) : landing)
  readonly property bool canRetry: stage === "result" && !!outcome && !outcome.ok && !!outcome.retry
  signal confirmed(int source, var destination, var targets)
  signal retryRequested()
  signal cancelled()
  implicitWidth: 420
  implicitHeight: content.implicitHeight
  /** @param {Object} desktop Catalog entry. @param {Object[]} all Catalog entries. @param {Object[]} destinations Native destination records. */
  function begin(desktop: var, all: var, destinations: var): void {
    entry = desktop; allEntries = all; source = desktop.id; targets = Catalog.removableWindows(desktop);
    var choices = Catalog.removeChoices(desktop, all, destinations);
    rows = choices.rows; selectedIndex = choices.defaultIndex;
    stage = "choose"; outcome = null;
    Qt.callLater(function() { confirmButton.forceActiveFocus(); });
  }
  // Try Again: the same removal, for every window now on the Desktop, to the same destination. When that
  // destination is gone the card stays in "choose" with the default preselected so the user decides.
  function retry(desktop: var, all: var, destinations: var): void {
    var keep = destination ? destination.id : 0;
    begin(desktop, all, destinations);
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].destination && rows[i].destination.id === keep) { selectedIndex = i; confirm(); return; }
    }
  }
  /** Start the removal through the service. A refusal (another move running) must not leave the card working.
   * @param {QtObject} service Provides removeDesktop(source, destination, targets). */
  function run(service: var): void {
    showWorking();
    if (!service.removeDesktop(source, destination, targets)) showResult(Catalog.removeBusyOutcome(source));
  }
  function showWorking(): void { stage = "working"; }
  function showResult(result: var): void {
    outcome = result; stage = "result";
    Qt.callLater(function() { (canRetry ? confirmButton : cancelButton).forceActiveFocus(); });
  }
  function move(step: int): void {
    if (stage !== "choose" || !targets.length) return;
    var i = selectedIndex;
    do { i += step; } while (i >= 0 && i < rows.length && rows[i].header);
    if (i >= 0 && i < rows.length) selectedIndex = i;
  }
  function confirm(): void {
    if (stage === "choose" && destination) confirmed(source, destination, targets);
    else if (canRetry) retryRequested();
    else if (stage === "result") cancelled();
  }
  // Enter is the default button, but never while Cancel holds focus.
  function accept(): void { if (cancelButton.activeFocus) cancelled(); else confirm(); }
  Keys.onEscapePressed: if (stage !== "working") cancelled()
  Keys.onReturnPressed: if (stage !== "working") accept()
  Keys.onEnterPressed: if (stage !== "working") accept()
  Keys.onUpPressed: move(-1)
  Keys.onDownPressed: move(1)
  Column {
    id: content
    anchors.left: parent.left; anchors.right: parent.right
    spacing: 12
    Text {
      objectName: "desktop-remove-title"
      text: root.stage === "result" && root.outcome ? root.outcome.title : root.stage === "working" ? "Removing Desktop " + root.source + "…" : root.wording.title
      color: root.foreground; font.pixelSize: 17; font.bold: true
    }
    Text {
      objectName: "desktop-remove-detail"
      // Busy and result text is announced as it changes; the title alone would hide the counts.
      Accessible.role: root.stage === "choose" ? Accessible.StaticText : Accessible.AlertMessage
      Accessible.name: (root.stage === "choose" ? "" : text)
      width: parent.width; wrapMode: Text.Wrap
      text: root.stage === "result" && root.outcome ? root.outcome.detail : root.stage === "working" ? "Moving windows. Nothing is closed." : root.wording.detail
      color: root.foreground; opacity: root.stage === "result" ? 0.85 : 0.7; font.pixelSize: 12
    }
    Column {
      id: list
      width: parent.width; spacing: 2
      visible: root.stage === "choose" && root.targets.length > 0
      Repeater {
        model: root.rows
        delegate: Item {
          id: row
          required property var modelData
          required property int index
          readonly property bool selected: root.selectedIndex === index
          objectName: modelData.header ? "desktop-remove-header-" + index : "desktop-remove-choice-" + modelData.destination.id
          width: list.width; height: modelData.header ? 24 : 34
          Accessible.role: modelData.header ? Accessible.StaticText : Accessible.RadioButton
          Accessible.name: modelData.header ? modelData.title : modelData.title + ", " + modelData.note
          Accessible.checked: selected
          Rectangle { anchors.fill: parent; radius: 5; visible: !row.modelData.header; color: row.selected ? Qt.alpha(root.accent, 0.28) : rowMouse.containsMouse ? Qt.alpha(root.foreground, 0.1) : "transparent" }
          Text { visible: !!row.modelData.header; x: 10; anchors.verticalCenter: parent.verticalCenter; text: row.modelData.title; color: root.foreground; opacity: 0.6; font.pixelSize: 11; font.bold: true }
          Row {
            visible: !row.modelData.header
            x: 10; anchors.verticalCenter: parent.verticalCenter; spacing: 10
            Rectangle {
              width: 14; height: 14; radius: 7; anchors.verticalCenter: parent.verticalCenter; color: "transparent"
              border.width: 2; border.color: row.selected ? root.accent : Qt.alpha(root.foreground, 0.5)
              Rectangle { anchors.centerIn: parent; width: 6; height: 6; radius: 3; color: root.accent; visible: row.selected }
            }
            Text { text: row.modelData.title; color: root.foreground; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter }
            Text { text: row.modelData.note || ""; color: root.foreground; opacity: 0.6; font.pixelSize: 12; anchors.verticalCenter: parent.verticalCenter }
          }
          MouseArea {
            id: rowMouse
            anchors.fill: parent; enabled: !row.modelData.header; hoverEnabled: true
            onClicked: root.selectedIndex = row.index
          }
        }
      }
    }
    Text {
      objectName: "desktop-remove-note"
      visible: root.stage === "choose" && root.targets.length > 0
      width: parent.width; wrapMode: Text.Wrap
      text: root.wording.note
      color: root.foreground; opacity: 0.7; font.pixelSize: 12
    }
    Row {
      spacing: 10
      visible: root.stage !== "working"
      QQC.Button {
        id: confirmButton
        objectName: "desktop-remove-confirm"
        visible: root.stage === "choose" || root.canRetry
        enabled: root.stage === "choose" ? !!root.destination : true
        text: root.stage === "result" ? "Try Again" : root.wording.confirm
        onClicked: root.confirm()
        contentItem: Text { text: confirmButton.text; color: root.accentInk; font.pixelSize: 13; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; opacity: confirmButton.enabled ? 1 : 0.5 }
        background: Rectangle { radius: 5; color: root.accent; opacity: confirmButton.enabled ? 1 : 0.4; border.width: 2; border.color: confirmButton.activeFocus ? root.foreground : "transparent"; implicitHeight: 32; implicitWidth: 90 }
      }
      QQC.Button {
        id: cancelButton
        objectName: "desktop-remove-cancel"
        text: root.stage === "result" ? "Close" : "Cancel"
        onClicked: root.cancelled()
        contentItem: Text { text: cancelButton.text; color: root.foreground; font.pixelSize: 13; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
        background: Rectangle { radius: 5; color: Qt.alpha(root.foreground, 0.12); border.width: 2; border.color: cancelButton.activeFocus ? root.foreground : "transparent"; implicitHeight: 32; implicitWidth: 90 }
      }
    }
  }
}
