pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as QQC

// Paperland's Bar quick menu. A pure view: the Bar widget owns status reads
// and commands, passes in the last confirmed status and acts on chosen().
FocusScope {
  id: root
  objectName: "paperland-quick-menu"
  /** Last confirmed status from parseStatus(), or null while unknown. */
  property var status: null
  /** Non-empty when status could not be read; every control is then disabled. */
  property string error: ""
  /** 1: status-confirmed running, 0: confirmed absent, -1: unknown. */
  property int runtimeState: -1
  /**
   * Key of the control whose command is running. Input is ignored meanwhile,
   * silently: every control keeps its confirmed look, so a fast change does
   * not flash, until readback replaces the status.
   */
  property string pending: ""
  /** The last command's failure, naming its control. */
  property string alert: ""
  /** Hyprland's confirmed scrolling:focus_fit_method from parseCentering(): 0 centers, 1 packs, -1 unknown. */
  property int centering: -1
  /** Why centering is unknown after a failed read; empty while the first read runs. */
  property string centeringError: ""
  property color foreground: "#e0ddd6"
  property color background: "#110e1b"
  property color accent: "#c590df"
  property color accentInk: "#101010"
  property color urgent: "#d67471"
  property color tooltipBackground: background
  property color tooltipForeground: foreground
  property color tooltipBorder: foreground
  property string fontFamily: "monospace"
  property real fontSize: 12
  property int focusIndex: 0
  // Tooltips follow keyboard focus only after the user navigates; the focus
  // set when the menu opens never shows one.
  property bool keyboardNavigated: false
  signal chosen(string action)
  signal cancelled()
  readonly property bool available: !!status && error === ""
  readonly property bool busy: pending !== ""
  readonly property bool runtimeKnown: available || runtimeState === 0
  readonly property bool runtimeRunning: available
  readonly property bool minimapEnabled: available && (status.visible > 0 || status.activeRows > 0)
  readonly property string minimapLabel: !available ? "Unknown" : status.visible === 0 ? "Hidden"
    : status.visible === status.displays ? "Shown" : "Shown on " + status.visible + " of " + status.displays + " displays"
  // Pinned wins over Peek; neither is Manual. Empty while status is unknown.
  readonly property string mode: !available ? "" : status.pinned ? "pinned" : status.peek ? "peek" : "manual"
  readonly property string reason: runtimeState === 0 ? "Start Paperland to use these controls."
    : error !== "" ? error : !status ? "Reading Paperland status…"
    : !minimapEnabled ? "No active Desktop to show a minimap on" : ""
  // Like every control, centering shows no value while Paperland status is unknown.
  readonly property bool centeringKnown: available && (centering === 0 || centering === 1)
  readonly property string centeringReason: !available ? reason : centeringError !== "" ? centeringError : "Reading Hyprland…"
  // The minimap's own settings (Follow Scratchpad, Strip mode) show beneath it
  // only while a strip is confirmed shown; collapsing changes none of their
  // saved values. Centering is Hyprland's, so it stays whatever the minimap does.
  readonly property bool expanded: available && status.visible > 0
  // Focus order for the keyboard; each control's `order` is its index here.
  // Collapsed children are neither shown nor reachable. The four children
  // sit at 3–6, so every later control shifts by exactly four.
  readonly property var controls: expanded
    ? [runtimeRow, searchRow, minimapRow, followRow, pinnedSegment, peekSegment, manualSegment, centeredSegment, packedSegment, settingsRow]
    : [runtimeRow, searchRow, minimapRow, centeredSegment, packedSegment, settingsRow]
  implicitWidth: 264
  implicitHeight: content.implicitHeight
  // Keep the selection on the same control, or on Minimap when its child
  // disappears. This moves the menu's own selection, never app focus.
  onRuntimeStateChanged: { if (runtimeState === 0) focusIndex = 0; }
  onExpandedChanged: focusIndex = expanded ? (focusIndex >= 3 ? focusIndex + 4 : focusIndex)
    : focusIndex >= 7 ? focusIndex - 4 : Math.min(focusIndex, 2)

  /**
   * Validates a `paperland status` reply for the fields this menu shows.
   * @param {string} text - the command's standard output
   * @param {int} displays - displays the Bar knows about
   * @returns {?{visible: int, displays: int, activeRows: int, pinned: bool, peek: bool, follow: bool}} null when malformed
   */
  function parseStatus(text: string, displays: int): var {
    var reply;
    try { reply = JSON.parse(text); } catch (e) { return null; }
    if (displays < 1 || !reply || typeof reply !== "object" || !Number.isInteger(reply.visibleMinimaps)
        || reply.visibleMinimaps < 0 || reply.visibleMinimaps > displays || !Array.isArray(reply.rows)
        || !reply.rows.every(function(row) { return !!row && typeof row.active === "boolean"; })
        || typeof reply.pinned !== "boolean" || typeof reply.peek !== "boolean"
        || typeof reply.scratchpadFollow !== "boolean") return null;
    return { visible: reply.visibleMinimaps, displays: displays,
      activeRows: reply.rows.filter(function(row) { return row.active; }).length,
      pinned: reply.pinned, peek: reply.peek, follow: reply.scratchpadFollow };
  }
  /** Only a successful, structurally valid empty instance list proves absence. */
  function parseStopped(text: string): bool {
    var instances;
    try { instances = JSON.parse(text); } catch (e) { return false; }
    return Array.isArray(instances) && instances.length === 0;
  }
  /**
   * Validates `hyprctl getoption scrolling:focus_fit_method -j`.
   * @param {string} text - the command's standard output
   * @returns {int} 0 or 1, or -1 for anything else
   */
  function parseCentering(text: string): int {
    var reply;
    try { reply = JSON.parse(text); } catch (e) { return -1; }
    return !!reply && typeof reply === "object" && reply.option === "scrolling:focus_fit_method"
      && (reply.int === 0 || reply.int === 1) ? reply.int : -1;
  }
  /**
   * Columns in a centering choice's preview, in glyph units of a 54 × 18
   * glyph whose viewport interior spans x 3–51. Centered shows the first
   * column held in the middle: blank space on its left, where no column
   * exists, and the strip continuing to the right edge. Packed shows it just
   * revealed beside the right edge, neighbours packed toward it.
   * @param {string} kind - "fit-centered", "fit-packed" or anything else
   * @returns {Array<{x: real, w: real, focused: bool}>}
   */
  function fitColumns(kind: string): var {
    if (kind === "fit-centered")
      return [{ x: 20, w: 14, focused: true }, { x: 36, w: 7, focused: false }, { x: 45, w: 6, focused: false }];
    if (kind === "fit-packed")
      return [{ x: 3, w: 6, focused: false }, { x: 11, w: 10, focused: false }, { x: 23, w: 10, focused: false },
        { x: 35, w: 14, focused: true }];
    return [];
  }
  /** Whether a segment is the confirmed choice; nothing is while its value is unknown. */
  function isPicked(key: string): bool {
    return key === "mode-" + mode
      || centeringKnown && key === (centering === 0 ? "centering-centered" : "centering-packed");
  }
  function reset(): void { focusIndex = runtimeState === 0 ? 0 : 1; keyboardNavigated = false; }
  // Choosing the other centering choice is the Widget's one "centering" toggle.
  // Only a control in the current focus order can act, so a collapsed child
  // cannot, whether by pointer, keyboard or accessibility.
  function activate(key: string): void {
    var centeringChoice = key.indexOf("centering-") === 0;
    if (key === "runtime") {
      if (!busy && runtimeKnown) chosen(key);
      return;
    }
    if (busy || !available || isPicked(key) || (key === "minimap" && !minimapEnabled)
        || (centeringChoice && !centeringKnown)
        || !controls.some(function(control) { return control.key === key; })) return;
    chosen(centeringChoice ? "centering" : key);
  }
  function move(step: int): void {
    focusIndex = (focusIndex + step + controls.length) % controls.length;
    keyboardNavigated = true;
  }
  function tint(color: color, opacity: real): color { return Qt.rgba(color.r, color.g, color.b, opacity); }
  function css(color: color, opacity: real): string {
    return "rgba(" + Math.round(color.r * 255) + "," + Math.round(color.g * 255) + "," + Math.round(color.b * 255) + "," + opacity + ")";
  }
  /**
   * Paints Paperland's stacked-cards mark: a filled centre card between 55 % flanks.
   * @param {object} context - a Canvas 2D context
   * @param {real} size - square canvas size in pixels
   * @param {color} flank - flank colour
   * @param {color} centre - centre card colour
   */
  function paintMark(context: var, size: real, flank: color, centre: color): void {
    context.reset();
    context.scale(size / 16, size / 16);
    context.fillStyle = css(flank, 0.55);
    context.beginPath(); context.roundedRect(0, 4, 3, 8, 1, 1); context.roundedRect(13, 4, 3, 8, 1, 1); context.fill();
    context.fillStyle = css(centre, 1);
    context.beginPath(); context.roundedRect(4, 2, 8, 12, 1.5, 1.5); context.fill();
  }

  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Escape) root.cancelled();
    else if (root.busy) event.accepted = true; // a running command holds every control still
    // Wayland hosts can deliver Shift+Tab as Tab with Shift rather than Backtab.
    else if (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier)) root.move(-1);
    else if ([Qt.Key_Down, Qt.Key_Right, Qt.Key_Tab].indexOf(event.key) >= 0) root.move(1);
    else if ([Qt.Key_Up, Qt.Key_Left, Qt.Key_Backtab].indexOf(event.key) >= 0) root.move(-1);
    else if ([Qt.Key_Enter, Qt.Key_Return, Qt.Key_Space].indexOf(event.key) >= 0) root.activate(root.controls[root.focusIndex].key);
    else return;
    event.accepted = true;
  }

  Column {
    id: content
    width: root.width
    spacing: 6
    Item {
      width: parent.width; height: 40
      Canvas {
        id: headerMark
        x: 8; y: 8; width: 24; height: 24
        onPaint: root.paintMark(getContext("2d"), width, root.foreground, root.foreground)
        Connections { target: root; function onForegroundChanged() { headerMark.requestPaint(); } }
      }
      Text {
        x: 42; y: 3
        text: "Paperland"
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily; font.pixelSize: root.fontSize + 2; font.weight: Font.DemiBold
      }
      QQC.AbstractButton {
        id: runtimeRow
        objectName: "quick-runtime"
        readonly property string key: "runtime"
        readonly property int order: 0
        x: 42; y: 18; width: parent.width - 42; height: 22
        enabled: root.runtimeKnown
        focusPolicy: Qt.NoFocus
        hoverEnabled: true
        Accessible.role: Accessible.Button
        Accessible.name: root.runtimeKnown ? root.runtimeRunning ? "Stop Paperland" : "Start Paperland"
          : "Paperland application, " + runtimeText.text
        Accessible.description: runtimeTip.label
        Accessible.onPressAction: root.activate(key)
        onClicked: root.activate(key)
        background: Rectangle {
          radius: 4
          color: runtimeRow.hovered ? root.tint(root.accent, 0.18) : "transparent"
          FocusRing { visible: root.activeFocus && root.focusIndex === 0; radius: 4 }
        }
        contentItem: Item {
          Text {
            id: runtimeText
            objectName: "quick-status"
            anchors.verticalCenter: parent.verticalCenter
            x: 20; width: parent.width - 20
            text: root.runtimeRunning ? "Running" : root.runtimeState === 0 ? "Stopped"
              : root.error !== "" ? "Status unavailable" : "Checking…"
            textFormat: Text.PlainText
            color: root.tint(root.foreground, 0.72)
            font.family: root.fontFamily; font.pixelSize: root.fontSize - 1
          }
          Glyph {
            objectName: "quick-runtime-glyph"
            visible: root.runtimeKnown
            anchors.verticalCenter: parent.verticalCenter
            width: 12; height: 12
            kind: root.runtimeRunning ? "stop" : "play"
            stroke: root.foreground
          }
        }
        Tip {
          id: runtimeTip
          objectName: "quick-runtime-tip"
          owner: runtimeRow; ownerIndex: 0
          label: !root.runtimeKnown ? root.reason : root.runtimeRunning
            ? "Stop Paperland for this session. Resolve unsaved Settings changes first. Start at login stays unchanged."
            : "Start Paperland hidden for this session. Start at login stays unchanged."
        }
      }
    }
    Divider {}
    ActionRow {
      id: searchRow
      objectName: "quick-search"
      key: "search"; order: 1
      glyph: "search"; label: "Search windows"
      tipText: root.available ? "Search all windows." : root.reason
    }
    Divider {}
    Text {
      objectName: "quick-alert"
      visible: root.alert !== ""
      x: 4; width: parent.width - 8
      text: root.alert
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      color: root.urgent
      font.family: root.fontFamily; font.pixelSize: root.fontSize
      Accessible.role: Accessible.AlertMessage
      Accessible.name: text
    }
    Text {
      objectName: "quick-reason"
      visible: root.reason !== ""
      x: 4; width: parent.width - 8
      text: root.reason
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      color: root.tint(root.foreground, 0.72)
      font.family: root.fontFamily; font.pixelSize: root.fontSize - 1
      Accessible.role: Accessible.StaticText
      Accessible.name: text
    }
    SwitchRow {
      id: minimapRow
      objectName: "quick-minimap"
      key: "minimap"; order: 2
      label: "Minimap"
      enabled: root.minimapEnabled
      on: root.expanded
      // Shown on some displays only: on, since pressing it hides them all.
      Accessible.checkStateMixed: root.expanded && root.status.visible < root.status.displays
      stateText: root.minimapLabel
      tipText: !root.minimapEnabled ? root.reason
        : root.status.visible > 0 ? "Hide the minimap on every display." : "Show the minimap on every display."
    }
    // The minimap's settings, indented beneath it while a strip is shown.
    Column {
      id: minimapChildren
      objectName: "quick-minimap-children"
      visible: root.expanded
      x: 12; width: root.width - 12
      spacing: 6
      SwitchRow {
        id: followRow
        objectName: "quick-follow"
        key: "follow"; order: 3
        width: parent.width
        label: "Follow Scratchpad"
        on: root.available && root.status.follow
        stateText: !root.available ? "Unknown" : root.status.follow ? "On" : "Off"
        tipText: root.available ? "Show the open Scratchpad’s windows in the minimap on its display." : root.reason
      }
      Text {
        objectName: "quick-mode-title"
        x: 4
        text: "Strip mode"
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily; font.pixelSize: root.fontSize
      }
      Rectangle {
        id: modeGroup
        width: parent.width; height: 28
        radius: 8
        color: "transparent"
        border.color: root.tint(root.foreground, 0.14); border.width: 1
        Accessible.role: Accessible.Grouping
        Accessible.name: "Strip mode"
        Row {
          Segment { id: pinnedSegment; objectName: "quick-mode-pinned"; key: "mode-pinned"; order: 4; width: modeGroup.width / 3; label: "Pinned"; tipText: "Always visible." }
          Segment { id: peekSegment; objectName: "quick-mode-peek"; key: "mode-peek"; order: 5; width: modeGroup.width / 3; label: "Peek"; tipText: "Appears as you navigate, then hides." }
          Segment { id: manualSegment; objectName: "quick-mode-manual"; key: "mode-manual"; order: 6; width: modeGroup.width / 3; label: "Manual"; tipText: "Stays as you leave it until you show or hide it." }
        }
      }
    }
    Divider {}
    Text {
      objectName: "quick-centering-title"
      x: 4
      text: "Center focused column"
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily; font.pixelSize: root.fontSize
    }
    // Hyprland's own fit policy, applied from the next focus change, so
    // nothing moves when a choice is pressed.
    Rectangle {
      id: centeringGroup
      objectName: "quick-centering"
      width: parent.width; height: centeredSegment.height
      radius: 8
      color: "transparent"
      border.color: root.tint(root.foreground, 0.14); border.width: 1
      Accessible.role: Accessible.Grouping
      Accessible.name: "Center focused column"
      Row {
        Segment {
          id: centeredSegment; objectName: "quick-centering-centered"; key: "centering-centered"; order: root.expanded ? 7 : 3
          width: centeringGroup.width / 2; label: "Centered"; glyph: "fit-centered"
          enabled: root.centeringKnown
          tipText: root.centeringKnown ? "Keep the focused column centered, even the first one, which leaves empty space to its left. Applies to all displays from the next focus change."
            : root.centeringReason
        }
        Segment {
          id: packedSegment; objectName: "quick-centering-packed"; key: "centering-packed"; order: root.expanded ? 8 : 4
          width: centeringGroup.width / 2; label: "Packed"; glyph: "fit-packed"
          enabled: root.centeringKnown
          tipText: root.centeringKnown ? "Scroll only far enough to show the focused column; it isn’t always held at an edge. Applies to all displays from the next focus change."
            : root.centeringReason
        }
      }
    }
    // Only a failed or unsupported reading earns a visible line; explanations
    // live in the tooltips, and Paperland's own reason is shown above.
    Text {
      objectName: "quick-centering-description"
      visible: root.available && !root.centeringKnown && root.centeringError !== ""
      x: 4; width: parent.width - 8
      text: root.centeringError
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      color: root.tint(root.foreground, 0.72)
      font.family: root.fontFamily; font.pixelSize: root.fontSize - 1
    }
    Divider {}
    ActionRow {
      id: settingsRow
      objectName: "quick-settings"
      key: "settings"; order: root.expanded ? 9 : 5
      glyph: "settings"; label: "Paperland Settings…"
      tipText: root.available ? "Open Paperland Settings." : root.reason
    }
  }

  component Divider: Rectangle { width: root.width; height: 1; color: root.tint(root.foreground, 0.12) }
  component FocusRing: Rectangle {
    anchors.fill: parent; anchors.margins: 2
    color: "transparent"
    border.color: root.foreground; border.width: 2
  }
  // Line glyphs 18 units tall, drawn in the control's ink; a wider glyph
  // gains width in the same units.
  component Glyph: Canvas {
    id: glyph
    property string kind
    property color stroke
    readonly property var columns: root.fitColumns(kind)
    width: 18; height: 18
    onStrokeChanged: requestPaint()
    onKindChanged: requestPaint()
    onPaint: {
      var c = getContext("2d");
      c.reset(); c.scale(height / 18, height / 18);
      c.strokeStyle = root.css(glyph.stroke, 1); c.fillStyle = root.css(glyph.stroke, 1);
      c.lineWidth = 1.4; c.lineCap = "round"; c.lineJoin = "round";
      c.beginPath();
      if (glyph.kind === "stop") {
        c.fillRect(3, 3, 12, 12);
      } else if (glyph.kind === "play") {
        c.moveTo(4.5, 1.5); c.lineTo(16.5, 9); c.lineTo(4.5, 16.5); c.closePath(); c.fill();
      } else if (glyph.kind === "settings") {
        c.arc(9, 9, 4.3, 0, 2 * Math.PI);
        for (var t = 0; t < 8; t++) {
          var a = t * Math.PI / 4;
          c.moveTo(9 + 4.3 * Math.cos(a), 9 + 4.3 * Math.sin(a)); c.lineTo(9 + 6.2 * Math.cos(a), 9 + 6.2 * Math.sin(a));
        }
        c.moveTo(11, 9); c.arc(9, 9, 2, 0, 2 * Math.PI); c.stroke();
      } else if (glyph.kind.indexOf("fit-") === 0) {
        // A 54 × 18 viewport; fitColumns() places the strip inside it.
        c.roundedRect(1.5, 2.5, 51, 13, 2, 2); c.stroke();
        glyph.columns.forEach(function(column) {
          c.fillStyle = root.css(glyph.stroke, column.focused ? 1 : 0.4);
          c.beginPath(); c.roundedRect(column.x, 5, column.w, 8, 1, 1); c.fill();
        });
      } else {
        c.arc(8, 8, 4.5, 0, 2 * Math.PI); c.moveTo(11.5, 11.5); c.lineTo(15, 15); c.stroke();
      }
    }
  }
  // A control is disabled and dimmed only while its value is unavailable. A
  // running command does not disable anything: activate() and the key handler
  // ignore input, so hover, colours and labels stay exactly as confirmed.
  //
  // A full-width on/off row: label and confirmed state on the left, a switch
  // on the right. The thumb follows the confirmed `on`, never the press; while
  // status is unknown the track is an empty outline, never the Off position.
  component SwitchRow: QQC.AbstractButton {
    id: switchRow
    required property string key
    required property int order
    property string label
    property string stateText
    property string tipText
    property bool on: false
    width: root.width; height: Math.max(30, labels.implicitHeight + 10)
    enabled: root.available
    opacity: enabled ? 1 : 0.45
    focusPolicy: Qt.NoFocus
    hoverEnabled: true
    Accessible.role: Accessible.CheckBox
    Accessible.name: label + ", " + stateText
    Accessible.checkable: true
    Accessible.checked: on
    Accessible.description: switchTip.label
    Accessible.onPressAction: root.activate(key)
    onClicked: root.activate(key)
    background: Rectangle {
      radius: 6
      color: switchRow.hovered ? root.tint(root.accent, 0.18) : "transparent"
      FocusRing { visible: root.activeFocus && root.focusIndex === switchRow.order; radius: 6 }
    }
    // The state wraps rather than elides: a partial display count is long.
    contentItem: Item {
      Column {
        id: labels
        x: 8; width: track.x - 16
        anchors.verticalCenter: parent.verticalCenter
        Text {
          objectName: switchRow.objectName + "-title"
          width: parent.width
          text: switchRow.label
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          color: root.foreground
          font.family: root.fontFamily; font.pixelSize: root.fontSize + 1
        }
        Text {
          objectName: switchRow.objectName + "-state"
          width: parent.width
          text: switchRow.stateText
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          color: root.tint(root.foreground, 0.72)
          font.family: root.fontFamily; font.pixelSize: root.fontSize - 1
        }
      }
      Rectangle {
        id: track
        objectName: switchRow.objectName + "-track"
        x: parent.width - width - 8
        anchors.verticalCenter: parent.verticalCenter
        width: 30; height: 18; radius: 9
        color: !root.available ? "transparent" : switchRow.on ? root.accent : root.tint(root.foreground, 0.25)
        border.color: root.tint(root.foreground, 0.5); border.width: root.available ? 0 : 1
        Rectangle {
          objectName: switchRow.objectName + "-thumb"
          visible: root.available
          x: switchRow.on ? parent.width - width - 3 : 3; y: 3
          width: 12; height: 12; radius: 6
          color: switchRow.on ? root.accentInk : root.foreground
        }
      }
    }
    Tip { id: switchTip; objectName: switchRow.objectName + "-tip"; owner: switchRow; ownerIndex: switchRow.order; label: switchRow.tipText }
  }
  // One choice of a split control; the confirmed one is an inset accent fill.
  // Strip mode's are text only; a `glyph` adds a layout preview above the label.
  component Segment: QQC.AbstractButton {
    id: segment
    required property string key
    required property int order
    property string label
    property string tipText
    property string glyph: ""
    readonly property bool picked: root.isPicked(key)
    topPadding: glyph === "" ? 0 : 31
    bottomPadding: glyph === "" ? 0 : 6
    height: glyph === "" ? 28 : topPadding + bottomPadding + contentItem.implicitHeight
    enabled: root.available
    opacity: enabled ? 1 : 0.45
    focusPolicy: Qt.NoFocus
    hoverEnabled: true
    Accessible.role: Accessible.RadioButton
    Accessible.name: label
    Accessible.checkable: true
    Accessible.checked: picked
    Accessible.description: segmentTip.label
    Accessible.onPressAction: root.activate(key)
    onClicked: root.activate(key)
    background: Item {
      Rectangle {
        anchors.fill: parent; anchors.margins: 2
        radius: 6
        color: segment.picked ? root.accent : segment.hovered ? root.tint(root.foreground, 0.08) : "transparent"
      }
      // 60 × 20 px keeps fitColumns()' 54-unit viewport.
      Glyph {
        objectName: segment.objectName + "-glyph"
        visible: segment.glyph !== ""
        anchors.horizontalCenter: parent.horizontalCenter
        y: 7; width: 60; height: 20
        kind: segment.glyph; stroke: segment.picked ? root.accentInk : root.foreground
      }
      FocusRing { visible: root.activeFocus && root.focusIndex === segment.order; radius: 6 }
    }
    contentItem: Text {
      text: segment.label
      textFormat: Text.PlainText
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      color: segment.picked ? root.accentInk : root.foreground
      font.family: root.fontFamily; font.pixelSize: root.fontSize
      font.weight: segment.picked ? Font.DemiBold : Font.Normal
    }
    Tip {
      id: segmentTip
      objectName: segment.objectName + "-tip"
      owner: segment; ownerIndex: segment.order
      label: root.available ? segment.tipText : root.reason
    }
  }
  component ActionRow: QQC.AbstractButton {
    id: row
    required property string key
    required property int order
    property string glyph
    property string label
    property string tipText
    width: root.width; height: 30
    enabled: root.available
    opacity: enabled ? 1 : 0.45
    focusPolicy: Qt.NoFocus
    hoverEnabled: true
    Accessible.role: Accessible.Button
    Accessible.name: label
    Accessible.description: rowTip.label
    Accessible.onPressAction: root.activate(key)
    onClicked: root.activate(key)
    background: Rectangle {
      radius: 6
      color: row.hovered ? root.tint(root.accent, 0.18) : "transparent"
      FocusRing { visible: root.activeFocus && root.focusIndex === row.order; radius: 6 }
    }
    contentItem: Item {
      Glyph { x: 8; y: 7; width: 16; height: 16; kind: row.glyph; stroke: root.foreground }
      Text {
        x: 34; anchors.verticalCenter: parent.verticalCenter
        text: row.label
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily; font.pixelSize: root.fontSize + 1
      }
    }
    Tip { id: rowTip; objectName: row.objectName + "-tip"; owner: row; ownerIndex: row.order; label: row.tipText }
  }
  // Host tooltip look, wrapped within the menu. Shown on hover, or on keyboard
  // focus once the user has navigated.
  component Tip: QQC.ToolTip {
    id: tipItem
    required property QQC.AbstractButton owner
    required property int ownerIndex
    property string label
    // A collapsed child's index may belong to another control; its tip stays shut.
    visible: label !== "" && owner.visible
      && (owner.hovered || root.keyboardNavigated && root.activeFocus && root.focusIndex === ownerIndex)
    delay: 500
    leftPadding: 10; rightPadding: 10; topPadding: 6; bottomPadding: 6
    // The popup sizes its content to availableWidth, overriding any width on
    // the Text itself; capping the popup is what makes the text wrap.
    width: Math.min(implicitWidth, root.width - 16)
    contentItem: Text {
      text: tipItem.label
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      color: root.tooltipForeground
      font.family: root.fontFamily; font.pixelSize: 11
    }
    background: Rectangle { color: root.tooltipBackground; border.color: root.tooltipBorder; border.width: 1 }
  }
}
