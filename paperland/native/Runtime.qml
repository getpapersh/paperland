pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "../shared" as Shared
import "../Layout.js" as Layout
import "../shared/Scratchpad.js" as Scratchpad
import "../shared/CaptureReport.js" as CaptureReport
import "../shared/Bindings.js" as Bindings
import "../shared/StripBadge.js" as StripBadge
import "../shared/StripColumns.js" as StripColumns
import ".."

QtObject {
  id: root
  readonly property string badgeRuntimeDir: String(Quickshell.env("XDG_RUNTIME_DIR") || "")
  readonly property string badgePath: badgeRuntimeDir ? badgeRuntimeDir + "/paperland-strip-badges.json" : ""
  property double badgeDeadline: 0
  // Only the standalone app receives the chord IPC; the Omarchy runtime mirrors its snapshot.
  property bool badgeSnapshotWriter: false
  property string badgeGeneration: ""
  property double badgeSeq: 0
  property double badgeAppliedAt: 0
  property var badgePendingSnapshot: null
  property var badgePendingReport: null
  property string badgeLayoutSignature: ""
  function appEntry(app: string): var {
    // A web app without a matching entry keeps its host label; guessing can select another app.
    if (Layout.webAppHost(app))
      return Layout.desktopEntry(DesktopEntries.applications.values, app) || DesktopEntries.byId(app);
    var name = Layout.appName(app);
    return DesktopEntries.byId(app)
      || DesktopEntries.byId(name)
      || DesktopEntries.byId(name.toLowerCase())
      || Layout.desktopEntry(DesktopEntries.applications.values, app)
      || DesktopEntries.heuristicLookup(app);
  }
  function nameFor(app: string): string {
    var entry = appEntry(app);
    return entry && entry.name ? entry.name : Layout.appName(app);
  }
  function iconFor(app: string): string {
    var entry = appEntry(app);
    return Quickshell.iconPath(entry && entry.icon ? entry.icon : "application-x-executable", true);
  }
  // Pill variant of the same resolver: unknown or unloadable apps return ""
  // so the pill can draw its own letter tile. Thumbnails keep iconFor's
  // application-x-executable fallback unchanged.
  function iconForPill(app: string): string {
    var entry = appEntry(app);
    return entry && entry.icon ? Quickshell.iconPath(entry.icon, true) : "";
  }
  readonly property string pillPath: badgeRuntimeDir ? badgeRuntimeDir + "/paperland-strip-columns.json" : ""
  property bool pillSnapshotWriter: false
  property string pillGeneration: ""
  property double pillSeq: 0
  property var stripColumns: []
  // The IPC receiver owns the mirror and writes before anything else reads
  // it: the first valid snapshot must land in the file. Readers (file loads)
  // never become writers, exactly like the badge flow.
  function showStripColumns(payload: string): bool {
    var report = StripColumns.parsePayload(payload);
    if (!report || !StripBadge.isNewer(report, { generation: pillGeneration, seq: pillSeq, appliedAt: 0 })) return false;
    pillGeneration = report.generation;
    pillSeq = report.seq;
    pillSnapshotWriter = true;
    stripColumns = report.workspaces;
    if (pillPath) pillWriter.setText(JSON.stringify(report));
    return true;
  }
  function applyStripColumns(report: var): bool {
    if (!report || !StripBadge.isNewer(report, { generation: pillGeneration, seq: pillSeq, appliedAt: 0 })) return false;
    pillGeneration = report.generation;
    pillSeq = report.seq;
    stripColumns = report.workspaces;
    return true;
  }
  function columnsForWorkspace(id: int): var {
    return StripColumns.workspaceColumns(stripColumns, id);
  }
  function loadStripColumns(): void {
    var value;
    try { value = JSON.parse(pillReader.text()); } catch (error) { value = null; }
    applyStripColumns(StripColumns.validateReport(value));
  }
  // A publish emitted while no instance listened is lost, so each host pulls
  // a fresh snapshot from the Lua module once it loads (same gate as the
  // follow preference push in shell.qml).
  function requestStripColumns(): void {
    Hyprland.dispatch('function() if _G.paperland_strip_columns_request then '
      + '_G.paperland_strip_columns_request() end end');
  }
  readonly property Connections pillLuaConnections: Connections {
    target: Hyprland
    function onUsingLuaChanged() { if (Hyprland.usingLua) pillRequestRetry.begin(); }
  }
  // A dispatch issued before Quickshell's compositor connection is up is
  // dropped silently, and onUsingLuaChanged never fires when usingLua was
  // already true, so one early request races instance startup. A few bounded
  // retries cost nothing: the Lua settle timer coalesces them and receivers
  // deduplicate by sequence.
  // Sends and idle ticks are bounded separately: a host that never reaches
  // Lua (or a compositor that is not Hyprland) stops waking after a few
  // seconds, and every false-to-true change grants a full set of four sends.
  readonly property Timer pillRequestRetry: Timer {
    id: pillRequestRetry
    property int sent: 0
    property int idle: 0
    interval: 500
    repeat: true
    triggeredOnStart: true
    function begin(): void { sent = 0; idle = 0; restart(); }
    onTriggered: {
      if (!Hyprland.usingLua) {
        if (++idle >= 10) stop();
        return;
      }
      root.requestStripColumns();
      if (++sent >= 4) stop();
    }
  }
  Component.onCompleted: pillRequestRetry.begin()
  readonly property Service service: Service {}
  readonly property WindowSendMenu sendMenu: WindowSendMenu { service: root.service }
  readonly property NameClient names: NameClient {}
  readonly property Shared.ThumbnailCache thumbnails: Shared.ThumbnailCache {
    windows: Hyprland.toplevels.values.map(function(window) {
      return {address: "0x" + window.address.replace(/^0x/, ""), handle: window.wayland};
    })
  }
  // Thumbnail surfaces (minimap strips, overview boards, the workspace
  // dialog, bar previews) register here so the capture report reads actual
  // slot state at request time instead of reconstructing it from the cache.
  // Each process (the standalone app, the Omarchy bar) has its own runtime
  // and registry. A surface provides captureRecords(): var.
  property var captureSurfaces: []
  function registerCaptureSurface(surface: QtObject): void {
    if (captureSurfaces.indexOf(surface) < 0) captureSurfaces = captureSurfaces.concat([surface]);
  }
  function unregisterCaptureSurface(surface: QtObject): void {
    captureSurfaces = captureSurfaces.filter(function(item) { return item !== surface; });
  }
  function localPath(location: url): string {
    return decodeURIComponent(location.toString().replace(/^file:\/\//, "")).replace(/\/$/, "");
  }
  // Build identity of the runtime files this process loaded, hashed once per
  // QML engine by the launcher shipped in the same tree, so the CLI can
  // compare it with a fresh hash of the installed files. Once known it never
  // changes: a bar widget created later (hotplug, layout rebuild) must not
  // re-hash files reinstalled since the running code was loaded. A
  // configuration reload builds a new engine and a new singleton.
  readonly property string runtimeDir: localPath(Qt.resolvedUrl(".."))
  property string identity: ""
  property string identityError: ""
  function computeIdentity(roots: var): void {
    if (identity || identityProcess.running) return;
    identityError = "";
    identityProcess.command = [runtimeDir + "/paperland", "identity"].concat(roots);
    identityProcess.running = true;
  }
  function identityReport(): string {
    return JSON.stringify(identity ? { identity: identity }
      : { identity: null, reason: identityError || "The running identity is still being computed." });
  }
  // Exit and end of stdout arrive in either order; settle once both are in.
  property int identityExit: -1
  property bool identityRead: false
  function settleIdentity(): void {
    if (identityExit < 0 || !identityRead) return;
    var value = identityOut.text.trim();
    if (identityExit === 0 && /^[0-9a-f]{16}$/.test(value)) identity = value;
    else identityError = identityErr.text.trim() || "Hashing the runtime files failed.";
  }
  readonly property Process identityProcess: Process {
    onStarted: { root.identityExit = -1; root.identityRead = false; }
    stdout: StdioCollector { id: identityOut; onStreamFinished: { root.identityRead = true; root.settleIdentity(); } }
    stderr: StdioCollector { id: identityErr }
    onExited: function(code) { root.identityExit = code; root.settleIdentity(); }
  }
  // One fresh live bind query per diagnostics request, polled quietly by the
  // CLI. A request arriving while a query runs shares that query.
  property int bindRequest: 0
  property string bindResult: ""
  property int bindExit: -1
  property bool bindRead: false
  function beginDiagnostics(): string {
    if (!bindQuery.running) {
      bindRequest++;
      bindResult = "";
      bindStarted = false;
      bindQuery.running = true;
      bindDeadline.restart();
    }
    return String(bindRequest);
  }
  // A hung query must not keep every later request pending; it ends before
  // the CLI's own 5 s wait so the reply carries this reason.
  property bool bindStarted: false
  readonly property Timer bindDeadline: Timer {
    interval: 4000
    onTriggered: {
      if (root.bindResult) return;
      root.bindResult = Bindings.deadlineResult(root.bindStarted);
      root.bindQuery.running = false;
    }
  }
  function diagnosticsStatus(request: string): string {
    if (request !== String(bindRequest))
      return JSON.stringify({ incomplete: true, reason: "Unknown or superseded diagnostics request." });
    return bindResult || '{"pending":true}';
  }
  function settleBinds(): void {
    if (bindExit < 0 || !bindRead || bindResult) return;
    bindDeadline.stop();
    bindResult = Bindings.queryResult(bindExit, bindOut.text, bindErr.text, Scratchpad.toggleBinding);
  }
  readonly property Process bindQuery: Process {
    command: ["hyprctl", "-j", "binds"]
    onStarted: { root.bindStarted = true; root.bindExit = -1; root.bindRead = false; }
    stdout: StdioCollector { id: bindOut; onStreamFinished: { root.bindRead = true; root.settleBinds(); } }
    stderr: StdioCollector { id: bindErr }
    onExited: function(code) { root.bindExit = code; root.settleBinds(); }
  }
  // This process's capture report, keyed by host so the launcher can merge
  // the standalone and bar replies into one object.
  function captureReport(host: string, detail: bool, gaps: var): string {
    var records = [];
    captureSurfaces.forEach(function(surface) { records = records.concat(surface.captureRecords()); });
    var retained = Object.keys(thumbnails.records).filter(function(key) {
      var entry = root.thumbnails.records[key];
      return !!(entry && entry.result);
    }).length;
    return JSON.stringify(CaptureReport.buildReport(
      [{ name: host, slots: records, cacheRetained: retained, cacheBound: thumbnails.maxEntries, gaps: gaps }], detail));
  }
  function activeBadgeRow(): var {
    // The row the focused display's strip displays: the open scratchpad while
    // the follow preference is on, otherwise the active desktop workspace.
    // Lua numbers that same target, so validation must anchor to it too.
    return Scratchpad.rowFor(service.rows, service.rowIds, service.focusedMonitor,
      service.scratchpadFollow);
  }
  function showStripBadges(payload: string): bool {
    var report = StripBadge.parseReport(payload);
    if (!report || !StripBadge.isNewer(report,
        { generation: badgeGeneration, seq: badgeSeq, appliedAt: badgeAppliedAt })) return false;
    badgeGeneration = report.generation;
    badgeSeq = report.seq;
    badgeAppliedAt = Date.now();
    badgeSnapshotWriter = true;
    badgePendingSnapshot = null;
    badgePendingReport = null;
    if (report.windows === null) { saveStripBadges([]); return true; }
    var row = activeBadgeRow();
    var clean = StripBadge.retainOnMismatch(StripBadge.validateShow(report.windows, row),
      service.stripBadgeAddresses);
    if (clean === service.stripBadgeAddresses) {
      if (!row) badgePendingReport = { generation: report.generation, seq: report.seq,
        timestamp: badgeAppliedAt, windows: report.windows };
      preserveFreshReport(badgeAppliedAt);
      return false;
    }
    if (!clean.length) { preserveFreshReport(badgeAppliedAt); return true; }
    saveStripBadges(clean);
    return true;
  }
  function applySharedBadges(value: var): void {
    var snapshot = StripBadge.parseSnapshot(value);
    if (!snapshot || !StripBadge.isNewer(snapshot,
        { generation: badgeGeneration, seq: badgeSeq, appliedAt: badgeAppliedAt })) return;
    badgeGeneration = snapshot.generation;
    badgeSeq = snapshot.seq;
    badgeAppliedAt = snapshot.timestamp;
    badgePendingSnapshot = null;
    badgePendingReport = null;
    var current = { addresses: service.stripBadgeAddresses, layoutSignature: badgeLayoutSignature,
      deadline: badgeDeadline };
    var resolved = StripBadge.retainOnMismatch(
      StripBadge.resolveSnapshot(snapshot, activeBadgeRow(), Date.now()), current);
    if (resolved === current) preserveFreshReport(snapshot.timestamp);
    else setResolvedSnapshot(snapshot, resolved);
  }
  function setResolvedSnapshot(snapshot: var, resolved: var): void {
    badgePendingSnapshot = resolved && resolved.pending ? snapshot : null;
    badgePendingReport = null;
    if (!resolved.pending) {
      service.stripBadgeAddresses = resolved.addresses;
      badgeLayoutSignature = resolved.layoutSignature;
    }
    badgeDeadline = resolved ? resolved.deadline : 0;
    armBadgeExpiry();
  }
  function saveStripBadges(addresses: var): void {
    var timestamp = Date.now();
    var row = addresses.length ? activeBadgeRow() : null;
    badgeAppliedAt = timestamp;
    badgePendingSnapshot = null;
    badgePendingReport = null;
    service.stripBadgeAddresses = addresses;
    badgeLayoutSignature = row ? StripBadge.canonicalSignature(row) : "";
    badgeDeadline = addresses.length ? timestamp + StripBadge.STALE_MS : 0;
    armBadgeExpiry();
    if (badgeSnapshotWriter && badgePath) badgeWriter.setText(JSON.stringify({
      addresses: addresses, timestamp: timestamp, generation: badgeGeneration,
      seq: badgeSeq, layoutSignature: badgeLayoutSignature
    }));
  }
  function preserveFreshReport(timestamp: double): void {
    if (!StripBadge.isFresh(timestamp, Date.now())
        || (!service.stripBadgeAddresses.length && !badgePendingSnapshot && !badgePendingReport)) return;
    badgeDeadline = timestamp + StripBadge.STALE_MS;
    armBadgeExpiry();
    if (badgeSnapshotWriter && badgePath && service.stripBadgeAddresses.length)
      badgeWriter.setText(JSON.stringify({ addresses: service.stripBadgeAddresses, timestamp: timestamp,
        generation: badgeGeneration, seq: badgeSeq, layoutSignature: badgeLayoutSignature }));
  }
  function clearStripBadges(): void {
    if (!service.stripBadgeAddresses.length && !badgeDeadline && !badgePendingSnapshot && !badgePendingReport) return;
    saveStripBadges([]);
  }
  function armBadgeExpiry(): void {
    if (!badgeDeadline) { badgeExpiry.stop(); return; }
    badgeExpiry.interval = Math.max(1, Math.ceil(badgeDeadline - Date.now()));
    badgeExpiry.restart();
  }
  function loadStripBadges(): void {
    var value;
    try { value = JSON.parse(badgeReader.text()); } catch (error) { value = null; }
    applySharedBadges(value);
  }
  function revalidateStripBadges(): void {
    if (badgePendingSnapshot) {
      var pending = badgePendingSnapshot;
      var resolved = StripBadge.resumeSnapshot(pending,
        { generation: badgeGeneration, seq: badgeSeq, appliedAt: badgeAppliedAt },
        activeBadgeRow(), Date.now());
      if (!resolved) { badgePendingSnapshot = null; return; }
      if (resolved.pending) return;
      setResolvedSnapshot(null, resolved);
      return;
    }
    if (badgePendingReport) {
      var pending = badgePendingReport;
      var row = activeBadgeRow();
      if (!row) return;
      badgePendingReport = null;
      if (!StripBadge.isFresh(pending.timestamp, Date.now())) return;
      var clean = StripBadge.validateShow(pending.windows, row);
      if (!clean || !clean.length) { preserveFreshReport(pending.timestamp); return; }
      saveStripBadges(clean);
      return;
    }
    loadStripBadges();
  }
  readonly property Connections badgeClearConnections: Connections {
    target: root.service
    function onLayoutChanged() { Qt.callLater(function() { root.revalidateStripBadges(); }); }
    function onFocusedMonitorChanged() { root.clearStripBadges(); }
  }
  readonly property Timer badgeExpiry: Timer {
    interval: StripBadge.STALE_MS
    onTriggered: {
      if (root.badgeDeadline > Date.now()) { restart(); return; }
      root.clearStripBadges();
    }
  }
  readonly property FileView badgeReader: FileView {
    path: root.badgePath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadStripBadges()
    onFileChanged: reload()
  }
  readonly property FileView badgeWriter: FileView {
    path: root.badgePath
    watchChanges: false
    printErrors: false
    onSaved: root.badgeReader.reload()
  }
  // Column snapshots are persistent presentation state, not transient badges:
  // no expiry, and the next native event self-corrects stale membership.
  readonly property FileView pillReader: FileView {
    path: root.pillPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadStripColumns()
    onFileChanged: reload()
  }
  // A missing file cannot be watched directly: a bar that starts before the
  // first snapshot (first login) would never load one. Observe creation and
  // atomic replacement in the runtime directory, as WorkspaceNames does.
  readonly property FileView pillDirectory: FileView {
    path: root.badgeRuntimeDir
    preload: false
    watchChanges: true
    printErrors: false
    // The directory reports every runtime-dir entry (sockets, other mirrors);
    // coalesce the burst, and reload only matters until the mirror exists.
    onFileChanged: root.pillDirectoryReload.restart()
  }
  readonly property Timer pillDirectoryReload: Timer {
    interval: 50
    onTriggered: root.pillReader.reload()
  }
  readonly property FileView pillWriter: FileView {
    path: root.pillPath
    watchChanges: false
    printErrors: false
    onSaved: root.pillReader.reload()
  }
}
