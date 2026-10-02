pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "../shared" as Shared
import "../Layout.js" as Layout
import "../shared/Scratchpad.js" as Scratchpad
import "../shared/StripBadge.js" as StripBadge
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
  readonly property Service service: Service {}
  readonly property WindowSendMenu sendMenu: WindowSendMenu { service: root.service }
  readonly property NameClient names: NameClient {}
  readonly property Shared.ThumbnailCache thumbnails: Shared.ThumbnailCache {
    windows: Hyprland.toplevels.values.map(function(window) {
      return {address: "0x" + window.address.replace(/^0x/, ""), handle: window.wayland};
    })
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
}
