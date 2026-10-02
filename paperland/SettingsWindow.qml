pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import "native" as Native
import "SettingsSearch.js" as SettingsSearch

Item {
  id: root
  required property Service service
  required property var savedPreferences
  property var initialPreferences: ({})
  property bool confirmClose: false
  property bool closeAfterSave: false
  property bool saveRequested: false
  property bool saveFailed: false
  property string stagedBlur: "keep"
  readonly property bool hasRuntimeDraft: Object.keys(initialPreferences).some(function(key) {
    return root.runtimeValues()[key] !== root.initialPreferences[key];
  })
  property bool opened: false
  property var targetScreen: null
  property int peekSeconds: 3
  property bool peekEnabled: false
  property bool pinned: true
  property string opacityMode: "background"
  property int backgroundOpacity: 96
  property int entireOpacity: 100
  readonly property int opacityValue: opacityMode === "entire" ? entireOpacity : backgroundOpacity
  property bool overviewWindowList: true
  property int overviewDensity: 0
  property bool scratchpadFollow: true
  property string selectedSection: "Minimap"
  property string selectedCard: ""
  onSelectedSectionChanged: {
    selectedCard = "";
    clearPendingScroll();
    jumpOutline.visible = false;
  }
  property string query: ""
  property string currentAutostart: "off"
  property string stagedAutostart: "keep"
  property var currentSetup: ({})
  property string stagedShortcut: "keep"
  property string stagedResize: "keep"
  property string stagedCentering: "keep"
  property string stagedStripChord: "keep"
  property string stagedBarPanels: "keep"
  readonly property bool chordEnabled: (root.stagedStripChord === "keep" ? root.currentSetup.strip_chord : root.stagedStripChord) === "SUPER + CTRL"
  readonly property string effectiveBarPanels: root.stagedBarPanels === "keep" ? (root.currentSetup.bar_panels || "drop") : root.stagedBarPanels
  property string stagedBar: "keep"
  property string stagedBarScratchpad: "keep"
  property string stagedMonitorDirection: "keep"
  property var stagedMonitorOverrides: ({})
  property var stagedDesktopDirections: ({})
  property bool nativeApplyPending: false
  readonly property var monitors: Hyprland.monitors.values.map(function(monitor) { return monitor.lastIpcObject; })
  readonly property var desktops: {
    // Every tunable Desktop: the union of live positive IDs and saved positive
    // IDs. A saved choice whose Desktop is absent right now stays listed, and
    // its missing native state keeps reading as unconfirmed.
    var ids = ({});
    Hyprland.workspaces.values.forEach(function(workspace) {
      if (workspace.lastIpcObject.id > 0) ids[workspace.lastIpcObject.id] = true;
    });
    Object.keys(root.currentSetup.desktop_directions || {}).forEach(function(id) {
      var number = parseInt(id, 10);
      if (number > 0) ids[number] = true;
    });
    return Object.keys(ids).map(function(id) { return {id: parseInt(id, 10)}; })
      .sort(function(a, b) { return a.id - b.id; });
  }
  readonly property bool desktopBackendReady: currentSetup.native_direction_available === true
  readonly property bool hasStaged: hasRuntimeDraft || stagedBlur !== "keep" || stagedAutostart !== "keep" || stagedShortcut !== "keep"
    || stagedResize !== "keep" || stagedCentering !== "keep" || stagedStripChord !== "keep"
    || stagedBarPanels !== "keep" || stagedBar !== "keep" || stagedBarScratchpad !== "keep"
    || stagedMonitorDirection !== "keep" || Object.keys(stagedMonitorOverrides).length > 0
    || Object.keys(stagedDesktopDirections).length > 0
  readonly property bool stopBlocked: hasStaged || applyUnresolved || previewProcess.running || statusProcess.running
  property bool loadingCurrent: false
  property var reviewPlan: null
  property bool reviewOpen: false
  property string message: ""
  property string previewOutput: ""
  property string previewError: ""
  property string statusOutput: ""
  property string statusError: ""
  property bool reviewRequested: false
  property int statusPolls: 0
  property bool applyUnresolved: false
  // The Apply attempt this window is waiting on; empty when recovering on open.
  // It only routes receipts to the consent that produced them; it authorizes nothing.
  property string currentAttempt: ""
  readonly property var sections: ["Minimap", "Overview", "Displays", "Shortcuts", "Startup & Bar"]
  readonly property var searchEntries: SettingsSearch.entries()
  readonly property var searchResults: SettingsSearch.rank(searchEntries, query)
  property int resultIndex: -1
  property var pendingCard: null
  property var pendingScroll: null
  onQueryChanged: resultIndex = -1
  signal preferencesReloadRequested()

  function runtimeValues(): var {
    return {pinned: pinned, peek: peekEnabled, peekSeconds: peekSeconds,
      minimapOpacityMode: opacityMode, minimapBackgroundOpacity: backgroundOpacity,
      minimapEntireOpacity: entireOpacity, overviewWindowList: overviewWindowList,
      overviewDensity: overviewDensity, scratchpadFollow: scratchpadFollow};
  }
  function resetPreferences(): void {
    initialPreferences = Object.assign({}, savedPreferences);
    pinned = savedPreferences.pinned; peekEnabled = savedPreferences.peek;
    peekSeconds = savedPreferences.peekSeconds; opacityMode = savedPreferences.minimapOpacityMode;
    backgroundOpacity = savedPreferences.minimapBackgroundOpacity;
    entireOpacity = savedPreferences.minimapEntireOpacity;
    overviewWindowList = savedPreferences.overviewWindowList;
    overviewDensity = savedPreferences.overviewDensity; scratchpadFollow = savedPreferences.scratchpadFollow;
  }
  function discard(): void {
    if (applyUnresolved) return;
    stagedBlur = "keep";
    resetPreferences();
    // The write being discarded is resolved, so its error state clears with it;
    // the button is unreachable while an Apply is unresolved.
    saveFailed = false;
    applyUnresolved = true;
    finishStaged();
    reviewOpen = false;
    message = "Changes discarded.";
    restoreFocus();
  }
  function save(): void {
    if (applyUnresolved) return;
    saveFailed = false;
    saveRequested = true;
    requestReview();
  }
  function freshAttemptId(): string {
    // A fresh 32-character marker per consent, in the 16–64 lowercase hex interface
    // range. It identifies the attempt so old receipts cannot resolve it.
    var id = "";
    for (var i = 0; i < 32; i++) id += "0123456789abcdef"[Math.floor(Math.random() * 16)];
    return id;
  }

  component NumberBox: QQC.SpinBox {
    id: control
    implicitWidth: 92
    implicitHeight: 38
    editable: true
    contentItem: TextInput {
      text: control.displayText
      color: Theme.settingsColor("#d5ddf5")
      font.pixelSize: 13
      horizontalAlignment: Qt.AlignHCenter
      verticalAlignment: Qt.AlignVCenter
      readOnly: !control.editable
      validator: control.validator
      inputMethodHints: Qt.ImhDigitsOnly
      selectByMouse: true
    }
    background: Rectangle { radius: 7; color: Theme.settingsColor("#1b2234"); border.color: control.activeFocus ? Theme.settingsColor("#7b9aff") : Theme.settingsColor("#414c69") }
    up.indicator: Item {
      x: control.width - width; width: 25; height: control.height / 2
      Text { anchors.centerIn: parent; text: "⌃"; color: Theme.settingsColor("#c1ccec"); font.pixelSize: 16 }
    }
    down.indicator: Item {
      x: control.width - width; y: control.height / 2; width: 25; height: control.height / 2
      Text { anchors.centerIn: parent; text: "⌄"; color: Theme.settingsColor("#c1ccec"); font.pixelSize: 16 }
    }
  }

  function open(): void {
    Theme.refreshSettingsColors();
    targetScreen = Quickshell.screens.find(function(screen) {
      return Hyprland.focusedMonitor && screen.name === Hyprland.focusedMonitor.name;
    }) || Quickshell.screens[0] || null;
    if (!opened && !hasStaged) resetPreferences();
    opened = true;
    requestCurrent();
    requestStatus();
    Qt.callLater(function() { search.forceActiveFocus(); });
  }
  function close(): void {
    if (applyUnresolved) { opened = false; return; }
    if (hasStaged) { confirmClose = true; return; }
    opened = false; reviewOpen = false;
  }
  function restoreFocus(): void {
    // Disabled buttons and closed overlays drop keyboard focus; without this Escape stops working.
    Qt.callLater(function() { card.forceActiveFocus(); });
  }
  function moveResult(delta: int): void {
    if (!searchResults.length) return;
    resultIndex = resultIndex < 0 ? (delta > 0 ? 0 : searchResults.length - 1)
      : Math.max(0, Math.min(searchResults.length - 1, resultIndex + delta));
  }
  function openResult(result: var): void {
    // Clearing the query restores the section list; the jump waits for the section's geometry.
    selectedSection = result.section;
    search.text = "";
    Qt.callLater(function() { root.jumpTo(result); });
  }
  function activateResult(): void {
    if (!searchResults.length) return;
    openResult(searchResults[resultIndex < 0 ? 0 : resultIndex]);
  }
  function findItem(item: var, matches: var): var {
    if (!item || item.visible === false) return null;
    if (matches(item)) return item;
    var children = item.data || item.children || [];
    for (var i = 0; i < children.length; i++) {
      var found = findItem(children[i], matches);
      if (found) return found;
    }
    return null;
  }
  function scrollToTarget(target: var): void {
    var parent = target.parent;
    while (parent && (parent.contentY === undefined || parent.contentHeight === undefined)) parent = parent.parent;
    if (!parent) return;
    var position = target.mapToItem(parent.contentItem, 0, 0);
    parent.contentY = Math.max(0, Math.min(parent.contentHeight - parent.height,
      position.y + target.height / 2 - parent.height / 2));
  }
  function clearPendingScroll(): void {
    if (!pendingCard) return;
    pendingCard.yChanged.disconnect(pendingScroll);
    pendingCard = null;
    pendingScroll = null;
  }
  function jumpTo(result: var): void {
    // Only visible items qualify: focusing a hidden or clipped control would silently drop the jump.
    var target = null;
    if (result.control) target = findItem(contentCards, function(item) { return item.objectName === result.control; });
    else if (result.button) target = findItem(contentCards, function(item) { return typeof item.clicked === "function" && item.text === result.button; });
    else target = findItem(contentCards, function(item) { return item instanceof Text && item.font.bold && item.text === result.card; });
    if (!target) return;
    selectedCard = result.card;
    scrollToTarget(target);
    clearPendingScroll();
    // Outline the enclosing Settings card. Anchoring inside it tracks layout polish and scrolling,
    // so the frame stays on the card without copying geometry at jump time.
    var host = target;
    while (host && host.parent !== contentCards) host = host.parent;
    if (host) {
      jumpOutline.parent = host;
      jumpOutline.anchors.fill = host;
      jumpOutline.visible = true;
      // A section shown for the first time still carries pre-layout geometry when the jump runs,
      // so the first centering can clamp to zero. Re-center once from the settled position when
      // the card's y is actually assigned by the layout pass.
      pendingCard = host;
      pendingScroll = function() {
        clearPendingScroll();
        Qt.callLater(function() { root.scrollToTarget(target); });
      };
      host.yChanged.connect(pendingScroll);
      jumpFlash.restart();
    }
    target.forceActiveFocus();
  }
  function setupCommand(mode: string, token: string): var {
    var command = ["python3", Quickshell.shellPath("setup.py"), "setup",
      "--autostart", stagedAutostart, "--shortcut", stagedShortcut,
      "--resize", stagedResize, "--centering", stagedCentering,
      "--strip-chord", stagedStripChord, "--bar-panels", stagedBarPanels,
      "--omarchy-bar", stagedBar, "--omarchy-bar-scratchpad", stagedBarScratchpad,
      "--monitor-direction", stagedMonitorDirection, "--minimap-blur", stagedBlur];
    if (hasRuntimeDraft) {
      var selection = {}, baseline = {}, values = runtimeValues();
      Object.keys(initialPreferences).forEach(function(key) {
        if (values[key] !== root.initialPreferences[key]) {
          selection[key] = values[key]; baseline[key] = root.initialPreferences[key];
        }
      });
      command.push("--runtime-preferences", JSON.stringify(selection), "--runtime-baseline", JSON.stringify(baseline));
    }
    Object.keys(stagedMonitorOverrides).sort().forEach(function(name) {
      command.push("--monitor-direction-override", name + "=" + root.stagedMonitorOverrides[name]);
    });
    Object.keys(stagedDesktopDirections).sort().forEach(function(id) {
      command.push("--desktop-direction", id + "=" + root.stagedDesktopDirections[id]);
    });
    if (mode === "preview") command.push("--settings-preview");
    else if (mode === "apply") command.push("--settings-attempt", root.currentAttempt, "--settings-apply", token);
    return command;
  }
  function preferredBarPanels(): string {
    // The panel choice belongs to the enabled chord: keep a configured drop, or
    // a configured relocate where the Omarchy Bar exists. Otherwise drop, so a
    // standalone setup never binds Omarchy's panel commands.
    var saved = root.currentSetup.bar_panels;
    if (saved === "drop") return "drop";
    if (saved === "relocate" && root.currentSetup.bar_available === true) return "relocate";
    return "drop";
  }
  function directionChoice(kind: string, name: string): string {
    var staged = kind === "monitor" ? stagedMonitorOverrides : stagedDesktopDirections;
    var saved = kind === "monitor" ? currentSetup.monitor_direction_overrides || {} : currentSetup.desktop_directions || {};
    return staged[name] || saved[name] || "auto";
  }
  function stageDirection(kind: string, name: string, direction: string): void {
    var staged = Object.assign({}, kind === "monitor" ? stagedMonitorOverrides : stagedDesktopDirections);
    var saved = kind === "monitor" ? currentSetup.monitor_direction_overrides || {} : currentSetup.desktop_directions || {};
    if (direction === (saved[name] || "auto")) delete staged[name];
    else staged[name] = direction;
    if (kind === "monitor") stagedMonitorOverrides = staged;
    else stagedDesktopDirections = staged;
  }
  function directionLabel(direction: string): string {
    return direction === "right" ? "Horizontal" : direction === "down" ? "Vertical" : direction === "auto" ? "Auto" : direction || "Unconfirmed";
  }
  function desktopDirectionDiffers(id: int): bool {
    var saved = (currentSetup.desktop_directions || {})[id];
    var active = (service.managedDirection.desktops || {})[id];
    return !!saved && service.managedDirection.native_direction_available === true
      && active !== undefined && active !== saved;
  }
  function reviewDiff(): string {
    if (!reviewPlan || !reviewPlan.files.length) return "No file changes.";
    var lines = reviewPlan.files.map(function(file) { return file.diff; }).join("\n").split("\n");
    return "<pre>" + lines.map(function(line) {
      var escaped = line.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
      var color = line.charAt(0) === "+" ? Theme.settingsColor("#91d5b0") : line.charAt(0) === "-" ? Theme.settingsColor("#ec9ba8") : Theme.settingsColor("#bbc8e6");
      return '<span style="color:' + color.toString() + '">' + escaped + "</span>";
    }).join("\n") + "</pre>";
  }
  function requestCurrent(): void {
    service.queryManagedDirection();
    if (previewProcess.running) return;
    previewOutput = ""; previewError = "";
    loadingCurrent = true;
    previewProcess.command = ["python3", Quickshell.shellPath("setup.py"), "setup", "--settings-preview"];
    previewProcess.running = true;
  }
  function requestReview(): void {
    if (!hasStaged) return;
    // An unresolved Apply owns the flow: a review queued before consent must
    // not reopen the Review overlay or start a preview beside the writer.
    if (applyUnresolved) { reviewRequested = false; return; }
    if (previewProcess.running) { reviewRequested = true; return; }
    previewOutput = ""; previewError = "";
    loadingCurrent = false;
    previewProcess.command = setupCommand("preview", "");
    previewProcess.running = true;
  }
  function retryNative(): void {
    if (applyUnresolved) return;
    stagedDesktopDirections = Object.assign({}, currentSetup.desktop_directions || {});
    requestReview();
  }
  function requestStatus(): void {
    if (statusProcess.running) return;
    statusOutput = ""; statusError = "";
    statusProcess.command = ["python3", Quickshell.shellPath("setup.py"), "setup", "--settings-status"];
    if (currentAttempt !== "") statusProcess.command = statusProcess.command.concat(["--settings-attempt", currentAttempt]);
    statusProcess.running = true;
  }
  function apply(): void {
    if (!reviewPlan || !reviewPlan.token || applyUnresolved) return;
    // Consent has been given here; the writer must survive Quickshell reload.
    saveFailed = false;
    currentAttempt = freshAttemptId();
    // Consent also ends the queued-review race: no delayed preview may reopen
    // the Review overlay or launch a duplicate writer for this plan.
    reviewRequested = false;
    saveRequested = false;
    Quickshell.execDetached(setupCommand("apply", reviewPlan.token));
    applyUnresolved = true;
    reviewOpen = false;
    restoreFocus();
    message = "Saving changes…";
    statusPolls = 0;
    applyPoll.start();
  }
  function finishStaged(): void {
    // Opening Settings queries the last result too; an old success must not discard a new draft.
    if (!applyUnresolved && hasStaged) return;
    preferencesReloadRequested();
    resetPreferences();
    stagedBlur = "keep";
    stagedAutostart = "keep";
    stagedShortcut = "keep";
    stagedResize = "keep";
    stagedCentering = "keep";
    stagedStripChord = "keep";
    stagedBarPanels = "keep";
    stagedBar = "keep";
    stagedBarScratchpad = "keep";
    stagedMonitorDirection = "keep";
    stagedMonitorOverrides = ({});
    stagedDesktopDirections = ({});
    applyUnresolved = false;
    currentAttempt = "";
    applyPoll.stop();
    if (closeAfterSave) { closeAfterSave = false; opened = false; }
    requestCurrent();
  }
  function reconcileManualSave(result: var): void {
    // Opening Settings also reads previous results; they cannot consume a new draft.
    if (!applyUnresolved && hasStaged) return;
    var ownAttempt = applyUnresolved;
    var bar = stagedBar, pill = stagedBarScratchpad;
    closeAfterSave = false;
    saveFailed = false;
    finishStaged();
    // The owned files are saved. Only the refused Bar edit remains a draft;
    // the receipt retains its intent when Settings reopens after UI loss.
    if (ownAttempt && result.manual_bar === true) {
      stagedBar = bar !== "keep" ? bar : (result.staged || {}).omarchy_bar || "keep";
      stagedBarScratchpad = pill !== "keep" ? pill : (result.staged || {}).bar_scratchpad || "keep";
    }
    message = "Configuration saved. Manual integration is still needed: " + (result.manual || "Review the setup instructions.");
  }
  Process {
    id: previewProcess
    stdout: StdioCollector { onStreamFinished: root.previewOutput = text }
    stderr: StdioCollector { onStreamFinished: root.previewError = text }
    onExited: function(code) {
      Qt.callLater(function() {
        if (root.applyUnresolved && !root.loadingCurrent) {
          root.saveRequested = false;
          root.reviewRequested = false;
          return;
        }
        if (code !== 0) { root.loadingCurrent = false; root.saveRequested = false; root.closeAfterSave = false; root.saveFailed = true; root.restoreFocus(); root.message = root.previewError || "Could not preview Settings changes."; return; }
        try {
          var plan = JSON.parse(root.previewOutput);
          if (root.loadingCurrent) {
            root.currentSetup = plan.effective || {};
            root.currentAutostart = root.currentSetup.autostart || "off";
          } else {
            root.reviewPlan = plan;
            root.message = "";
            if (root.saveRequested) {
              root.saveRequested = false;
              root.apply();
            } else {
              root.reviewOpen = true;
              Qt.callLater(function() { reviewCancel.forceActiveFocus(); });
            }
          }
          root.loadingCurrent = false;
          if (root.reviewRequested) {
            root.reviewRequested = false;
            Qt.callLater(function() { root.requestReview(); });
          }
        } catch (error) { root.message = "Could not read the Settings preview: " + error; }
      });
    }
  }
  Process {
    id: statusProcess
    stdout: StdioCollector { onStreamFinished: root.statusOutput = text }
    stderr: StdioCollector { onStreamFinished: root.statusError = text }
    onExited: function(code) {
      Qt.callLater(function() {
        if (code !== 0) { root.message = root.statusError || "Could not check Save status."; return; }
        try {
          var result = JSON.parse(root.statusOutput);
          // While this window waits on its own consented Apply, only that
          // attempt's receipt may resolve it. An older receipt, or one without
          // an attempt_id, can neither certify success nor clear the draft.
          if (root.applyUnresolved && root.currentAttempt !== "" && result.attempt_id !== root.currentAttempt) return;
          if (!root.applyUnresolved && (result.status === "running" || result.status === "unknown"))
            root.currentAttempt = result.attempt_id || "";
          root.nativeApplyPending = result.status === "saved-pending-native";
          if (result.status === "saved-pending-native") {
            if (result.manual) {
              root.reconcileManualSave(result);
              root.message = (result.error || "Desktop choice saved; native application is pending.") + " " + root.message;
            } else {
              root.message = result.error || "Desktop choice saved; native application is pending. Review and retry.";
              root.finishStaged();
            }
          } else if (result.status === "applied") {
            root.message = "Changes saved and validated.";
            root.currentAutostart = root.stagedAutostart === "keep" ? root.currentAutostart : root.stagedAutostart;
            root.finishStaged();
          } else if (result.status === "saved-needs-rescan") {
            root.message = "Configuration saved; Bar activation is unverified. Run: " + result.next_action;
            root.finishStaged();
          } else if (result.status === "saved-needs-manual") {
            root.reconcileManualSave(result);
          } else if (result.status === "failed") {
            root.saveFailed = true;
            root.closeAfterSave = false;
            root.message = "Save failed: " + (result.error || "See the setup backup.") + (result.backup ? " Backup: " + result.backup : "");
            applyPoll.stop();
            root.applyUnresolved = false;
            root.currentAttempt = "";
          } else if (result.status === "unknown") {
            root.saveFailed = true;
            root.closeAfterSave = false;
            root.message = "Save outcome is uncertain. Inspect the saved backup before retrying." + (result.backup ? " " + result.backup : "");
            applyPoll.stop();
            root.applyUnresolved = true;
          } else if (result.status === "not-applied") {
            root.saveFailed = true;
            root.closeAfterSave = false;
            root.message = result.error || "Save stopped before changing configuration. Review again.";
            applyPoll.stop();
            root.applyUnresolved = false;
            root.currentAttempt = "";
          } else if (result.status === "running" && !applyPoll.running) {
            root.applyUnresolved = true;
            root.message = "Saving changes…";
            root.statusPolls = 0;
            applyPoll.start();
          }
        } catch (error) { root.message = "Could not read Save status: " + error; }
      });
    }
  }
  Timer {
    id: applyPoll
    interval: 800
    repeat: true
    onTriggered: {
      root.statusPolls++;
      // A timeout is not proof that no write happened: the state stays
      // unresolved so Save, Discard and Review stay guarded until a receipt
      // for this attempt is reconciled.
      if (root.statusPolls > 30) { stop(); root.message = "Save result is not confirmed yet. Reopen Settings to check its outcome before retrying."; }
      else root.requestStatus();
    }
  }
  PanelWindow {
    id: window
    screen: root.targetScreen
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "paperland-settings"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    Rectangle {
      anchors.fill: parent
      color: Theme.alpha(Theme.settingsColor("#080b15"), 0.74)
      MouseArea { anchors.fill: parent; onClicked: root.close() }
    }
    Rectangle {
      id: card
      enabled: !root.reviewOpen && !root.confirmClose
      Keys.onEscapePressed: root.close()
      objectName: "settings-window"
      width: Math.min(1480, parent.width - 32)
      height: Math.min(880, parent.height - 32)
      anchors.centerIn: parent
      radius: 16
      color: Theme.settingsColor("#191d2c")
      border.color: Theme.settingsColor("#38415d")
      border.width: 1
      MouseArea { anchors.fill: parent }
      RowLayout {
        anchors.fill: parent
        anchors.margins: card.border.width
        spacing: 0
        Rectangle {
          Layout.preferredWidth: Math.min(270, card.width * 0.22)
          Layout.fillHeight: true
          color: Theme.settingsColor("#171b29")
          radius: 16
          ColumnLayout {
            anchors.fill: parent
            anchors.margins: 20
            spacing: 12
            Text { text: "Paperland Settings"; color: Theme.settingsColor("#d4d1ff"); font.pixelSize: 20; font.bold: true }
            Text { text: "Tidy workspaces. A calmer desktop."; color: Theme.settingsColor("#9299bc"); font.pixelSize: 11 }
            TextField {
              id: search
              objectName: "settings-search"
              Layout.fillWidth: true
              placeholderText: "Search settings…"
              Accessible.name: "Search settings"
              color: Theme.settingsColor("#d6dcf5")
              placeholderTextColor: Theme.settingsColor("#929cbe")
              onTextChanged: root.query = text
              Keys.onUpPressed: root.moveResult(-1)
              Keys.onDownPressed: root.moveResult(1)
              Keys.onReturnPressed: root.activateResult()
              Keys.onEnterPressed: root.activateResult()
              // First Escape clears a query; an empty field rejects the event so the card's close handling takes it.
              Keys.onEscapePressed: function(event) {
                if (search.text.length) { search.text = ""; event.accepted = true; }
                else event.accepted = false;
              }
              background: Rectangle { radius: 8; color: Theme.settingsColor("#202638"); border.color: search.activeFocus ? Theme.settingsColor("#7b9aff") : Theme.settingsColor("#3c4665") }
            }
            QQC.ScrollView {
              visible: root.query.trim() !== ""
              Layout.fillWidth: true
              Layout.fillHeight: true
              clip: true
              // Without this the flickable sizes contentWidth from the rows' implicit width
              // and the fillWidth rows collapse to the narrowest label.
              contentWidth: availableWidth
              ColumnLayout {
                width: parent.width
                spacing: 4
                Repeater {
                  model: root.searchResults
                  delegate: Rectangle {
                    id: resultRow
                    required property var modelData
                    required property int index
                    Layout.fillWidth: true
                    Layout.preferredHeight: 46
                    radius: 8
                    objectName: "settings-result-" + index
                    color: root.resultIndex === index ? Theme.settingsColor("#303765") : "transparent"
                    border.color: root.resultIndex === index ? Theme.settingsColor("#6488ff") : "transparent"
                    Accessible.role: Accessible.ListItem
                    Accessible.name: resultRow.modelData.label
                    ColumnLayout {
                      anchors.fill: parent; anchors.margins: 8; spacing: 2
                      Text { Layout.fillWidth: true; text: resultRow.modelData.label; color: Theme.settingsColor("#e2e0ff"); font.pixelSize: 13; elide: Text.ElideRight }
                      Text { Layout.fillWidth: true; text: resultRow.modelData.breadcrumb; color: Theme.settingsColor("#9299bc"); font.pixelSize: 11; elide: Text.ElideRight }
                    }
                    MouseArea { anchors.fill: parent; onClicked: root.openResult(resultRow.modelData) }
                  }
                }
                Text {
                  visible: root.query.trim() !== "" && root.searchResults.length === 0
                  objectName: "settings-search-empty"
                  text: "No settings match"
                  color: Theme.settingsColor("#9299bc"); font.pixelSize: 12
                }
              }
            }
            QQC.ScrollView {
              objectName: "settings-navigation-scroll"
              visible: root.query.trim() === ""
              Layout.fillWidth: true
              Layout.fillHeight: true
              clip: true
              contentWidth: availableWidth
              ColumnLayout {
                width: parent.width
                spacing: 9
                Repeater {
                  model: root.sections
                  delegate: ColumnLayout {
                    id: sectionGroup
                    required property string modelData
                    required property int index
                    Layout.fillWidth: true
                    spacing: 3
                    Rectangle {
                      id: navItem
                      readonly property string modelData: sectionGroup.modelData
                      readonly property int index: sectionGroup.index
                      Layout.fillWidth: true
                      objectName: "settings-section-" + index
                      Layout.preferredHeight: 43
                      radius: 8
                      activeFocusOnTab: true
                      Accessible.role: Accessible.Button
                      Accessible.name: navItem.modelData
                      Accessible.selectable: true
                      Accessible.selected: root.selectedSection === navItem.modelData
                      Accessible.description: Accessible.selected ? "Showing section links" : "Open section and show its links"
                      function select(): void {
                        root.selectedSection = modelData;
                        forceActiveFocus();
                      }
                      Accessible.onPressAction: select()
                      Keys.onReturnPressed: select()
                      Keys.onEnterPressed: select()
                      Keys.onSpacePressed: select()
                      onActiveFocusChanged: if (activeFocus) root.scrollToTarget(navItem)
                      color: root.selectedSection === navItem.modelData ? Theme.settingsColor("#303765") : "transparent"
                      border.color: root.selectedSection === navItem.modelData || activeFocus ? Theme.settingsColor("#6488ff") : "transparent"
                      Canvas {
                        property color ink: Theme.settingsColor("#b8c9f4")
                        onInkChanged: requestPaint()
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left; anchors.leftMargin: 14
                        width: 20; height: 20
                        onPaint: {
                          var c = getContext("2d");
                          c.strokeStyle = ink.toString(); c.lineWidth = 1.3; c.lineCap = "round";
                          c.beginPath();
                          if (navItem.index === 0) {
                            c.rect(2, 2, 6, 6); c.rect(12, 2, 6, 6); c.rect(2, 12, 6, 6); c.rect(12, 12, 6, 6);
                          } else if (navItem.index === 1) {
                            c.rect(2, 2, 16, 16); c.moveTo(7, 2); c.lineTo(7, 18); c.moveTo(7, 7); c.lineTo(18, 7);
                          } else if (navItem.index === 2) {
                            c.rect(1, 2, 18, 12); c.moveTo(10, 14); c.lineTo(10, 18); c.moveTo(6, 18); c.lineTo(14, 18);
                          } else if (navItem.index === 3) {
                            c.rect(1, 4, 18, 12); c.moveTo(4, 8); c.lineTo(16, 8); c.moveTo(4, 12); c.lineTo(16, 12);
                          } else {
                            c.arc(10, 10, 8, -Math.PI / 3, 4 * Math.PI / 3); c.moveTo(10, 1); c.lineTo(10, 9);
                          }
                          c.stroke();
                        }
                      }
                      Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 47
                        text: navItem.modelData
                        color: root.selectedSection === navItem.modelData ? Theme.settingsColor("#e2e0ff") : Theme.settingsColor("#adb4d7")
                        font.pixelSize: 14
                      }
                      MouseArea { anchors.fill: parent; onClicked: navItem.select() }
                    }
                    Repeater {
                      model: root.selectedSection === sectionGroup.modelData
                        ? SettingsSearch.cards(root.searchEntries, sectionGroup.modelData) : []
                      delegate: QQC.Button {
                        id: childLink
                        required property string modelData
                        required property int index
                        objectName: "settings-child-" + sectionGroup.index + "-" + index
                        Layout.fillWidth: true
                        Layout.leftMargin: 34
                        implicitHeight: Math.max(34, contentItem.implicitHeight + 12)
                        activeFocusOnTab: true
                        onActiveFocusChanged: if (activeFocus) root.scrollToTarget(childLink)
                        Accessible.name: modelData
                        Accessible.description: "Jump to " + modelData + " in " + sectionGroup.modelData
                        Accessible.selectable: true
                        Accessible.selected: root.selectedCard === modelData
                        Keys.onReturnPressed: clicked()
                        Keys.onEnterPressed: clicked()
                        onClicked: root.jumpTo({card: modelData, control: "", button: ""})
                        contentItem: Text {
                          text: childLink.modelData
                          color: root.selectedCard === text ? Theme.settingsColor("#e2e0ff") : Theme.settingsColor("#adb4d7")
                          font.pixelSize: 12
                          wrapMode: Text.WordWrap
                          verticalAlignment: Text.AlignVCenter
                        }
                        background: Rectangle {
                          radius: 6
                          color: root.selectedCard === childLink.modelData || childLink.hovered
                            ? Theme.settingsColor("#303765") : "transparent"
                          border.color: childLink.activeFocus ? Theme.settingsColor("#6488ff") : "transparent"
                        }
                      }
                    }
                  }
                }
              }
            }
            Text { text: "Paperland\nA native companion for Hyprland"; color: Theme.settingsColor("#777e9d"); font.pixelSize: 11; lineHeight: 1.4 }
          }
        }
        Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true; color: Theme.settingsColor("#30384d") }
        ColumnLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.margins: 24
          spacing: 14
          RowLayout {
            Layout.fillWidth: true
            Text { text: root.selectedSection; color: Theme.settingsColor("#d9d4ff"); font.pixelSize: 29; font.bold: true }
            Item { Layout.fillWidth: true }
            Rectangle {
              Layout.preferredWidth: 166; Layout.preferredHeight: 30; radius: 15
              color: Theme.settingsColor("#262c40"); border.color: Theme.settingsColor("#39445e")
              Text { anchors.centerIn: parent; text: root.saveFailed ? "●  Save error" : root.applyUnresolved ? "●  Saving…" : root.hasStaged ? "●  Unsaved changes" : "●  Saved"; color: root.saveFailed ? Theme.settingsColor("#ec9ba8") : root.hasStaged ? Theme.settingsColor("#efc989") : Theme.settingsColor("#93ccb2"); font.pixelSize: 11 }
            }
            SettingsButton { text: "✕"; Accessible.name: "Close Settings"; onClicked: root.close() }
          }
          Text {
            Layout.fillWidth: true
            text: root.selectedSection === "Minimap" ? "A compact view of your desktops and windows, always within reach."
              : root.selectedSection === "Overview" ? "Browse windows across all desktops."
              : root.selectedSection === "Displays" ? "Set how desktops grow on each display."
              : root.selectedSection === "Shortcuts" ? "Choose Paperland keys in Hyprland."
              : root.selectedSection === "Startup & Bar" ? "Choose how Paperland starts and appears in your desktop."
              : "Settings for " + root.selectedSection.toLowerCase() + "."
            color: Theme.settingsColor("#a8afd1"); font.pixelSize: 14
          }
          RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 14
          QQC.ScrollView {
            objectName: "settings-content-scroll"
            enabled: !root.applyUnresolved
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: availableWidth
            ColumnLayout {
              id: contentCards
              width: parent.width
              spacing: 14
              Rectangle {
                visible: root.selectedSection === "Minimap"
                Layout.fillWidth: true; implicitHeight: 218
                color: Theme.settingsColor("#202638"); border.color: Theme.settingsColor("#37415b"); radius: 10
                ColumnLayout {
                  anchors.fill: parent; anchors.margins: 20; spacing: 12
                  Text { text: "Visibility"; color: Theme.settingsColor("#d9d4ff"); font.pixelSize: 18; font.bold: true }
                  Text { text: "Control when the minimap is shown."; color: Theme.settingsColor("#9ea7ca"); font.pixelSize: 12 }
                  RowLayout {
                    Layout.fillWidth: true
                    Text { text: "Strip mode"; color: Theme.settingsColor("#c3c9e5"); font.pixelSize: 13 }
                    Item { Layout.fillWidth: true }
                    Repeater {
                      model: ["Pinned", "Peek", "Manual"]
                      delegate: SettingsButton {
                        id: modeButton
                        required property string modelData
                        text: modeButton.modelData
                        checkable: true
                        autoExclusive: true
                        checked: modeButton.modelData === "Pinned" ? root.pinned : modeButton.modelData === "Peek" ? root.peekEnabled : !root.pinned && !root.peekEnabled
                        onClicked: { root.pinned = modeButton.modelData === "Pinned"; root.peekEnabled = modeButton.modelData === "Peek"; }
                      }
                    }
                  }
                  Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.settingsColor("#37415b") }
                  RowLayout {
                    Layout.fillWidth: true
                    ColumnLayout {
                      Text { text: "Peek lasts"; color: Theme.settingsColor("#c3c9e5"); font.pixelSize: 13 }
                      Text { text: "How long the minimap stays visible when peeking."; color: Theme.settingsColor("#929cbe"); font.pixelSize: 11 }
                    }
                    Item { Layout.fillWidth: true }
                    NumberBox {
                      objectName: "settings-peek-seconds"
                      from: 1; to: 60; value: root.peekSeconds; editable: true
                      Accessible.name: "Peek duration in seconds"
                      onValueModified: root.peekSeconds = value
                    }
                    Text { text: "seconds"; color: Theme.settingsColor("#b4bad7"); font.pixelSize: 12 }
                  }
                }
              }
              Rectangle {
                visible: root.selectedSection === "Minimap"
                Layout.fillWidth: true; implicitHeight: 284
                color: Theme.settingsColor("#202638"); border.color: Theme.settingsColor("#37415b"); radius: 10
                ColumnLayout {
                  anchors.fill: parent; anchors.margins: 20; spacing: 13
                  Text { text: "Appearance"; color: Theme.settingsColor("#d9d4ff"); font.pixelSize: 18; font.bold: true }
                  Text { text: "Adjust how the minimap blends with your desktop."; color: Theme.settingsColor("#9ea7ca"); font.pixelSize: 12 }
                  RowLayout {
                    Layout.fillWidth: true
                    Text { text: "Opacity"; color: Theme.settingsColor("#c3c9e5"); font.pixelSize: 13 }
                    Item { Layout.fillWidth: true }
                    SettingsButton {
                      text: "Background only"; checkable: true; autoExclusive: true; checked: root.opacityMode === "background"
                      onClicked: root.opacityMode = "background"
                    }
                    SettingsButton {
                      text: "Entire strip"; checkable: true; autoExclusive: true; checked: root.opacityMode === "entire"
                      onClicked: root.opacityMode = "entire"
                    }
                  }
                  RowLayout {
                    Layout.fillWidth: true
                    QQC.Slider {
                      id: opacitySlider
                      objectName: "settings-opacity-slider"
                      implicitHeight: 30
                      Layout.fillWidth: true
                      from: root.opacityMode === "entire" ? 20 : 0
                      to: 100
                      value: root.opacityValue
                      Accessible.name: root.opacityMode === "entire" ? "Entire strip opacity" : "Minimap background opacity"
                      onMoved: { if (root.opacityMode === "entire") root.entireOpacity = Math.round(value); else root.backgroundOpacity = Math.round(value); }
                      background: Rectangle {
                        x: opacitySlider.leftPadding
                        y: opacitySlider.topPadding + opacitySlider.availableHeight / 2 - height / 2
                        width: opacitySlider.availableWidth; height: 7; radius: 4; color: Theme.settingsColor("#3a425b")
                        Rectangle { width: opacitySlider.visualPosition * parent.width; height: parent.height; radius: 4; color: Theme.settingsColor("#5b82f6") }
                      }
                      handle: Rectangle {
                        x: opacitySlider.leftPadding + opacitySlider.visualPosition * (opacitySlider.availableWidth - width)
                        y: opacitySlider.topPadding + opacitySlider.availableHeight / 2 - height / 2
                        width: 18; height: 18; radius: 9; color: Theme.settingsColor("#b0c1ff"); border.color: Theme.settingsColor("#7194ff")
                      }
                    }
                    Text { text: root.opacityValue + "%"; color: Theme.settingsColor("#c3c9e5"); font.pixelSize: 13 }
                    NumberBox {
                      objectName: "settings-opacity-percent"
                      from: root.opacityMode === "entire" ? 20 : 0
                      to: 100; value: root.opacityValue; editable: true
                      Accessible.name: "Opacity percent"
                      onValueModified: { if (root.opacityMode === "entire") root.entireOpacity = value; else root.backgroundOpacity = value; }
                    }
                  }
                  Text { text: "Background only can reach 0%. Entire strip starts at 20%."; color: Theme.settingsColor("#929cbe"); font.pixelSize: 11 }
                  Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.settingsColor("#37415b") }
                  RowLayout {
                    Layout.fillWidth: true
                    ColumnLayout {
                      Text { text: "Blur background"; color: Theme.settingsColor("#c3c9e5"); font.pixelSize: 13 }
                      Text { text: root.currentSetup.compositor_blur === false ? "Hyprland blur is disabled. Enable decoration.blur.enabled in your config." : "Soften the desktop behind the minimap using Hyprland’s blur settings."; color: Theme.settingsColor("#929cbe"); font.pixelSize: 11; wrapMode: Text.Wrap; Layout.fillWidth: true }
                    }
                    Item { Layout.fillWidth: true }
                    SettingsSwitch {
                      objectName: "settings-minimap-blur"
                      checked: root.stagedBlur === "keep" ? root.currentSetup.minimap_blur === true : root.stagedBlur === "on"
                      Accessible.name: "Blur minimap background"
                      onClicked: root.stagedBlur = checked === (root.currentSetup.minimap_blur === true) ? "keep" : checked ? "on" : "off"
                    }
                  }
                }
              }
              Rectangle {
                visible: root.selectedSection === "Overview"
                Layout.fillWidth: true; implicitHeight: 160
                color: Theme.settingsColor("#202638"); border.color: Theme.settingsColor("#37415b"); radius: 10
                ColumnLayout {
                  anchors.fill: parent; anchors.margins: 20; spacing: 12
                  Text { text: "Window list"; color: Theme.settingsColor("#d9d4ff"); font.pixelSize: 18; font.bold: true }
                  Text { text: "Keep the docked list visible."; color: Theme.settingsColor("#9ea7ca"); font.pixelSize: 12 }
                  RowLayout {
                    Layout.fillWidth: true
                    Text { text: "Show window list"; color: Theme.settingsColor("#c3c9e5"); font.pixelSize: 13 }
                    Item { Layout.fillWidth: true }
                    SettingsSwitch {
                      objectName: "settings-overview-window-list"
                      checked: root.overviewWindowList
                      Accessible.name: "Show Overview window list"
                      onClicked: root.overviewWindowList = checked
                    }
                  }
                }
              }
              Rectangle {
                visible: root.selectedSection === "Minimap"
                Layout.fillWidth: true; implicitHeight: 138
                color: Theme.settingsColor("#202638"); border.color: Theme.settingsColor("#37415b"); radius: 10
                ColumnLayout {
                  anchors.fill: parent; anchors.margins: 20; spacing: 12
                  Text { text: "Contents"; color: Theme.settingsColor("#d9d4ff"); font.pixelSize: 18; font.bold: true }
                  Text { text: "Choose what the minimap should track."; color: Theme.settingsColor("#9ea7ca"); font.pixelSize: 12 }
                  RowLayout {
                    Layout.fillWidth: true
                    ColumnLayout {
                      Text { text: "Follow Scratchpad"; color: Theme.settingsColor("#c3c9e5"); font.pixelSize: 13 }
                      Text { text: "Show the open Scratchpad on its display."; color: Theme.settingsColor("#929cbe"); font.pixelSize: 11 }
                    }
                    Item { Layout.fillWidth: true }
                    SettingsSwitch {
                      objectName: "settings-scratchpad-follow"
                      checked: root.scratchpadFollow
                      Accessible.name: "Follow Scratchpad"
                      onClicked: root.scratchpadFollow = checked
                    }
                  }
                }
              }
              Rectangle {
                visible: root.selectedSection === "Shortcuts"
                Layout.fillWidth: true; implicitHeight: windowNav.implicitHeight + 40
                color: Theme.settingsColor("#202638"); border.color: Theme.settingsColor("#37415b"); radius: 10
                ColumnLayout {
                  id: windowNav
                  anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 20
                  spacing: 12
                  Text { text: "Window navigation"; color: Theme.settingsColor("#d9d4ff"); font.pixelSize: 18; font.bold: true }
                  Text { text: "Set shortcuts for quick access to Paperland features."; color: Theme.settingsColor("#9ea7ca"); font.pixelSize: 12 }
                  RowLayout {
                    Layout.fillWidth: true
                    Text { text: "Open minimap"; color: Theme.settingsColor("#c3c9e5"); font.pixelSize: 13 }
                    Item { Layout.fillWidth: true }
                    TextField {
                      id: shortcutField
                      objectName: "settings-shortcut"
                      Layout.preferredWidth: 210
                      text: root.stagedShortcut === "keep" ? root.currentSetup.shortcut || "none" : root.stagedShortcut
                      Accessible.name: "Open minimap shortcut"
                      placeholderText: "SUPER + M, or none"
                      color: Theme.settingsColor("#d6dcf5")
                      placeholderTextColor: Theme.settingsColor("#929cbe")
                      onEditingFinished: root.stagedShortcut = text.trim() === root.currentSetup.shortcut ? "keep" : text.trim() || "none"
                      background: Rectangle { radius: 8; color: Theme.settingsColor("#202638"); border.color: shortcutField.activeFocus ? Theme.settingsColor("#7b9aff") : Theme.settingsColor("#3c4665") }
                    }
                  }
                  Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.settingsColor("#37415b") }
                  RowLayout {
                    Layout.fillWidth: true
                    ColumnLayout {
                      Text { text: "Numbered strip focus"; color: Theme.settingsColor("#c3c9e5"); font.pixelSize: 13 }
                      Text { text: "Super + Ctrl + 1–9 focuses a numbered window."; color: Theme.settingsColor("#929cbe"); font.pixelSize: 11 }
                    }
                    Item { Layout.fillWidth: true }
                    SettingsSwitch {
                      objectName: "settings-strip-chord"
                      checked: root.chordEnabled
                      Accessible.name: "Numbered strip focus"
                      onClicked: {
                        var choice = checked ? "SUPER + CTRL" : "none";
                        root.stagedStripChord = choice === (root.currentSetup.strip_chord || "none") ? "keep" : choice;
                        root.stagedBarPanels = root.chordEnabled && root.stagedStripChord !== "keep" ? root.preferredBarPanels() : "keep";
                      }
                    }
                  }
                  Text {
                    text: root.effectiveBarPanels === "relocate"
                      ? "When enabled, conflicting Omarchy Bar keys move to Super + Ctrl + Alt + 1–9."
                      : "When enabled, conflicting Omarchy Bar panel keys are removed; Omarchy's defaults return when the chord is disabled."
                    color: Theme.settingsColor("#929cbe"); font.pixelSize: 11; wrapMode: Text.Wrap; Layout.fillWidth: true
                  }
                  RowLayout {
                    objectName: "settings-bar-panels"
                    visible: root.chordEnabled && root.currentSetup.bar_available === true
                    Layout.fillWidth: true
                    ColumnLayout {
                      Text { text: "Bar panel shortcuts"; color: Theme.settingsColor("#c3c9e5"); font.pixelSize: 13 }
                      Text { text: "What happens to the conflicting Omarchy Bar keys."; color: Theme.settingsColor("#929cbe"); font.pixelSize: 11 }
                    }
                    Item { Layout.fillWidth: true }
                    SettingsButton {
                      text: "Relocate"
                      checkable: true
                      autoExclusive: true
                      checked: root.effectiveBarPanels === "relocate"
                      selected: root.effectiveBarPanels === "relocate"
                      Accessible.name: "Relocate Bar panel shortcuts"
                      onClicked: root.stagedBarPanels = "relocate"
                    }
                    SettingsButton {
                      text: "Drop"
                      checkable: true
                      autoExclusive: true
                      checked: root.effectiveBarPanels === "drop"
                      selected: root.effectiveBarPanels === "drop"
                      Accessible.name: "Drop Bar panel shortcuts"
                      onClicked: root.stagedBarPanels = "drop"
                    }
                  }
                }
              }
              Rectangle {
                visible: root.selectedSection === "Shortcuts"
                Layout.fillWidth: true; implicitHeight: 224
                color: Theme.settingsColor("#202638"); border.color: Theme.settingsColor("#37415b"); radius: 10
                ColumnLayout {
                  anchors.fill: parent; anchors.margins: 20; spacing: 12
                  Text { text: "Canvas actions"; color: Theme.settingsColor("#d9d4ff"); font.pixelSize: 18; font.bold: true }
                  Text { text: "Shortcuts for arranging columns on your canvas."; color: Theme.settingsColor("#9ea7ca"); font.pixelSize: 12 }
                  RowLayout {
                    Layout.fillWidth: true
                    Text { text: "Resize columns"; color: Theme.settingsColor("#c3c9e5"); font.pixelSize: 13 }
                    Item { Layout.fillWidth: true }
                    QQC.ComboBox {
                      objectName: "settings-resize"
                      Layout.preferredWidth: 210
                      implicitHeight: 38
                      model: ["System", "Incremental", "Presets"]
                      currentIndex: ["system", "incremental", "presets"].indexOf(root.stagedResize === "keep" ? root.currentSetup.resize || "system" : root.stagedResize)
                      Accessible.name: "Resize columns shortcuts"
                      palette.base: Theme.settingsColor("#1b2234")
                      palette.button: Theme.settingsColor("#1b2234")
                      palette.text: Theme.settingsColor("#d5ddf5")
                      palette.buttonText: Theme.settingsColor("#d5ddf5")
                      background: Rectangle { radius: 7; color: Theme.settingsColor("#1b2234"); border.color: Theme.settingsColor("#414c69") }
                      onActivated: {
                        var choice = ["system", "incremental", "presets"][currentIndex];
                        root.stagedResize = choice === root.currentSetup.resize ? "keep" : choice;
                      }
                    }
                  }
                  Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.settingsColor("#37415b") }
                  RowLayout {
                    Layout.fillWidth: true
                    Text { text: "Center columns"; color: Theme.settingsColor("#c3c9e5"); font.pixelSize: 13 }
                    Item { Layout.fillWidth: true }
                    TextField {
                      id: centeringField
                      objectName: "settings-centering"
                      Layout.preferredWidth: 210
                      text: root.stagedCentering === "keep" ? root.currentSetup.centering || "none" : root.stagedCentering
                      Accessible.name: "Center columns shortcut"
                      placeholderText: "SUPER + C, or none"
                      color: Theme.settingsColor("#d6dcf5")
                      placeholderTextColor: Theme.settingsColor("#929cbe")
                      onEditingFinished: root.stagedCentering = text.trim() === (root.currentSetup.centering || "none") ? "keep" : text.trim() || "none"
                      background: Rectangle { radius: 8; color: Theme.settingsColor("#202638"); border.color: centeringField.activeFocus ? Theme.settingsColor("#7b9aff") : Theme.settingsColor("#3c4665") }
                    }
                  }
                }
              }
              Rectangle {
                visible: root.selectedSection === "Overview"
                Layout.fillWidth: true; implicitHeight: 160
                color: Theme.settingsColor("#202638"); border.color: Theme.settingsColor("#37415b"); radius: 10
                ColumnLayout {
                  anchors.fill: parent; anchors.margins: 20; spacing: 12
                  Text { text: "Previews"; color: Theme.settingsColor("#d9d4ff"); font.pixelSize: 18; font.bold: true }
                  Text { text: "Choose how window previews are displayed."; color: Theme.settingsColor("#9ea7ca"); font.pixelSize: 12 }
                  RowLayout {
                    Layout.fillWidth: true
                    Text { text: "Preview density"; color: Theme.settingsColor("#c3c9e5"); font.pixelSize: 13 }
                    Item { Layout.fillWidth: true }
                    Repeater {
                      model: ["Full", "Icons", "Timeline"]
                      delegate: SettingsButton {
                        id: densityButton
                        required property string modelData
                        required property int index
                        text: densityButton.modelData
                        checkable: true
                        autoExclusive: true
                        checked: root.overviewDensity === densityButton.index
                        onClicked: root.overviewDensity = densityButton.index
                      }
                    }
                  }
                }
              }
              Rectangle {
                visible: root.selectedSection === "Startup & Bar"
                Layout.fillWidth: true; implicitHeight: 180
                color: Theme.settingsColor("#202638"); border.color: Theme.settingsColor("#37415b"); radius: 10
                ColumnLayout {
                  anchors.fill: parent; anchors.margins: 20; spacing: 12
                  Text { text: "Startup"; color: Theme.settingsColor("#d9d4ff"); font.pixelSize: 18; font.bold: true }
                  Text { text: "Choose what happens when you sign in."; color: Theme.settingsColor("#9ea7ca"); font.pixelSize: 12 }
                  RowLayout {
                    Layout.fillWidth: true
                    ColumnLayout {
                      Text { text: "Start Paperland hidden at login"; color: Theme.settingsColor("#c3c9e5"); font.pixelSize: 13 }
                      Text { text: "Keep Paperland ready without opening the minimap."; color: Theme.settingsColor("#929cbe"); font.pixelSize: 11 }
                    }
                    Item { Layout.fillWidth: true }
                    SettingsSwitch {
                      objectName: "settings-startup-hidden"
                      checked: root.stagedAutostart === "keep" ? root.currentAutostart === "on" : root.stagedAutostart === "on"
                      Accessible.name: "Start Paperland hidden"
                      onClicked: root.stagedAutostart = checked === (root.currentAutostart === "on") ? "keep" : checked ? "on" : "off"
                    }
                  }
                  Text { text: root.stagedAutostart === "keep" ? "Current setting" : "Unsaved changes"; color: root.stagedAutostart === "keep" ? Theme.settingsColor("#8fcaac") : Theme.settingsColor("#eac487"); font.pixelSize: 11 }
                }
              }
              Rectangle {
                visible: root.selectedSection === "Startup & Bar"
                Layout.fillWidth: true; implicitHeight: 246
                color: Theme.settingsColor("#202638"); border.color: Theme.settingsColor("#37415b"); radius: 10
                ColumnLayout {
                  anchors.fill: parent; anchors.margins: 20; spacing: 12
                  Text { text: "Omarchy Bar"; color: Theme.settingsColor("#d9d4ff"); font.pixelSize: 18; font.bold: true }
                  Text { text: root.currentSetup.bar_available ? "Show Paperland controls in the Omarchy Bar." : "Omarchy Bar configuration is unavailable on this installation."; color: Theme.settingsColor("#9ea7ca"); font.pixelSize: 12; wrapMode: Text.Wrap; Layout.fillWidth: true }
                  RowLayout {
                    Layout.fillWidth: true
                    ColumnLayout {
                      Text { text: "Use Paperland in Omarchy Bar"; color: Theme.settingsColor("#c3c9e5"); font.pixelSize: 13 }
                      Text { text: "Saved configuration; Review shows how to load changes."; color: Theme.settingsColor("#929cbe"); font.pixelSize: 11 }
                    }
                    Item { Layout.fillWidth: true }
                    SettingsSwitch {
                      objectName: "settings-bar-integration"
                      enabled: !!root.currentSetup.bar_available
                      checked: root.stagedBar === "keep" ? root.currentSetup.omarchy_bar === true : root.stagedBar === "enable"
                      Accessible.name: "Use Paperland in Omarchy Bar"
                      onClicked: root.stagedBar = checked === (root.currentSetup.omarchy_bar === true) ? "keep" : checked ? "enable" : "disable"
                    }
                  }
                  Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.settingsColor("#37415b") }
                  RowLayout {
                    Layout.fillWidth: true
                    Text { text: "Show Scratchpad pill"; color: Theme.settingsColor("#c3c9e5"); font.pixelSize: 13 }
                    Item { Layout.fillWidth: true }
                    SettingsSwitch {
                      objectName: "settings-bar-scratchpad"
                      enabled: !!root.currentSetup.bar_available && (root.stagedBar === "enable" || root.stagedBar === "keep" && root.currentSetup.omarchy_bar === true)
                      checked: root.stagedBarScratchpad === "keep" ? root.currentSetup.bar_scratchpad !== false : root.stagedBarScratchpad === "show"
                      Accessible.name: "Show Bar Scratchpad pill"
                      onClicked: root.stagedBarScratchpad = checked === (root.currentSetup.bar_scratchpad !== false) ? "keep" : checked ? "show" : "hide"
                    }
                  }
                  Text { text: "Manual control: edit json.paperland and its scratchpad value in ~/.config/omarchy/shell.json. Linked files stay untouched; Review shows exact instructions."; color: Theme.settingsColor("#929cbe"); font.pixelSize: 11; wrapMode: Text.Wrap; Layout.fillWidth: true }
                }
              }
              Rectangle {
                visible: root.selectedSection === "Displays"
                Layout.fillWidth: true; implicitHeight: 105
                color: Theme.settingsColor("#202638"); border.color: Theme.settingsColor("#37415b"); radius: 10
                RowLayout {
                  anchors.fill: parent; anchors.margins: 20
                  ColumnLayout {
                    Text { text: "Monitor-aware integration"; color: Theme.settingsColor("#d9d4ff"); font.pixelSize: 18; font.bold: true }
                    Text { text: "When off, explicit Desktop choices are saved but inactive."; color: Theme.settingsColor("#9ea7ca"); font.pixelSize: 12; wrapMode: Text.Wrap; Layout.fillWidth: true }
                  }
                  Item { Layout.fillWidth: true }
                  SettingsSwitch {
                    objectName: "settings-monitor-integration"
                    checked: root.stagedMonitorDirection === "keep" ? root.currentSetup.monitor_direction === true : root.stagedMonitorDirection === "on"
                    Accessible.name: "Monitor-aware integration"
                    onClicked: root.stagedMonitorDirection = checked === (root.currentSetup.monitor_direction === true) ? "keep" : checked ? "on" : "off"
                  }
                }
              }
              Rectangle {
                visible: root.selectedSection === "Displays"
                Layout.fillWidth: true; implicitHeight: monitorChoices.implicitHeight + 40
                color: Theme.settingsColor("#202638"); border.color: Theme.settingsColor("#37415b"); radius: 10
                ColumnLayout {
                  id: monitorChoices
                  anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 20
                  spacing: 14
                  Text { text: "Monitor direction"; color: Theme.settingsColor("#d9d4ff"); font.pixelSize: 18; font.bold: true }
                  Text { text: "Choose how desktops grow on each connected display."; color: Theme.settingsColor("#9ea7ca"); font.pixelSize: 12; wrapMode: Text.Wrap; Layout.fillWidth: true }
                  Repeater {
                    model: root.monitors
                    delegate: ColumnLayout {
                      id: monitorChoice
                      required property var modelData
                      Layout.fillWidth: true
                      RowLayout {
                        Layout.fillWidth: true
                        ColumnLayout {
                          Text { text: monitorChoice.modelData.name; color: Theme.settingsColor("#c3c9e5"); font.pixelSize: 13 }
                          Text { text: monitorChoice.modelData.width + " × " + monitorChoice.modelData.height; color: Theme.settingsColor("#929cbe"); font.pixelSize: 11 }
                        }
                        Item { Layout.fillWidth: true }
                        Repeater {
                          model: ["auto", "right", "down"]
                          delegate: SettingsButton {
                            id: monitorDirectionButton
                            required property string modelData
                            text: root.directionLabel(monitorDirectionButton.modelData)
                            Accessible.name: monitorChoice.modelData.name + " direction " + text
                            selected: root.directionChoice("monitor", monitorChoice.modelData.name) === monitorDirectionButton.modelData
                            onClicked: root.stageDirection("monitor", monitorChoice.modelData.name, monitorDirectionButton.modelData)
                          }
                        }
                      }
                      Text {
                        text: "Monitor policy: " + root.directionLabel(root.service.managedDirection.enabled ? root.service.managedDirection.monitors[monitorChoice.modelData.name] || "" : "")
                        color: Theme.settingsColor("#929cbe"); font.pixelSize: 11
                      }
                    }
                  }
                }
              }
              Rectangle {
                visible: root.selectedSection === "Displays"
                Layout.fillWidth: true; implicitHeight: desktopChoices.implicitHeight + 40
                color: Theme.settingsColor("#202638"); border.color: Theme.settingsColor("#37415b"); radius: 10
                ColumnLayout {
                  id: desktopChoices
                  anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 20
                  spacing: 14
                  Text { text: "Desktop direction"; color: Theme.settingsColor("#d9d4ff"); font.pixelSize: 18; font.bold: true }
                  Text { text: "Auto follows its assigned display. Explicit choices stay with the Desktop when moved."; color: Theme.settingsColor("#9ea7ca"); font.pixelSize: 12; wrapMode: Text.Wrap; Layout.fillWidth: true }
                  Text { visible: !root.desktopBackendReady; text: "Desktop overrides are unavailable: native active direction cannot yet be verified."; color: Theme.settingsColor("#e5c18a"); font.pixelSize: 12; wrapMode: Text.Wrap; Layout.fillWidth: true }
                  Text {
                    objectName: "settings-pan-unavailable"
                    visible: root.service.managedDirection.enabled && !root.service.managedDirection.native_direction_available
                    text: "Canvas panning (drag or wheel) is unavailable while native direction cannot be verified. If the bridge is unavailable, install a compatible build."
                    color: Theme.settingsColor("#e5c18a"); font.pixelSize: 12; wrapMode: Text.Wrap; Layout.fillWidth: true
                  }
                  Repeater {
                    model: root.desktops
                    delegate: ColumnLayout {
                      id: desktopChoice
                      required property var modelData
                      Layout.fillWidth: true
                      RowLayout {
                        Layout.fillWidth: true
                        Text { Layout.fillWidth: true; text: "Desktop " + desktopChoice.modelData.id; color: Theme.settingsColor("#c3c9e5"); font.pixelSize: 13 }
                        Repeater {
                          model: ["auto", "right", "down"]
                          delegate: SettingsButton {
                            id: desktopDirectionButton
                            required property string modelData
                            text: root.directionLabel(desktopDirectionButton.modelData)
                            enabled: root.desktopBackendReady
                            Accessible.name: "Desktop " + desktopChoice.modelData.id + " direction " + text
                            selected: root.directionChoice("desktop", String(desktopChoice.modelData.id)) === desktopDirectionButton.modelData
                            onClicked: root.stageDirection("desktop", String(desktopChoice.modelData.id), desktopDirectionButton.modelData)
                          }
                        }
                      }
                      Text {
                        visible: root.currentSetup.desktop_directions !== undefined
                        text: "Saved: " + root.directionLabel((root.currentSetup.desktop_directions || {})[desktopChoice.modelData.id] || "auto")
                          + " · Active: " + (root.currentSetup.monitor_direction !== true ? "Inactive (integration off)"
                            : root.service.managedDirection.native_direction_available && (root.service.managedDirection.desktops || {})[desktopChoice.modelData.id]
                              ? root.directionLabel(root.service.managedDirection.desktops[desktopChoice.modelData.id]) : "Unconfirmed")
                        color: root.desktopDirectionDiffers(desktopChoice.modelData.id) ? Theme.settingsColor("#e5c18a") : Theme.settingsColor("#929cbe"); font.pixelSize: 11
                      }
                      Text {
                        visible: root.desktopDirectionDiffers(desktopChoice.modelData.id)
                        text: "Native direction differs from the saved choice."
                        color: Theme.settingsColor("#e5c18a"); font.pixelSize: 11; wrapMode: Text.Wrap; Layout.fillWidth: true
                      }
                    }
                  }
                }
              }
            }
          }
          Rectangle {
            visible: card.width >= 1050
            Layout.preferredWidth: card.width * 0.31
            Layout.fillHeight: true
            radius: 10
            color: Theme.settingsColor("#202638")
            border.color: Theme.settingsColor("#37415b")
            ColumnLayout {
              anchors.fill: parent; anchors.margins: 18; spacing: 12
              Text { text: root.selectedSection === "Shortcuts" ? "Pending change" : root.selectedSection === "Startup & Bar" ? "Bar preview" : "Preview"; color: Theme.settingsColor("#d9d4ff"); font.pixelSize: 18; font.bold: true }
              Text { text: root.selectedSection === "Shortcuts" ? "Review shows the exact file changes." : root.selectedSection === "Minimap" || root.selectedSection === "Overview" ? "A live view of your current desktop." : "An illustration of your selected options."; color: Theme.settingsColor("#9ea7ca"); font.pixelSize: 12; wrapMode: Text.Wrap; Layout.fillWidth: true }
              Rectangle {
                Layout.fillWidth: true; Layout.fillHeight: true
                radius: 8; clip: true
                gradient: Gradient {
                  GradientStop { position: 0; color: Theme.settingsColor("#172440") }
                  GradientStop { position: 0.55; color: Theme.settingsColor("#2d4165") }
                  GradientStop { position: 1; color: Theme.settingsColor("#111e34") }
                }
                MiniStrip {
                  visible: root.selectedSection === "Minimap"
                  enabled: false
                  row: root.targetScreen ? root.service.rowForScreen(root.targetScreen.name) : null
                  width: vertical ? 150 : parent.width - 24
                  height: vertical ? Math.min(parent.height - 24, implicitHeight) : implicitHeight
                  x: vertical ? parent.width - width - 12 : 12
                  y: vertical ? 12 : parent.height - height - 12
                  thumbnailSource: Qt.resolvedUrl("native/WindowThumbnail.qml")
                  captureEnabled: root.opened && visible
                  workspaces: root.targetScreen ? root.service.workspacesFor(root.targetScreen.name) : []
                  scratchpad: root.targetScreen ? root.service.scratchpadForMonitor(root.targetScreen.name) : null
                  scratchpadOpen: !!scratchpad && scratchpad.active
                  shortcutBinding: root.service.scratchpadBinding
                  focusedAddress: root.service.focusedAddress
                  pinned: root.pinned
                  peek: root.peekEnabled
                  backgroundOpacity: root.opacityMode === "background" ? root.backgroundOpacity : 96
                  opacity: root.opacityMode === "entire" ? root.entireOpacity / 100 : 1
                  iconFor: Native.Runtime.iconFor
                  nameFor: Native.Runtime.nameFor
                }
                OverviewBoard {
                  visible: root.selectedSection === "Overview"
                  enabled: false
                  width: 1100
                  height: parent.height / scale
                  scale: parent.width / width
                  transformOrigin: Item.TopLeft
                  rows: root.service.rows
                  rowIds: root.service.rowIds
                  windows: root.service.windows
                  catalog: root.service.catalog
                  focusedAddress: root.service.focusedAddress
                  captureEnabled: root.opened && visible
                  listEnabled: root.overviewWindowList
                  density: root.overviewDensity
                  iconFor: Native.Runtime.iconFor
                  nameFor: Native.Runtime.nameFor
                }
                ColumnLayout {
                  visible: root.selectedSection === "Shortcuts"
                  anchors.fill: parent; anchors.margins: 18; spacing: 16
                  Text { text: "Open minimap"; color: Theme.settingsColor("#d2d9f4"); font.pixelSize: 13 }
                  Text { text: root.stagedShortcut === "keep" ? root.currentSetup.shortcut || "none" : root.stagedShortcut; color: Theme.settingsColor("#93b1ff"); font.pixelSize: 18; wrapMode: Text.Wrap; Layout.fillWidth: true }
                  Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.settingsColor("#46506b") }
                  Text { text: "Resize columns"; color: Theme.settingsColor("#d2d9f4"); font.pixelSize: 13 }
                  Text { text: root.stagedResize === "keep" ? root.currentSetup.resize || "system" : root.stagedResize; color: Theme.settingsColor("#93b1ff"); font.pixelSize: 16 }
                  Item { Layout.fillHeight: true }
                  Text { text: "Keys take effect after Save changes."; color: Theme.settingsColor("#a6b2d1"); font.pixelSize: 12; wrapMode: Text.Wrap; Layout.fillWidth: true }
                }
                ColumnLayout {
                  visible: root.selectedSection === "Displays" || root.selectedSection === "Startup & Bar"
                  anchors.fill: parent; anchors.margins: 12; spacing: 10
                  Rectangle {
                    visible: root.selectedSection === "Startup & Bar"
                    Layout.fillWidth: true; Layout.preferredHeight: 40
                    radius: 6; color: Theme.settingsColor("#111b31")
                    Text {
                      anchors.centerIn: parent
                      text: !root.currentSetup.bar_available ? "Omarchy Bar unavailable" : "Menu    1   2   3" + ((root.stagedBar === "enable" || root.stagedBar === "keep" && root.currentSetup.omarchy_bar === true) && (root.stagedBarScratchpad === "show" || root.stagedBarScratchpad === "keep" && root.currentSetup.bar_scratchpad !== false) ? "     S" : "")
                      color: Theme.settingsColor("#c5d2f4"); font.pixelSize: 12
                    }
                  }
                  Item { visible: root.selectedSection !== "Overview"; Layout.fillHeight: true }
                  Rectangle {
                    Layout.alignment: Qt.AlignRight
                    Layout.fillHeight: root.selectedSection !== "Startup & Bar"
                    Layout.preferredWidth: root.selectedSection === "Overview" ? parent.width : parent.width * 0.58
                    Layout.preferredHeight: root.selectedSection === "Startup & Bar" ? 90 : 260
                    radius: 10
                    color: Theme.alpha(Theme.settingsColor("#111b31"), root.opacityMode === "background" ? root.backgroundOpacity / 100 : 0.96)
                    opacity: root.selectedSection === "Minimap" && root.opacityMode === "entire" ? root.entireOpacity / 100 : 1
                    ColumnLayout {
                      anchors.fill: parent; anchors.margins: 9; spacing: 10
                      Repeater {
                        model: root.selectedSection === "Startup & Bar" ? 1 : 3
                        delegate: ColumnLayout {
                          id: illustratedDesktop
                          required property int index
                          Layout.fillWidth: true; Layout.fillHeight: true
                          spacing: 6
                          Rectangle {
                            Layout.fillWidth: true; Layout.preferredHeight: 25; radius: 7; color: Theme.settingsColor("#303950")
                            Text { anchors.centerIn: parent; text: "Desktop " + (illustratedDesktop.index + 1); color: Theme.settingsColor("#c9d1ea"); font.pixelSize: 10 }
                          }
                          Rectangle {
                            Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumHeight: 35
                            radius: 5; color: Theme.settingsColor("#1c2638"); border.color: Theme.settingsColor("#45526e")
                            Row {
                              visible: root.selectedSection === "Overview" && root.overviewDensity === 1
                              anchors.centerIn: parent; spacing: 8
                              Repeater { model: 3; Rectangle { width: 24; height: 24; radius: 4; color: Theme.settingsColor("#6588bc") } }
                            }
                            Column {
                              visible: root.selectedSection !== "Overview" || root.overviewDensity !== 1
                              anchors.fill: parent; anchors.margins: 7; spacing: 4
                              Repeater {
                                model: 4
                                delegate: Rectangle {
                                  required property int index
                                  width: parent.width * (index % 2 ? 0.55 : 0.83)
                                  height: 3; radius: 1
                                  color: index % 2 ? Theme.settingsColor("#577391") : Theme.settingsColor("#7596bc")
                                }
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
          }
          Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.settingsColor("#37415b") }
          RowLayout {
            Layout.fillWidth: true
            Text { Layout.fillWidth: true; text: root.message || (root.hasStaged ? "Your changes have not been saved." : "All changes saved."); color: Theme.settingsColor("#a8afd1"); font.pixelSize: 12; wrapMode: Text.Wrap }
            SettingsButton { objectName: "settings-retry-native"; text: "Retry native apply"; visible: root.nativeApplyPending || root.desktops.some(function(workspace) { return root.desktopDirectionDiffers(workspace.id); }); enabled: root.desktopBackendReady && !root.applyUnresolved; onClicked: root.retryNative() }
            SettingsButton { text: "Discard changes"; enabled: root.hasStaged && !root.applyUnresolved; onClicked: root.discard() }
            SettingsButton { objectName: "settings-show-diff"; text: "Show file changes"; enabled: root.hasStaged && !root.applyUnresolved; onClicked: root.requestReview() }
            SettingsButton { objectName: "settings-save"; text: "Save changes"; enabled: root.hasStaged && !root.applyUnresolved && !previewProcess.running; primary: true; onClicked: root.save() }
          }
        }
      }
    }
    Rectangle {
      visible: root.reviewOpen
      anchors.fill: parent
      color: Theme.alpha(Theme.settingsColor("#0a0c17"), 0.76)
      MouseArea { anchors.fill: parent; onClicked: root.reviewOpen = false }
      Rectangle {
        width: Math.min(800, parent.width - 40); height: Math.min(620, parent.height - 40)
        anchors.centerIn: parent
        radius: 13; color: Theme.settingsColor("#202638"); border.color: Theme.settingsColor("#586787")
        Keys.onEscapePressed: { root.reviewOpen = false; search.forceActiveFocus(); }
        MouseArea { anchors.fill: parent }
        ColumnLayout {
          anchors.fill: parent; anchors.margins: 22; spacing: 12
          RowLayout {
            Layout.fillWidth: true
            Text { text: "Review changes"; color: Theme.settingsColor("#ddd9ff"); font.pixelSize: 25; font.bold: true }
            Item { Layout.fillWidth: true }
            SettingsButton { text: "✕"; Accessible.name: "Cancel review"; onClicked: { root.reviewOpen = false; search.forceActiveFocus(); } }
          }
          Text { text: root.reviewPlan && root.reviewPlan.retry_native && root.reviewPlan.files.length === 0 ? "Reapply the saved Desktop choices to Hyprland. No configuration files will change." : "These exact files will change only after you choose Save changes."; wrapMode: Text.Wrap; Layout.fillWidth: true; color: Theme.settingsColor("#b0b8d8"); font.pixelSize: 13 }
          Text { text: "Files to be modified (" + (root.reviewPlan ? root.reviewPlan.files.length : 0) + ")"; color: Theme.settingsColor("#d1d8ef"); font.pixelSize: 13 }
          QQC.ScrollView {
            Layout.fillWidth: true; Layout.fillHeight: true
            QQC.TextArea {
              objectName: "settings-review-diff"
              readOnly: true
              wrapMode: TextEdit.NoWrap
              textFormat: TextEdit.RichText
              text: root.reviewDiff()
              font.family: "monospace"; font.pixelSize: 11
              color: Theme.settingsColor("#d3d9ef")
              background: Rectangle { color: Theme.settingsColor("#151a27"); radius: 7 }
            }
          }
          Text { visible: !!root.reviewPlan && !!root.reviewPlan.warnings && root.reviewPlan.warnings.length > 0; text: root.reviewPlan && root.reviewPlan.warnings ? root.reviewPlan.warnings.join("\n") : ""; color: Theme.settingsColor("#eec588"); wrapMode: Text.Wrap; Layout.fillWidth: true }
          Text { visible: !!root.reviewPlan && !!root.reviewPlan.manual; text: root.reviewPlan ? root.reviewPlan.manual || "" : ""; color: Theme.settingsColor("#eec588"); wrapMode: Text.Wrap; Layout.fillWidth: true }
          Text { visible: !!root.reviewPlan && !root.reviewPlan.manual && !!root.reviewPlan.next_action; text: root.reviewPlan ? "After saving: " + (root.reviewPlan.next_action || "") : ""; color: Theme.settingsColor("#eec588"); wrapMode: Text.Wrap; Layout.fillWidth: true }
          Rectangle {
            Layout.fillWidth: true; implicitHeight: 60
            color: Theme.settingsColor("#243552"); border.color: Theme.settingsColor("#466db0"); radius: 8
            Column {
              anchors.fill: parent; anchors.margins: 12; spacing: 5
              Text { text: "Checked Apply"; color: Theme.settingsColor("#dce5ff"); font.pixelSize: 13; font.bold: true }
              Text { text: "Paperland rechecks reviewed inputs and backs up files before writing."; color: Theme.settingsColor("#b3c5e9"); font.pixelSize: 12 }
            }
          }
          RowLayout {
            Layout.fillWidth: true
            Item { Layout.fillWidth: true }
            SettingsButton { id: reviewCancel; text: "Cancel"; onClicked: { root.reviewOpen = false; search.forceActiveFocus(); } }
            SettingsButton { objectName: "settings-confirm-save"; text: "Save changes"; primary: true; enabled: !!root.reviewPlan && (root.reviewPlan.files.length > 0 || !!root.reviewPlan.plugin_link || root.reviewPlan.retry_native === true); onClicked: root.apply() }
          }
        }
      }
    }
    Rectangle {
      visible: root.confirmClose
      onVisibleChanged: if (visible) Qt.callLater(function() { keepEditing.forceActiveFocus(); })
      Keys.onEscapePressed: { root.confirmClose = false; search.forceActiveFocus(); }
      anchors.fill: parent; color: Theme.alpha(Theme.settingsColor("#0a0c17"), 0.76)
      MouseArea { anchors.fill: parent }
      Rectangle {
        anchors.centerIn: parent; width: Math.min(550, parent.width - 40); height: 160
        radius: 13; color: Theme.settingsColor("#202638"); border.color: Theme.settingsColor("#586787")
        ColumnLayout {
          anchors.fill: parent; anchors.margins: 22; spacing: 14
          Text { text: "Save your changes before closing?"; color: Theme.settingsColor("#ddd9ff"); font.pixelSize: 20 }
          Text { text: "Your settings have not been saved."; color: Theme.settingsColor("#b0b8d8"); font.pixelSize: 13 }
          RowLayout {
            SettingsButton { id: keepEditing; objectName: "settings-keep-editing"; text: "Keep editing"; onClicked: { root.confirmClose = false; root.restoreFocus(); } }
            SettingsButton { objectName: "settings-close-discard"; text: "Discard"; onClicked: { root.confirmClose = false; root.discard(); root.opened = false; } }
            SettingsButton { objectName: "settings-close-save"; text: "Save changes"; primary: true; onClicked: { root.confirmClose = false; root.closeAfterSave = true; root.save(); } }
          }
        }
      }
    }
    Rectangle {
      id: jumpOutline
      objectName: "settings-jump-outline"
      visible: false
      color: "transparent"
      radius: 10
      border.color: Theme.settingsColor("#7b9aff")
      border.width: 2
    }
    Timer {
      id: jumpFlash
      interval: 1400
      onTriggered: {
        jumpOutline.visible = false;
        root.clearPendingScroll();
      }
    }

  }
}
