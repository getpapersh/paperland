import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "NamesLogic.js" as NamesLogic

// The native compositor remains the source of truth for workspace lifecycle and
// names. This object only owns the generated defaults file and one serialized
// save/apply pipeline.
Item {
  id: root

  property bool ready: false
  property string error: ""
  readonly property string defaultsPath: {
    var explicit = String(Quickshell.env("PAPERLAND_WORKSPACE_NAMES_FILE") || "");
    if (explicit !== "") return explicit;
    var config = String(Quickshell.env("XDG_CONFIG_HOME") || "");
    if (config === "") config = String(Quickshell.env("HOME") || "") + "/.config";
    return config + "/hypr/paperland-workspace-names.lua";
  }
  readonly property string session: String(Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "")
  property var entries: ({})
  property var requests: ({})
  property var queue: []
  property var currentRequest: null
  property string phase: ""
  property int nextRequest: 0
  readonly property string requestPrefix: Date.now().toString(36) + "-" + Math.random().toString(36).slice(2)
  property int processesRunning: 0

  function missingFile(message) {
    if (message === FileViewError.FileNotFound) return true;
    var text = String(message || "").toLowerCase();
    return text.indexOf("no such file") >= 0 || text.indexOf("not found") >= 0 || text.indexOf("cannot open") >= 0;
  }

  function setRequest(request, state, message) {
    request.state = state;
    if (message !== undefined) request.message = String(message || "");
    var copy = Object.assign({}, requests);
    copy[request.requestId] = request;
    requests = copy;
  }

  function terminal(request, state, message, saved, loaded, applied) {
    operationTimer.stop();
    saveNext.stop();
    defaultsFile.watchChanges = true;
    currentRequest = null;
    phase = "";
    busy = false;
    if (workspaceQuery.running) workspaceQuery.running = false;
    if (rulesQuery.running) rulesQuery.running = false;
    if (reload.running) reload.running = false;
    if (configErrors.running) configErrors.running = false;
    if (dispatch.running) dispatch.running = false;
    request.saved = !!saved;
    request.loaded = !!loaded;
    request.applied = !!applied;
    request.terminal = true;
    setRequest(request, state, message);
    error = String(message || "");
    pump.restart();
  }

  property bool busy: false

  function workspaceSnapshot(id) {
    var wanted = NamesLogic.positiveId(id);
    if (!wanted) return null;
    var values = Hyprland.workspaces.values || [];
    for (var i = 0; i < values.length; i++) {
      var workspace = values[i];
      var nativeRow = workspace.lastIpcObject || {};
      var rowId = Number(nativeRow.id !== undefined ? nativeRow.id : workspace.id);
      if (rowId !== wanted) continue;
      var name = nativeRow.name !== undefined ? nativeRow.name : workspace.name;
      return { id: wanted, name: String(name === undefined || name === null ? wanted : name) };
    }
    // Quickshell may deliver the initial model asynchronously. The focused
    // workspace is still a native snapshot and covers the immediate begin
    // call while that model is being populated.
    var focused = Hyprland.focusedWorkspace;
    if (focused && Number(focused.id) === wanted) {
      var focusedRow = focused.lastIpcObject || {};
      var focusedName = focusedRow.name !== undefined ? focusedRow.name : focused.name;
      return { id: wanted, name: String(focusedName === undefined || focusedName === null ? wanted : focusedName) };
    }
    return null;
  }

  function liveSession() {
    return String(Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "");
  }

  function begin(workspaceId) {
    var id = NamesLogic.positiveId(workspaceId);
    if (!ready) return JSON.stringify({ ok: false, message: "Workspace names are still initializing." });
    if (!id) return JSON.stringify({ ok: false, message: "Workspace ID must be a positive integer." });
    var current = workspaceSnapshot(id);
    if (!current) return JSON.stringify({ ok: false, message: "Workspace does not exist." });
    var revision = NamesLogic.revision(entries, id);
    return JSON.stringify({ ok: true,
      capture: { session: session, id: id, observedName: current.name, revision: revision },
      savedName: revision });
  }

  function submit(payloadString) {
    if (!ready) return JSON.stringify({ ok: false, message: "Workspace names are still initializing." });
    var payload;
    try { payload = JSON.parse(String(payloadString)); }
    catch (parseError) { return JSON.stringify({ ok: false, message: "Submit payload is not valid JSON." }); }
    if (!payload || typeof payload !== "object" || !payload.capture) return JSON.stringify({ ok: false, message: "Submit payload has no capture." });
    var capture = payload.capture;
    var id = NamesLogic.positiveId(capture.id);
    if (!id || String(capture.id) !== String(id)) return JSON.stringify({ ok: false, message: "Capture has an invalid workspace ID." });
    if (String(capture.session || "") !== liveSession()) return JSON.stringify({ ok: false, message: "Capture belongs to another compositor session." });
    if (typeof capture.observedName !== "string" || (capture.revision !== null && typeof capture.revision !== "string")) return JSON.stringify({ ok: false, message: "Capture has invalid revision data." });
    var normalized = NamesLogic.normalizeName(payload.name);
    if (!normalized.ok) return JSON.stringify({ ok: false, message: normalized.message });
    var requestId = requestPrefix + "-" + (++nextRequest);
    var request = { requestId: requestId, state: "queued", saved: false, loaded: false, applied: false, terminal: false,
      message: "", capture: { session: session, id: id, observedName: capture.observedName, revision: capture.revision }, name: normalized.name };
    var copy = Object.assign({}, requests);
    copy[requestId] = request;
    requests = copy;
    queue = queue.concat([request]);
    pump.restart();
    return JSON.stringify({ ok: true, requestId: requestId });
  }

  function status(requestId) {
    var request = requests[String(requestId)];
    if (!request) return JSON.stringify({ requestId: String(requestId), state: "unresolved", saved: false, loaded: false, applied: false, terminal: true, message: "Unknown request." });
    return JSON.stringify({ requestId: request.requestId, state: request.state, saved: !!request.saved, loaded: !!request.loaded,
      applied: !!request.applied, terminal: !!request.terminal, message: String(request.message || "") });
  }

  function startTimer() { operationTimer.restart(); }

  function pumpQueue() {
    if (busy || processesRunning > 0 || queue.length === 0) return;
    busy = true;
    currentRequest = queue[0];
    queue = queue.slice(1);
    setRequest(currentRequest, "loading", "");
    phase = "submit-file";
    startTimer();
    defaultsFile.reload();
  }

  function fail(message, saved, loaded, applied) {
    if (!currentRequest) return;
    terminal(currentRequest, "error", message, saved, loaded, applied);
  }

  function parseOwnedFile(text) {
    var parsed = NamesLogic.parse(String(text || ""));
    if (!parsed.ok) {
      if (currentRequest) fail(parsed.message, false, false, false);
      else error = parsed.message;
      return null;
    }
    entries = parsed.entries;
    return parsed.entries;
  }

  function startWorkspaceQuery(nextPhase) {
    phase = nextPhase;
    workspaceQuery.command = ["hyprctl", "-j", "workspaces"];
    workspaceQuery.running = true;
  }

  function parseWorkspaces(output) {
    var rows;
    try { rows = JSON.parse(String(output || "")); }
    catch (parseError) { fail("Native workspace query was not valid JSON.", currentRequest.saved, currentRequest.loaded, false); return null; }
    if (!Array.isArray(rows)) { fail("Native workspace query was not an array.", currentRequest.saved, currentRequest.loaded, false); return null; }
    var id = currentRequest.capture.id;
    for (var i = 0; i < rows.length; i++) {
      if (Number(rows[i].id) === id) return { id: id, name: String(rows[i].name === undefined ? id : rows[i].name) };
    }
    fail("Workspace disappeared before the native action.", currentRequest.saved, currentRequest.loaded, false);
    return null;
  }

  function queryRules(nextPhase) {
    phase = nextPhase;
    rulesQuery.command = ["hyprctl", "-j", "workspacerules"];
    rulesQuery.running = true;
  }

  function parseRules(output) {
    var raw;
    try { raw = JSON.parse(String(output || "")); }
    catch (parseError) { fail("Native workspace-rules query was not valid JSON.", currentRequest.saved, currentRequest.loaded, false); return null; }
    var parsed = NamesLogic.nativeRules(raw);
    if (!parsed.ok) { fail(parsed.message, currentRequest.saved, currentRequest.loaded, false); return null; }
    return parsed.rules;
  }

  function candidateEntries() {
    try { return NamesLogic.replaceEntry(entries, currentRequest.capture.id, currentRequest.name); }
    catch (entryError) { fail("Could not form the owned workspace-names update.", false, false, false); return null; }
  }

  function startSave(candidate) {
    var text;
    try { text = NamesLogic.format(candidate); }
    catch (formatError) { fail("Could not encode the owned workspace-names file.", false, false, false); return; }
    currentRequest.candidate = candidate;
    currentRequest.saved = false;
    setRequest(currentRequest, "saving", "");
    phase = "save";
    if (text === String(defaultsFile.text() || "")) {
      currentRequest.saved = true;
      setRequest(currentRequest, "loading", "");
      phase = "reload";
      reload.command = ["hyprctl", "reload"];
      reload.running = true;
      return;
    }
    defaultsFile.watchChanges = false;
    defaultsFile.setText(text);
  }

  function afterReload() {
    phase = "configerrors";
    configErrors.command = ["hyprctl", "configerrors"];
    configErrors.running = true;
  }

  function validateNativeRules() {
    var rules = parseRules(rulesStdout.text);
    if (!rules || !currentRequest) return;
    var candidate = currentRequest.candidate;
    var conflicts = NamesLogic.ruleConflict(rules, candidate);
    currentRequest.loaded = currentRequest.name === "" || NamesLogic.ruleMatches(rules, currentRequest.capture.id, currentRequest.name);
    setRequest(currentRequest, "loading", "");
    if (currentRequest.name !== "" && (conflicts.length > 0 || !NamesLogic.ruleMatches(rules, currentRequest.capture.id, currentRequest.name))) {
      fail("Native reload did not confirm the owned workspace default.", true, currentRequest.loaded, false);
      return;
    }
    if (currentRequest.name === "" && conflicts.length > 0) {
      fail("Saved default removed; native fallback is unknown because an external default rule remains.", true, true, false);
      return;
    }
    startWorkspaceQuery("recheck");
  }

  function dispatchRename(workspace) {
    if (!currentRequest) return;
    var desired = currentRequest.name === "" ? String(currentRequest.capture.id) : currentRequest.name;
    var encodedId = NamesLogic.luaQuote(String(currentRequest.capture.id));
    var encodedName = NamesLogic.luaQuote(desired);
    if (encodedId === null || encodedName === null) { fail("Could not encode the native rename request.", true, true, false); return; }
    currentRequest.desired = desired;
    setRequest(currentRequest, "applying", "");
    phase = "dispatch";
    dispatch.command = ["hyprctl", "dispatch", "" + "hl.dsp.workspace.rename({ workspace = " + encodedId + ", name = " + encodedName + " })"];
    dispatch.running = true;
  }

  function finishApply() {
    var workspace = parseWorkspaces(workspaceStdout.text);
    if (!workspace || !currentRequest) return;
    if (workspace.name !== currentRequest.desired) {
      fail("Native workspace readback did not confirm the requested name.", true, true, false);
      return;
    }
    terminal(currentRequest, "applied", currentRequest.name ? "Name saved, loaded and applied." : "Saved default cleared; the workspace now uses its native number.", true, true, true);
  }

  function processWorkspace(exitCode) {
    if (!currentRequest) return;
    if (exitCode !== 0) { fail("Native workspace query failed.", currentRequest.saved, currentRequest.loaded, false); return; }
    var workspace = parseWorkspaces(workspaceStdout.text);
    if (!workspace || !currentRequest) return;
    if (phase === "fresh-submit") {
      if (liveSession() !== currentRequest.capture.session) { fail("Compositor session changed while the request was pending.", false, false, false); return; }
      if (workspace.name !== currentRequest.capture.observedName) { fail("Workspace name changed while the request was pending.", false, false, false); return; }
      queryRules("before-save");
    } else if (phase === "recheck") {
      if (liveSession() !== currentRequest.capture.session) { fail("Compositor session changed while the request was pending.", currentRequest.saved, currentRequest.loaded, false); return; }
      if (workspace.name !== currentRequest.capture.observedName) { fail("Workspace name changed while the request was pending.", currentRequest.saved, currentRequest.loaded, false); return; }
      dispatchRename(workspace);
    } else if (phase === "apply-readback") finishApply();
  }

  function processRules(exitCode) {
    if (!currentRequest) return;
    if (exitCode !== 0) { fail("Native workspace-rules query failed.", currentRequest.saved, currentRequest.loaded, false); return; }
    if (phase === "before-save") {
      var rules = parseRules(rulesStdout.text);
      if (!rules || !currentRequest) return;
      var candidate = candidateEntries();
      if (!candidate) return;
      // The current native rule can still carry the captured old owned name;
      // recognize it against the current file before replacing that entry.
      if (currentRequest.name !== "" && NamesLogic.ruleConflict(rules, entries).length > 0) {
        fail("An external native default rule makes this workspace name unresolved.", false, false, false);
        return;
      }
      phase = "presave-file";
      defaultsFile.reload();
    } else if (phase === "after-rules") validateNativeRules();
  }

  function processReload(exitCode) {
    if (!currentRequest) return;
    currentRequest.saved = true;
    setRequest(currentRequest, "loading", "");
    if (exitCode !== 0) { fail("Owned names were saved, but native reload failed.", true, false, false); return; }
    afterReload();
  }

  function processConfigErrors(exitCode) {
    if (!currentRequest) return;
    if (exitCode !== 0 || String(configErrorsStdout.text || "").trim() !== "") {
      fail("Owned names were saved, but native configerrors reported a reload failure.", true, false, false);
      return;
    }
    queryRules("after-rules");
  }

  function processDispatch(exitCode) {
    if (!currentRequest) return;
    if (exitCode !== 0) { fail("Owned names were saved and loaded, but native rename failed.", true, true, false); return; }
    startWorkspaceQuery("apply-readback");
  }

  function onFileLoaded() {
    defaultsFile.watchChanges = true;
    if (!ready) {
      var initial = parseOwnedFile(defaultsFile.text());
      if (initial) ready = true;
      return;
    }
    if (!currentRequest) { parseOwnedFile(defaultsFile.text()); return; }
    if (phase !== "submit-file" && phase !== "presave-file") return;
    var current = parseOwnedFile(defaultsFile.text());
    if (!current) return;
    var capture = currentRequest.capture;
    if (NamesLogic.revision(current, capture.id) !== capture.revision) { fail("Saved workspace name changed while the request was pending.", false, false, false); return; }
    if (phase === "presave-file") { phase = "save-ready"; saveNext.restart(); }
    else startWorkspaceQuery("fresh-submit");
  }

  function onFileLoadFailed(message) {
    defaultsFile.watchChanges = true;
    if (missingFile(message)) {
      entries = {};
      if (!ready) { ready = true; return; }
      if (currentRequest && (phase === "submit-file" || phase === "presave-file")) {
        var capture = currentRequest.capture;
        if (capture.revision !== null) { fail("Owned names file disappeared after capture.", false, false, false); return; }
        if (phase === "presave-file") { phase = "save-ready"; saveNext.restart(); }
        else startWorkspaceQuery("fresh-submit");
      }
      return;
    }
    if (!ready) { error = "Owned names file could not be read: " + String(message || "unknown error"); return; }
    if (currentRequest) fail("Owned names file could not be read: " + String(message || "unknown error"), false, false, false);
  }

  function onFileSaved() {
    if (!currentRequest || phase !== "save") return;
    defaultsFile.watchChanges = true;
    entries = currentRequest.candidate;
    currentRequest.saved = true;
    setRequest(currentRequest, "loading", "");
    phase = "reload";
    reload.command = ["hyprctl", "reload"];
    reload.running = true;
  }

  function onFileSaveFailed(message) {
    if (currentRequest) fail("Owned names could not be saved: " + String(message || "unknown error"), false, false, false);
  }

  // FileView completes its current job after emitting loaded/loadFailed.
  // Start the replacement on the next event turn so that completion cannot
  // discard the new write's callback.
  Timer { id: saveNext; interval: 0; onTriggered: if (root.currentRequest && root.phase === "save-ready") root.startSave(root.candidateEntries()) }
  Timer { id: pump; interval: 0; onTriggered: root.pumpQueue() }
  Timer {
    id: operationTimer
    interval: 8000
    onTriggered: if (root.currentRequest) root.terminal(root.currentRequest, "unresolved",
      "Outcome unresolved: the native operation timed out. Check live and saved names before retrying.",
      root.currentRequest.saved, root.currentRequest.loaded, false)
  }

  // A missing file cannot be watched directly. Observe creation and atomic
  // replacement in its directory so a later edit refreshes the saved revision.
  FileView {
    path: root.defaultsPath.substring(0, root.defaultsPath.lastIndexOf("/"))
    preload: false
    watchChanges: true
    printErrors: false
    onFileChanged: if (!root.busy) defaultsFile.reload()
  }

  FileView {
    id: defaultsFile
    path: root.defaultsPath
    atomicWrites: true
    watchChanges: true
    printErrors: false
    onLoaded: root.onFileLoaded()
    onFileChanged: if (!root.busy) reload()
    onLoadFailed: function(message) { root.onFileLoadFailed(message); }
    onSaved: root.onFileSaved()
    onSaveFailed: function(message) { root.onFileSaveFailed(message); }
  }

  Process {
    id: workspaceQuery
    stdout: StdioCollector { id: workspaceStdout }
    stderr: StdioCollector { id: workspaceStderr }
    onStarted: root.processesRunning++
    onExited: function(exitCode) {
      root.processesRunning = Math.max(0, root.processesRunning - 1);
      root.processWorkspace(exitCode);
      if (!root.currentRequest) pump.restart();
    }
  }
  Process {
    id: rulesQuery
    stdout: StdioCollector { id: rulesStdout }
    stderr: StdioCollector { id: rulesStderr }
    onStarted: root.processesRunning++
    onExited: function(exitCode) {
      root.processesRunning = Math.max(0, root.processesRunning - 1);
      root.processRules(exitCode);
      if (!root.currentRequest) pump.restart();
    }
  }
  Process {
    id: reload
    stdout: StdioCollector { id: reloadStdout }
    stderr: StdioCollector { id: reloadStderr }
    onStarted: root.processesRunning++
    onExited: function(exitCode) {
      root.processesRunning = Math.max(0, root.processesRunning - 1);
      root.processReload(exitCode);
      if (!root.currentRequest) pump.restart();
    }
  }
  Process {
    id: configErrors
    stdout: StdioCollector { id: configErrorsStdout }
    stderr: StdioCollector { id: configErrorsStderr }
    onStarted: root.processesRunning++
    onExited: function(exitCode) {
      root.processesRunning = Math.max(0, root.processesRunning - 1);
      root.processConfigErrors(exitCode);
      if (!root.currentRequest) pump.restart();
    }
  }
  Process {
    id: dispatch
    stdout: StdioCollector { id: dispatchStdout }
    stderr: StdioCollector { id: dispatchStderr }
    onStarted: root.processesRunning++
    onExited: function(exitCode) {
      root.processesRunning = Math.max(0, root.processesRunning - 1);
      root.processDispatch(exitCode);
      if (!root.currentRequest) pump.restart();
    }
  }

  Component.onCompleted: defaultsFile.reload()
}
