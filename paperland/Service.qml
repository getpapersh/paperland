import QtQuick
import Quickshell.Hyprland
import Quickshell.Io
import "Layout.js" as Layout
import "Switcher.js" as Switcher
import "shared/WorkspaceCatalog.js" as Catalog
import "shared/Scratchpad.js" as Scratchpad
import "shared/WindowDestinations.js" as Destinations
import "NamesLogic.js" as Names

Item {
  id: root
  property bool expanded: false
  readonly property var allWindows: Switcher.windows(
    Hyprland.toplevels.values.map(function(w) { return w.lastIpcObject; }),
    Hyprland.monitors.values.map(function(m) { return m.lastIpcObject; }))
  readonly property var catalog: Catalog.build(
    Hyprland.monitors.values.map(function(m) { return m.lastIpcObject; }),
    Hyprland.workspaces.values.map(function(w) { return w.lastIpcObject; }),
    Hyprland.toplevels.values.map(function(w) { return w.lastIpcObject; }))
  readonly property var scratchpadEntry: Scratchpad.build(
    Hyprland.toplevels.values.map(function(w) { return w.lastIpcObject; }))
  property var scratchpadBinding: null
  // Live `hyprctl -j binds`, for showing the shortcuts the user actually has.
  property var bindings: []
  function scratchpadForMonitor(monitor: string): var {
    var monitors = Hyprland.monitors.values.map(function(m) {
      return { name: m.name, lastIpcObject: m.lastIpcObject };
    });
    var open = Scratchpad.isOpenOn(monitors, monitor);
    return Scratchpad.forMonitor(scratchpadEntry, monitor, open, open && focusedMonitor === monitor);
  }
  function workspacesFor(monitor: string): var { return Catalog.forMonitor(catalog, monitor); }
  // Whether a display's strip may show the open scratchpad row. Persisted by
  // shell.qml; see setScratchpadFollow.
  property bool scratchpadFollow: true
  signal followRequested(bool value)
  function setScratchpadFollow(value: bool): void {
    if (value === scratchpadFollow) return;
    scratchpadFollow = value;
    followRequested(value);
  }
  readonly property var destinations: Destinations.entries(
    Hyprland.monitors.values.map(function(m) { return m.lastIpcObject; }),
    Hyprland.workspaces.values.map(function(w) { return w.lastIpcObject; }))
  readonly property string focusedMonitor: Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
  property bool moveBusy: false
  property string moveMessage: ""
  property var moveTarget: null
  property var moveDestination: null
  property bool moveFollow: false
  property string movePhase: ""
  property string moveOutput: ""
  property string moveError: ""
  property int movePolls: 0
  signal moveFinished(bool success)
  property bool groupActive: false
  property var groupTargets: []
  property var groupMoved: []
  property string groupNotice: ""
  property int groupIndex: 0
  property int groupSource: 0
  property string groupSourceSelector: ""
  property string groupSourceMonitor: ""
  property var groupDestination: null
  property var groupReorderPlan: null
  property var groupReorderIds: ({})
  property bool groupReorderVertical: false
  property var groupStacks: []
  property string groupSourceFocus: ""
  property string groupFailureReason: ""
  signal groupFinished(bool success)

  function moveGroup(addresses: var, workspace: int, source: int, reorder: var, selectedIds: var, offered: var): bool {
    if (moveBusy || groupActive) return false;
    groupNotice = "";
    var row = rows[source];
    var destination = reorder && workspace === source ? { kind: "reorder" }
      : workspace === -2 ? { kind: "floating", id: source }
      : workspace === 0 ? { kind: "new" }
      : destinations.find(function(entry) { return entry.kind === "existing" && entry.id === workspace; });
    if (!row || !destination || (workspace === source && !reorder) || !addresses || !addresses.length) {
      moveMessage = "Choose another available Desktop.";
      groupNotice = moveMessage;
      return false;
    }
    if (destination.kind === "existing" && (!offered || offered.id !== destination.id
        || offered.name !== destination.name || offered.monitor !== destination.monitor
        || offered.monitorId !== destination.monitorId || offered.selector !== destination.selector)) {
      moveMessage = "The destination changed. Select it again.";
      groupNotice = moveMessage;
      return false;
    }
    var targets = [];
    for (var i = 0; i < addresses.length; i++) {
      var address = addresses[i], window = allWindows[address];
      if (!window || !window.stableId || !selectedIds || selectedIds[address] !== window.stableId
          || !row.windows.some(function(item) { return item.address === address && item.stableId === selectedIds[address]; })
          || targets.some(function(item) { return item.address === address; })) {
        moveMessage = "The selection changed. Select the windows again.";
        groupNotice = moveMessage;
        return false;
      }
      targets.push({ address: address, stableId: window.stableId, sourceWorkspace: source });
    }
    if (destination.kind === "reorder") {
      var anchor = allWindows[reorder.anchor];
      var plan = typeof reorder.after === "boolean" && anchor && anchor.stableId
        && row.windows.some(function(window) { return window.address === reorder.anchor; })
        ? Layout.reorderPlan(row, addresses, reorder.anchor, reorder.after) : null;
      if (!plan) {
        moveMessage = "The reorder target changed. Try again.";
        groupNotice = moveMessage;
        return false;
      }
      if (!plan.steps.length) { moveMessage = "Already in that position."; groupFinished(true); return true; }
      return runGroupReorder(plan, source, targets);
    }
    groupTargets = targets; groupDestination = destination; groupSource = source;
    groupSourceSelector = row.name === "special:scratchpad" ? row.name : String(source);
    groupSourceMonitor = row.monitor;
    groupStacks = Layout.columns(row).filter(function(column) {
      return column.windows.length > 1 && column.windows.every(function(window) { return addresses.indexOf(window.address) >= 0; });
    }).map(function(column) { return column.windows.map(function(window) { return allWindows[window.address].stableId; }); });
    groupSourceFocus = allWindows[focusedAddress] && row.windows.some(function(window) { return window.address === focusedAddress; })
      ? allWindows[focusedAddress].stableId : "";
    groupMoved = []; groupIndex = 0; groupActive = true;
    runNextGroup();
    return true;
  }
  function runGroupReorder(plan: var, source: int, targets: var): bool {
    var ids = {};
    for (var c = 0; c < plan.desired.length; c++) {
      for (var m = 0; m < plan.desired[c].length; m++) {
        var address = plan.desired[c][m], window = allWindows[address];
        if (!window || !/^[0-9a-f]+$/i.test(window.stableId)) {
          groupNotice = "The source Desktop changed. Try again.";
          moveMessage = groupNotice;
          return false;
        }
        ids[address] = window.stableId;
      }
    }
    var columns = Layout.columns(rows[source]).map(function(column) {
      return column.windows.map(function(window) { return ids[window.address]; });
    });
    var checks = Object.keys(ids).map(function(address) {
      return 'local w=hl.get_window("stableid:' + ids[address] + '"); '
        + 'if not w or not w.mapped or w.floating or not w.workspace or w.workspace.id~=' + source
        + ' then error("The source Desktop changed.") end; ';
    }).join("") + 'local previousIndex=nil; local indexStep=nil; '
      + columns.map(function(column) {
        var check = 'local leader=hl.get_window("stableid:' + column[0] + '"); '
          + 'local native=leader.layout and leader.layout.column; '
          + 'if not native or #native.windows~=' + column.length
          + ' then error("The source columns changed.") end; ';
        column.forEach(function(stableId, index) {
          check += 'if native.windows[' + (index + 1) + ']~=hl.get_window("stableid:' + stableId
            + '") then error("The source stack changed.") end; ';
        });
        return check + 'if previousIndex then local step=native.index-previousIndex; '
          + 'if math.abs(step)~=1 or (indexStep and step~=indexStep) '
          + 'then error("The source order changed.") end; indexStep=step end; '
          + 'previousIndex=native.index; ';
      }).join("");
    var operations = plan.steps.map(function(step) {
      var stableId = ids[step.address];
      var action = step.kind === "promote" ? "promote" : "swapcol " + step.direction;
      return 'local f=hl.dispatch(hl.dsp.focus({window="stableid:' + stableId + '"})); '
        + 'if not f or not f.ok then error("Could not focus a selected window.") end; '
        + 'local r=hl.dispatch(hl.dsp.layout("' + action + '")); '
        + 'if not r or not r.ok then error("Native reorder failed.") end; ';
    }).join("");
    groupSource = source; groupSourceSelector = rows[source].name === "special:scratchpad" ? rows[source].name : String(source);
    groupSourceMonitor = rows[source].monitor;
    var prior = ids[focusedAddress] || "";
    var restore = sourceRestoreCode() + (prior ? 'local prior=hl.get_window("stableid:' + prior + '"); '
      + 'if prior and prior.workspace and prior.workspace.id==' + source
      + ' then hl.dispatch(hl.dsp.focus({window="stableid:' + prior + '"})) '
      + 'end; ' : '');
    groupTargets = targets; groupReorderPlan = plan; groupReorderIds = ids;
    groupReorderVertical = rows[source].vertical; groupActive = true; moveBusy = true;
    moveMessage = "Reordering…";
    runMove("reorder-dispatch", ["hyprctl", "dispatch", 'function() ' + checks + operations + restore + 'end']);
    return true;
  }
  function verifyGroupReorder(clients: var): bool {
    var expected = groupReorderPlan.desired.map(function(column) {
      return column.map(function(address) { return groupReorderIds[address]; });
    });
    var stableIds = Object.keys(groupReorderIds).map(function(address) { return groupReorderIds[address]; });
    var found = clients.filter(function(client) {
      return client.mapped && !client.floating && client.workspace && client.workspace.id === groupSource;
    });
    if (found.length !== stableIds.length || found.some(function(client) {
      return stableIds.indexOf(client.stableId) < 0;
    })) return false;
    var axis = groupReorderVertical ? 1 : 0, cross = groupReorderVertical ? 0 : 1;
    found.sort(function(a, b) { return a.at[axis] - b.at[axis] || a.at[cross] - b.at[cross]; });
    var observed = [];
    found.forEach(function(client) {
      var last = observed[observed.length - 1];
      if (last && last.start === client.at[axis] && last.size === client.size[axis]) last.ids.push(client.stableId);
      else observed.push({ start: client.at[axis], size: client.size[axis], ids: [client.stableId] });
    });
    return JSON.stringify(observed.map(function(column) { return column.ids; })) === JSON.stringify(expected);
  }
  function finishGroupReorder(success: bool, message: string): void {
    moveBusy = false; groupActive = false; moveMessage = message; groupNotice = message;
    refresh(); groupFinished(success);
  }
  function runNextGroup(): void {
    if (!groupActive) return;
    if (groupIndex >= groupTargets.length) {
      if (groupStacks.length && groupDestination.kind !== "floating") {
        movePolls = 0;
        runMove("group-layout", ["hyprctl", "-j", "workspaces"]);
      } else finishGroup(true, groupMoved.length + " windows sent.");
      return;
    }
    var target = groupTargets[groupIndex];
    var sourceRow = rows[groupSource];
    if (!sourceRow || !sourceRow.windows.some(function(window) { return window.address === target.address; })) {
      groupActive = false;
      moveMessage = groupMoved.length + " confirmed moved; " + (groupTargets.length - groupIndex)
        + " not sent. The selection changed. Check their locations.";
      groupNotice = moveMessage;
      groupFinished(false);
      return;
    }
    if (groupDestination.kind === "new") {
      // Choose the ID and move the first window in one compositor call, so no
      // other workspace creator can claim the ID between those two actions.
      var checks = groupTargets.map(function(selected) {
        return 'local selected=hl.get_window("stableid:' + selected.stableId + '"); '
          + 'if not selected or not selected.workspace or selected.workspace.id~=' + groupSource
          + ' then error("The selection changed before dispatch.") end; ';
      }).join("");
      var code = '(function() ' + checks + 'local w=hl.get_window("stableid:' + target.stableId + '"); '
        + 'if not w or not w.workspace or w.workspace.id~=' + groupSource
        + ' then error("That window left its source Desktop.") end; '
        + 'local used={} for _,d in ipairs(hl.get_workspaces()) do if d.id>0 then used[d.id]=true end end; '
        + 'local id=1 while used[id] do id=id+1 end; '
        + 'local result=hl.dispatch(hl.dsp.window.move({window=w,workspace=tostring(id),follow=false})); '
        + 'if not result or not result.ok then error("Native move failed.") end; return id end)()';
      moveTarget = target; moveDestination = null; moveFollow = false;
      movePolls = 0; moveBusy = true; moveMessage = "Sending…";
      runMove("new-dispatch", ["hyprctl", "repl", code]);
    } else if (!dispatchWindow(target, groupDestination, false)) {
      groupActive = false;
      moveMessage = groupMoved.length + " confirmed moved; " + (groupTargets.length - groupIndex)
        + " not sent. Check their locations.";
      groupNotice = moveMessage;
      groupFinished(false);
    }
  }
  function finishGroup(success: bool, message: string): void {
    groupRowWait.stop();
    groupActive = false; moveBusy = false; moveMessage = message; groupNotice = message;
    Hyprland.dispatch('function() ' + sourceRestoreCode() + 'end');
    groupFinished(success);
  }
  function sourceRestoreCode(): string {
    return 'hl.dispatch(hl.dsp.focus({monitor=' + Names.luaQuote(groupSourceMonitor) + '})); '
      + (groupSource < 0 ? 'if hl.get_workspace("special:scratchpad") then ' : '')
      + 'hl.dispatch(hl.dsp.focus({workspace=' + Names.luaQuote(groupSourceSelector) + '})); '
      + (groupSource < 0 ? 'end; ' : '');
  }
  function reconstructGroupStacks(): void {
    var code = 'function() local d=hl.get_workspace("' + groupDestination.id + '"); '
      + 'if not d or d.id~=' + groupDestination.id + ' then error("The destination changed.") end; ';
    groupStacks.forEach(function(stack) {
      stack.forEach(function(stableId) {
        code += 'local w=hl.get_window("stableid:' + stableId + '"); '
          + 'if not w or not w.workspace or w.workspace.id~=' + groupDestination.id
          + ' then error("A moved window changed Desktop.") end; ';
      });
    });
    groupStacks.forEach(function(stack) {
      for (var i = 1; i < stack.length; i++) {
        code += 'local leader=hl.get_window("stableid:' + stack[0] + '"); '
          + 'local wanted=hl.get_window("stableid:' + stack[i] + '"); '
          + 'if not leader or not wanted or not leader.mapped or not wanted.mapped '
          + 'or leader.floating or wanted.floating or not leader.workspace or not wanted.workspace '
          + 'or leader.workspace.id~=d.id or wanted.workspace.id~=d.id '
          + 'then error("A moved window changed layout.") end; '
          + 'local current=leader.layout; local next=wanted.layout; '
          + 'if not current or not next or not current.column or not next.column '
          + 'or next.column.index~=current.column.index+1 or next.column.windows[1]~=wanted '
          + 'then error("The next stack member changed.") end; ';
        code += 'local f=hl.dispatch(hl.dsp.focus({window="stableid:' + stack[0] + '"})); '
          + 'if not f or not f.ok then error("Could not focus the moved stack.") end; '
          + 'local r=hl.dispatch(hl.dsp.layout("consume")); '
          + 'if not r or not r.ok then error("Native stack reconstruction failed.") end; ';
      }
    });
    code += sourceRestoreCode();
    if (groupSourceFocus) {
      code += 'local prior=hl.get_window("stableid:' + groupSourceFocus + '"); '
        + 'if prior and prior.workspace and prior.workspace.id==' + groupSource
        + ' then hl.dispatch(hl.dsp.focus({window="stableid:' + groupSourceFocus + '"})) end; ';
    }
    runMove("group-reconstruct", ["hyprctl", "dispatch", code + 'end']);
  }
  function verifyGroupStacks(clients: var): bool {
    var byId = {};
    clients.forEach(function(client) { byId[client.stableId] = client; });
    return groupStacks.every(function(stack) {
      var members = stack.map(function(stableId) { return byId[stableId]; });
      if (members.some(function(client) { return !client || !client.mapped || !client.workspace
        || client.workspace.id !== groupDestination.id; })) return false;
      var vertical = rows[groupDestination.id] ? rows[groupDestination.id].vertical : false;
      var axis = vertical ? 1 : 0, cross = vertical ? 0 : 1;
      return members.every(function(client) { return client.at[axis] === members[0].at[axis]; })
        && members.every(function(client, index) { return index === 0 || members[index - 1].at[cross] < client.at[cross]; });
    });
  }

  function cancelActivationCheck(): void { activationCheck.stop(); }
  function moveWindow(target: var, destination: var, follow: bool): bool {
    if (groupActive) return false;
    return dispatchWindow(target, destination, follow);
  }
  function dispatchWindow(target: var, destination: var, follow: bool): bool {
    if (moveBusy) return false;
    if (!target || !allWindows[target.address] || !target.stableId
        || allWindows[target.address].stableId !== target.stableId) {
      moveMessage = "That window is no longer available.";
      return false;
    }
    var required = groupActive && groupIndex === 0
      ? groupTargets.map(function(item) { return item.stableId; }) : undefined;
    var command = Destinations.command(target.stableId, destination, follow, Names.luaQuote, target.sourceWorkspace, required);
    if (!command) { moveMessage = "Choose a valid destination."; return false; }
    moveTarget = target; moveDestination = destination; moveFollow = follow;
    movePolls = 0; moveBusy = true; moveMessage = "Sending…";
    runMove("dispatch", ["hyprctl", "dispatch", command]);
    return true;
  }
  function runMove(phase: string, command: var): void {
    movePhase = phase; moveOutput = ""; moveError = "";
    moveProcess.command = command; moveProcess.running = true;
  }
  function finishMove(success: bool, message: string): void {
    moveBusy = false; moveMessage = message; refresh();
    if (groupActive) {
      if (!success) {
        groupActive = false;
        moveMessage = groupMoved.length + " confirmed moved; 1 outcome uncertain; "
          + (groupTargets.length - groupIndex - 1) + " not sent. Check locations before trying again. " + message;
        groupNotice = moveMessage;
        groupFinished(false);
      } else {
        groupMoved = groupMoved.concat([groupTargets[groupIndex].address]);
        groupIndex++;
        Qt.callLater(root.runNextGroup);
      }
    } else moveFinished(success);
  }
  function receiveMove(code: int): void {
    if (movePhase === "group-failure-verify") {
      var clients;
      try { clients = code === 0 ? JSON.parse(moveOutput) : []; }
      catch (error) { clients = []; }
      var target = groupTargets[groupIndex];
      var current = clients.find(function(client) { return client.stableId === target.stableId && client.mapped; });
      var destination = groupDestination;
      var arrived = current && destination && current.workspace && current.workspace.id === destination.id
        && (destination.kind !== "existing" || current.monitor === destination.monitorId)
        && (destination.kind !== "floating" || current.floating);
      var stayed = current && current.workspace && current.workspace.id === groupSource
        && (destination && destination.kind !== "floating" || !current.floating);
      var confirmed = groupMoved.length + (arrived ? 1 : 0);
      finishGroup(false, confirmed + " confirmed moved; " + (stayed ? 1 : 0) + " stayed on source; "
        + (!arrived && !stayed ? 1 : 0) + " uncertain; "
        + (groupTargets.length - groupIndex - 1) + " not sent. " + groupFailureReason);
      return;
    }
    if (movePhase === "group-layout") {
      var workspaces;
      try { workspaces = code === 0 ? JSON.parse(moveOutput) : []; }
      catch (error) { workspaces = []; }
      var workspace = Array.isArray(workspaces)
        ? workspaces.find(function(entry) { return entry.id === groupDestination.id; }) : null;
      if (!workspace) {
        finishGroup(false, groupMoved.length + " windows moved, but the destination layout could not be confirmed. Check their positions.");
      } else if (workspace.tiledLayout !== "scrolling") {
        finishGroup(true, groupMoved.length + " windows moved; the selected stack split on this Desktop.");
      } else reconstructGroupStacks();
      return;
    }
    if (movePhase === "group-reconstruct") {
      if (code !== 0 || moveOutput.trim() !== "ok") {
        finishGroup(false, groupMoved.length + " windows moved, but stack reconstruction stopped. Check their positions. "
          + (moveError.trim() || moveOutput.trim()));
      } else runMove("group-stack-verify", ["hyprctl", "-j", "clients"]);
      return;
    }
    if (movePhase === "group-stack-verify") {
      if (!rows[groupDestination.id] && ++movePolls < 10) {
        refresh(); groupRowWait.restart(); return;
      }
      var stacked;
      try { stacked = code === 0 && verifyGroupStacks(JSON.parse(moveOutput)); }
      catch (error) { stacked = false; }
      finishGroup(stacked, stacked ? groupMoved.length + " windows moved with their stack preserved."
        : groupMoved.length + " windows moved, but the stack could not be confirmed. Check the destination.");
      return;
    }
    if (movePhase === "reorder-dispatch") {
      if (code !== 0 || moveOutput.trim() !== "ok") {
        finishGroupReorder(false, "Native reorder stopped; check current positions. "
          + (moveError.trim() || moveOutput.trim()));
      } else runMove("reorder-verify", ["hyprctl", "-j", "clients"]);
      return;
    }
    if (movePhase === "reorder-verify") {
      var reordered;
      try { reordered = code === 0 && verifyGroupReorder(JSON.parse(moveOutput)); }
      catch (error) { reordered = false; }
      finishGroupReorder(reordered, reordered ? "Selected windows reordered."
        : "Native reorder ran, but the final positions could not be confirmed. Check the Desktop.");
      return;
    }
    if (code !== 0) {
      if (groupActive) {
        var detail = (moveError + " " + moveOutput).trim();
        groupFailureReason = detail.endsWith("That destination changed. Select it again.")
          ? "The destination changed. Select it again."
          : "Native move was not accepted. Check locations before trying again.";
        runMove("group-failure-verify", ["hyprctl", "-j", "clients"]);
      } else finishMove(false, moveError.trim() || moveOutput.trim() || "Native move failed.");
      return;
    }
    if (movePhase === "new-dispatch") {
      var id = Number(moveOutput.trim());
      if (!Number.isInteger(id) || id <= 0) {
        finishMove(false, "The new Desktop ID could not be confirmed. Check window locations before trying again.");
        return;
      }
      groupDestination = { kind: "number", id: id };
      moveDestination = groupDestination;
      moveCheck.restart();
      return;
    }
    if (movePhase === "dispatch") {
      if (moveOutput.trim() !== "ok") { finishMove(false, moveOutput.trim() || "Native move was not accepted."); return; }
      moveCheck.restart();
      return;
    }
    var clients;
    try { clients = JSON.parse(moveOutput); }
    catch (error) { finishMove(false, "Could not confirm the move. Check the window's location before trying again."); return; }
    var window = clients.find(function(c) { return c.stableId === root.moveTarget.stableId && c.mapped; });
    if (!window) { finishMove(false, "The window closed before its move could be confirmed."); return; }
    var destination = moveDestination;
    var placed = window.workspace.id === destination.id;
    if (destination.kind === "existing") placed = placed && window.monitor === destination.monitorId;
    if (destination.kind === "floating") placed = placed && window.floating;
    if (placed && (!moveFollow || window.focusHistoryID === 0)) { finishMove(true, "Window sent."); return; }
    if (++movePolls >= 10) { finishMove(false, "Could not confirm the requested location or focus. Check the window before trying again."); return; }
    moveCheck.restart();
  }
  Process {
    id: moveProcess
    stdout: StdioCollector { onStreamFinished: root.moveOutput = text }
    stderr: StdioCollector { onStreamFinished: root.moveError = text }
    onExited: function(code) { root.receiveMove(code); }
  }
  Timer { id: moveCheck; interval: 100; onTriggered: root.runMove("verify", ["hyprctl", "-j", "clients"]) }
  Timer { id: groupRowWait; interval: 60; onTriggered: if (root.groupActive) root.runMove("group-stack-verify", ["hyprctl", "-j", "clients"]) }
  property string activationError: ""
  property string expectedAddress: ""
  property int expectedWorkspace: 0
  property bool pinned: true
  property string globalDirection: ""
  property var workspaceDirections: ({})
  property var managedDirection: ({ enabled: false, native_direction_available: false, monitors: ({}), desktops: ({}) })
  property int directionEpoch: 0
  property int directionRequestEpoch: 0
  readonly property string monitorGeometrySignature: JSON.stringify(Hyprland.monitors.values.map(function(m) {
    var data = m.lastIpcObject;
    return [data.name, data.width, data.height, data.scale, data.transform];
  }))
  function settleManagedDirection(): void {
    // Lua applies monitor rules after a 100 ms settle; invalidate in-flight reads first.
    directionEpoch++;
    if (managedDirection.enabled) managedDirection = { enabled: true, native_direction_available: false, monitors: ({}), desktops: ({}) };
    monitorDirectionSettle.restart();
  }
  onMonitorGeometrySignatureChanged: settleManagedDirection()
  // Reloads and session changes must not leave a superseded policy orienting
  // rows, so only these callers drop the confirmed snapshot.
  function queryManagedDirection(): void {
    directionEpoch++;
    // An old monitor policy must not orient a row after a reload or move.
    if (managedDirection.enabled) managedDirection = { enabled: true, native_direction_available: false, monitors: ({}), desktops: ({}) };
    requestManagedDirection();
  }
  // Routine refresh: re-read the policy but keep the confirmed snapshot until
  // the reply. Blanking here would empty every row's direction for a frame, and
  // the guard in onLayoutChanged would then cancel an active drag or its
  // pending landing although no policy changed.
  function requestManagedDirection(): void {
    if (managedDirectionQuery.running || monitorDirectionSettle.running) return;
    directionRequestEpoch = ++directionEpoch;
    managedDirectionQuery.running = true;
  }
  Component.onCompleted: queryManagedDirection()
  signal pinRequested(bool value)
  property var rowIds: []
  property var rows: ({})
  property var windows: ({})
  property var stripBadgeAddresses: []
  property real pendingPan: 0
  property int pendingWorkspace: 0
  property string lastFocusedAddress: ""
  readonly property string nativeFocus: Hyprland.activeToplevel ? "0x" + Hyprland.activeToplevel.address.replace(/^0x/, "") : ""
  readonly property string focusedAddress: nativeFocus || recentFocus() || (windows[lastFocusedAddress] ? lastFocusedAddress : "")
  // A keyboard-interactive layer has no toplevel. Preserve the last client
  // marker while searching, and drop it when that client disappears.
  onNativeFocusChanged: if (nativeFocus) lastFocusedAddress = nativeFocus;
  readonly property var layout: Layout.build(
    Hyprland.monitors.values.map(function(m) { return m.lastIpcObject; }),
    Hyprland.workspaces.values.map(function(w) { return w.lastIpcObject; }),
    Hyprland.toplevels.values.map(function(w) { return w.lastIpcObject; }),
    Object.assign({ global: globalDirection, managed: managedDirection }, workspaceDirections))

  onLayoutChanged: {
    var prior = root.rows[root.pendingWorkspace];
    var current = layout.rows[root.pendingWorkspace];
    root.rows = layout.rows;
    root.windows = layout.windows;
    // Keep delegates mounted during IPC refreshes so a viewport drag is not
    // destroyed underneath the pointer when window positions change.
    if (JSON.stringify(root.rowIds) !== JSON.stringify(layout.ids)) root.rowIds = layout.ids;
    // The strip's displayed row can change mid-gesture (the special closes or
    // opens underneath it): a queued move or landing would then act on the
    // wrong canvas, so drop the gesture session instead.
    if (panning || awaitingLanding) {
      if (!Scratchpad.panSelectionValid(rows, rowIds, pendingWorkspace, scratchpadFollow)
          || (prior && current && (prior.monitor !== current.monitor || prior.direction !== current.direction))) {
        panning = false; panOrigin = ""; panRestore = ""; pendingPan = 0;
        panTimer.stop(); awaitingLanding = false; landTimer.stop();
      }
    }
    // Only once the refresh requested at release can have come back: the first
    // layout change after a release is often the pre-refresh snapshot, and
    // landing on it picks the candidate from before the last pans.
    if (awaitingLanding && Date.now() - landRequestedAt >= 60) land();
  }

  function recentFocus() {
    // Native activeToplevel can be empty until the first focus event after
    // shell startup. The client snapshot supplies the most recent window.
    for (var address in windows) if (windows[address].focusOrder === 0) return address;
    return "";
  }
  function setPinned(value) { pinRequested(value); }
  function rowForScreen(name) {
    return Scratchpad.rowFor(rows, rowIds, name, scratchpadFollow);
  }
  function refresh(): void {
    // An early refresh can preempt Quickshell's initial request, which alone
    // creates monitor objects. Wait for that native snapshot before polling.
    if (!Hyprland.monitors.values.some(function(m) { return !!m.lastIpcObject.name; })) return;
    Hyprland.refreshMonitors();
    Hyprland.refreshWorkspaces();
    Hyprland.refreshToplevels();
  }
  function activate(address: string): void {
    groupNotice = "";
    activationCheck.stop();
    activationError = "";
    if (!allWindows[address] || !/^0x[0-9a-f]+$/i.test(address)) {
      activationError = "That window is no longer available.";
      return;
    }
    activationError = ""; expectedAddress = address; expectedWorkspace = allWindows[address].workspaceId;
    activationCheck.restart();
    Hyprland.dispatch('hl.dsp.focus({ window = "address:' + address + '" })');
    refreshLater.restart();
  }
  function closeWindow(address: string): void {
    if (!allWindows[address] || !/^0x[0-9a-f]+$/i.test(address)) return;
    Hyprland.dispatch('hl.dsp.window.close({ window = "address:' + address + '" })');
    refreshLater.restart();
  }
  // Commands come from shared/WindowActions.js, which validates the stable ID
  // inside the compositor; an empty command means the caller's ID was invalid.
  function dispatchWindowAction(command: string): void {
    if (!command) return;
    Hyprland.dispatch(command);
    refreshLater.restart();
  }
  // The compositor re-checks every target at dispatch; the polled snapshot can be stale.
  function closeWindows(workspaceId: int, targets: var): void {
    var code = Catalog.closeCommand(workspaceId, targets);
    if (!code) return;
    Hyprland.dispatch(code);
    refreshLater.restart();
  }
  function activateWorkspace(workspaceId: int): void {
    if (!catalog.entries[workspaceId]) return;
    Hyprland.dispatch('hl.dsp.focus({ workspace = "' + String(workspaceId) + '" })');
    refreshLater.restart();
  }
  function toggleScratchpad(monitor: string): void {
    var name = Names.luaQuote(monitor);
    if (!name) return;
    Hyprland.dispatch('function() local m=hl.get_active_monitor(); if not m or m.name~=' + name
      + ' then local result=hl.dispatch(hl.dsp.focus({monitor=' + name + '})); if not result or not result.ok then return end end '
      + 'm=hl.get_active_monitor(); if not m or m.name~=' + name + ' then return end '
      + 'hl.dispatch(hl.dsp.workspace.toggle_special("scratchpad")) end');
    refreshLater.restart();
  }
  function openNewWorkspace(monitor: string): void {
    var name = Names.luaQuote(monitor);
    if (!name) return;
    // Choose inside the compositor: a polled snapshot could name a workspace
    // another actor just created, and focusing it would navigate there instead.
    Hyprland.dispatch('function() local used={} for _,w in ipairs(hl.get_workspaces()) do if w.id>0 then used[w.id]=true end end '
      + 'local id=1 while used[id] do id=id+1 end local m=hl.get_active_monitor() '
      + 'if not m or m.name~=' + name + ' then hl.dispatch(hl.dsp.focus({monitor=' + name + '})) end '
      + 'hl.dispatch(hl.dsp.focus({workspace=tostring(id)})) end');
    refreshLater.restart();
  }
  Timer {
    id: activationCheck
    interval: 350
    onTriggered: {
      root.refresh();
      if (root.nativeFocus !== root.expectedAddress)
        root.activationError = "The selected window could not be focused. It may have closed.";
      else if (!Hyprland.activeToplevel || !Hyprland.activeToplevel.lastIpcObject.workspace
        || Hyprland.activeToplevel.lastIpcObject.workspace.id !== root.expectedWorkspace)
        root.activationError = "The window was focused, but its workspace changed.";
    }
  }
  function specialOpenOn(monitor) {
    // Any open special counts, not just the scratchpad: the native layout move
    // acts on whichever tape is displayed, so a desktop-row pan must be
    // refused for every special, exactly like the compositor-side pan guard.
    var snapshot = Hyprland.monitors.values.find(function(m) { return m.name === monitor; });
    var special = snapshot && snapshot.lastIpcObject && snapshot.lastIpcObject.specialWorkspace;
    return !!special && !!special.name;
  }
  function canPan(workspaceId) {
    var row = rows[workspaceId];
    if (!row || !row.active || row.fullscreen || !Layout.validDirection(row.direction)) return false;
    if (workspaceId < 0) {
      // While the special is open, activeworkspace keeps reporting the desktop
      // workspace, so the followed scratchpad row pans through its open
      // display while the preference shows it, instead of a focused-workspace
      // identity. The native move then targets the displayed special.
      return scratchpadFollow && focusedMonitor === row.monitor;
    }
    // With the preference off, a display showing the desktop while its
    // scratchpad is open must not pan: the unqualified native move would act
    // on the hidden special's tape (owner decision, 2026-09-24).
    return !!Hyprland.focusedWorkspace && Hyprland.focusedWorkspace.id === workspaceId
      && !specialOpenOn(row.monitor);
  }
  // A scrubber drag is a session: the strip holds exclusive keyboard focus for
  // its duration, which is what stops Hyprland cancelling each pan. Releasing
  // that focus makes the compositor refocus the previous window, and a focus
  // change re-centres its column -- so the landing has to be chosen here rather
  // than left to the compositor's restore.
  property bool panning: false
  property string panOrigin: ""
  // Window a cancelled drag must return to; empty for an ordinary landing.
  property string panRestore: ""
  // Re-evaluates when rows change, so a workspace that becomes ineligible
  // mid-drag (fullscreen, focus moving to another display) drops the preview
  // instead of leaving a card stuck in the landing accent.
  readonly property string panCandidate: panning && canPan(pendingWorkspace)
    ? Layout.centreWindow(rows[pendingWorkspace]) : ""
  function beginPan(workspaceId) {
    if (!canPan(workspaceId)) return;
    pendingWorkspace = workspaceId;
    pendingPan = 0;
    panOrigin = focusedAddress;
    // Discard any landing still pending from the previous drag, or it lands on
    // the old candidate part-way through this one.
    landTimer.stop();
    awaitingLanding = false;
    panRestore = "";
    panning = true;
  }
  function endPan() {
    if (!panning) return;
    panning = false;
    panOrigin = "";
    // Drop anything still queued. The strip has just given up exclusive focus,
    // so a late move would be undone and would re-trigger the refocus.
    panTimer.stop();
    pendingPan = 0;
    // Decide the landing from refreshed geometry. The row snapshot at release
    // predates the last pans, so choosing here would land on the column that
    // was nearest the centre a few frames ago.
    awaitingLanding = true;
    landRequestedAt = Date.now();
    refresh();
    landTimer.restart();
  }
  // Set between a drag ending and its landing being applied. The landing needs
  // geometry newer than the last pan, so it runs on the next layout update; the
  // timer is only a deadline for when no update arrives.
  property bool awaitingLanding: false
  property double landRequestedAt: 0
  Timer {
    id: landTimer
    interval: 150
    onTriggered: root.land()
  }
  function land() {
    if (!awaitingLanding) return;
    awaitingLanding = false;
    landTimer.stop();
    // A cancel restores the window the drag began on; a release takes whatever
    // is nearest the viewport centre now. Only a tiled origin has a column to
    // settle back on; a floating one keeps focus and leaves the canvas as is.
    var cancelled = !!panRestore;
    var restoring = cancelled && !!windows[panRestore] && !Layout.isFloating(windows[panRestore]);
    // A drag can outlive its own eligibility: fullscreen, a closed window or
    // focus moving to another display. Land nothing on a workspace the user can
    // no longer pan; a cancel still restores, since that only refocuses.
    if (!canPan(pendingWorkspace)) { panRestore = ""; return; }
    var row = rows[pendingWorkspace];
    var landing = panRestore || Layout.centreWindow(row);
    panRestore = "";
    // Focusing the landed window settles its column to the centre. Pixel-exact
    // landing is not reachable: any focus change re-centres or re-fits.
    if (landing && windows[landing] && landing !== focusedAddress) { activate(landing); return; }
    // Already focused, so no focus event will fire and nothing settles the
    // canvas. That is what a short release should do -- stay where it was left.
    // A cancel must still return, and a drag past the last column must not
    // strand the canvas, since suppressing the refocus also removed its clamp.
    if (restoring || (!cancelled && Layout.stranded(row))) Hyprland.dispatch('hl.dsp.layout("fit_into_view")');
    refreshLater.restart();
  }
  function cancelPan() {
    if (!panning) return;
    var origin = panOrigin;
    panning = false;
    panOrigin = "";
    pendingPan = 0;
    // Restore through the same deferred path as a landing: the strip has only
    // just given up exclusive keyboard focus, and a focus dispatch made before
    // that lands is ignored.
    panRestore = origin;
    panTimer.stop();
    awaitingLanding = true;
    landRequestedAt = Date.now();
    refresh();
    landTimer.restart();
  }
  function pan(workspaceId, delta) {
    if (!canPan(workspaceId)) return;
    if (pendingWorkspace !== workspaceId) pendingPan = 0;
    pendingWorkspace = workspaceId;
    pendingPan += delta;
    if (!panTimer.running) panTimer.start();
  }
  Timer {
    id: panTimer
    interval: 30
    onTriggered: {
      var row = root.rows[root.pendingWorkspace];
      // Carry the sub-pixel remainder instead of discarding it: a slow drag
      // delivers fractions of a pixel per tick, and rounding each tick away
      // loses the whole gesture.
      var whole = Math.round(root.pendingPan);
      root.pendingPan -= whole;
      if (!whole) return;
      var request = Layout.panRequest(row, whole);
      // Focusing a different display warps the cursor out of the gesture.
      // Also recheck at flush time, since the user may switch workspaces.
      if (!request || !root.canPan(root.pendingWorkspace)) return;
      // The snapshot can still go stale between this check and the compositor
      // running the move; the guard refuses it when the active monitor or the
      // open special no longer matches the row the gesture aimed at.
      Hyprland.dispatch('function() local m=hl.get_active_monitor() if not m or m.name~='
        + Names.luaQuote(row.monitor) + ' then return end local sp=hl.get_active_special_workspace() '
        + Layout.panGuard(root.pendingWorkspace < 0)
        + 'hl.dispatch(' + request + ') end');
      refreshLater.restart();
    }
  }
  Timer {
    interval: root.expanded || root.pinned ? 350 : 1500
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
  Timer { id: refreshLater; interval: 60; onTriggered: { root.refresh(); root.requestManagedDirection(); } }
  Process {
    id: directionQuery
    command: ["hyprctl", "-j", "getoption", "scrolling.direction"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var value = JSON.parse(text).str;
          root.globalDirection = Layout.validDirection(value) ? value : "";
        } catch (error) { root.globalDirection = ""; }
      }
    }
  }
  Process {
    id: scratchpadBindingQuery
    command: ["hyprctl", "-j", "binds"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var list = JSON.parse(text);
          root.bindings = Array.isArray(list) ? list : [];
          root.scratchpadBinding = Scratchpad.toggleBinding(list);
        } catch (error) { root.bindings = []; root.scratchpadBinding = null; }
      }
    }
  }
  Process {
    id: managedDirectionQuery
    command: ["hyprctl", "repl", "return _G.paperland_monitor_direction_snapshot and _G.paperland_monitor_direction_snapshot() or '{\"enabled\":false,\"native_direction_available\":false,\"monitors\":{},\"desktops\":{}}'"]
    stdout: StdioCollector {
      onStreamFinished: {
        if (root.directionRequestEpoch !== root.directionEpoch) return;
        try {
          var value = JSON.parse(text.trim());
          if (typeof value.enabled !== "boolean" || typeof value.native_direction_available !== "boolean"
              || !value.monitors || typeof value.monitors !== "object"
              || !value.desktops || typeof value.desktops !== "object") return;
          var monitors = {};
          for (var name in value.monitors) {
            if (!/^[A-Za-z0-9_.:-]+$/.test(name) || !Layout.validDirection(value.monitors[name])) return;
            monitors[name] = value.monitors[name];
          }
          var desktops = {};
          for (var number in value.desktops) {
            if (!/^[1-9][0-9]*$/.test(number) || !Layout.validDirection(value.desktops[number])) return;
            desktops[number] = value.desktops[number];
          }
          if (!value.native_direction_available && Object.keys(desktops).length) return;
          root.managedDirection = { enabled: value.enabled, native_direction_available: value.native_direction_available,
            monitors: monitors, desktops: desktops };
        } catch (error) { /* Retain unknown policy until a later compositor event. */ }
      }
    }
    onRunningChanged: if (!running && root.directionRequestEpoch !== root.directionEpoch
                      && !monitorDirectionSettle.running) root.requestManagedDirection()
  }
  // Native monitor rules settle before this read; routine queries wait too,
  // so an early reply cannot republish the pre-transition policy.
  Timer { id: monitorDirectionSettle; interval: 250; onTriggered: root.requestManagedDirection() }
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (["renameworkspace", "workspacev2", "createworkspacev2", "destroyworkspacev2", "moveworkspacev2", "activespecialv2", "openwindow", "closewindow", "movewindowv2", "changefloatingmode"].indexOf(event.name) >= 0) refreshLater.restart();
      if (event.name === "configreloaded") {
        if (!directionQuery.running) directionQuery.running = true;
        if (!scratchpadBindingQuery.running) scratchpadBindingQuery.running = true;
        root.queryManagedDirection();
      }
      if (["monitoradded", "monitorremoved", "monitorlayoutchanged"].indexOf(event.name) >= 0) root.settleManagedDirection();
    }
    function onUsingLuaChanged() { root.queryManagedDirection(); }
  }
}
