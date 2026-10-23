/** @typedef {{onScreen: boolean, capturing: boolean, intersectsViewport: boolean, captureEnabled: boolean, live: boolean, cached: boolean, capturedAt: number, renderable: boolean, stopped: boolean}} SlotSnapshot */
/** @typedef {{surface: string, monitor: string, workspace: number, workspaceName: string, rowActive: boolean, ordinal: number, address: string, app: string, title: string, inView: boolean, floating: boolean, state: SlotSnapshot}} SlotRecord */
/** @typedef {{surface: string, monitor: string, workspace: number, workspaceName: string, ordinal: number, app: string, state: string, reason?: string, capturedAt?: number, title?: string, address?: string}} SlotRow */

/**
 * What the slot shows. Only presented frames count: the cached image's own
 * Ready status decides, and a retained cache entry alone never claims cached.
 * @param {SlotSnapshot} state
 * @returns {"live"|"cached"|"fallback"}
 */
function slotState(state) {
  if (state.live) return "live";
  if (state.cached) return "cached";
  return "fallback";
}

/**
 * Why a non-live row is not live. By-design releases rank first: a slot whose
 * capture the host disabled is parked even when a stop was recorded earlier in
 * its life, because the stop is history and the current release is deliberate.
 * A tiled window scrolled outside its active row's viewport is also a by-design
 * release: the native thumbnail stops capturing it because Hyprland cannot
 * export it there, while its slot stays enabled and on screen. The owner
 * accepted (2026-10-01) parked for that window and off-monitor for the
 * remaining non-renderable cases. "Viewport" is the compositor's (the
 * window's inView), not the strip's clip of the slot. When the capture is
 * active or scheduled without its first frame, the row reports the
 * diagnostic-only waiting reason (coordinator judgment, owner-delegated
 * 2026-10-01); a retained image still resolving with no active capture omits
 * the reason, and never-captured stays the residue without active capture or
 * retained evidence.
 * @param {SlotRecord} record
 * @returns {string|null}
 */
function slotReason(record) {
  var state = record.state;
  if (state.live) return null;
  var parkedWindow = record.rowActive && !record.floating && !record.inView;
  var byDesign = !state.captureEnabled || !state.intersectsViewport || !state.onScreen;
  if (byDesign || (!state.renderable && parkedWindow))
    return state.renderable || parkedWindow ? "parked" : "off-monitor";
  if (state.stopped) return "capture-stopped";
  if (!state.renderable) return "off-monitor";
  if (state.capturing) return "waiting-for-live-capture";
  if (state.cached || state.capturedAt > 0) return null;
  return "never-captured";
}

/**
 * One slot record from a host's actual slot item. Only visible slots with a
 * thumbnail source count: a card too small for an image hides its slot, and
 * a card showing its icon (icon density, or below a surface's image floor)
 * has an empty source, so neither has a thumbnail slot to report. The context is the row (or bar entry) the slot belongs to;
 * without a scrolling row, rowActive stays false so nothing claims parked.
 * @param {string} surface
 * @param {{id?: number, monitor?: string, name?: string, active?: boolean}|null} context
 * @param {boolean} scrollingRow True when the context is a scrolling tiled row.
 * @param {number} ordinal
 * @param {{address: string, app: string, title: string, inView?: boolean, floating?: boolean}|null} window
 * @param {{visible: boolean, thumbnailSource: *, captureReport: SlotSnapshot}|null} slot
 * @returns {SlotRecord|null}
 */
function slotRecord(surface, context, scrollingRow, ordinal, window, slot) {
  if (!window || !slot || !slot.visible || String(slot.thumbnailSource || "") === "") return null;
  return { surface: surface, monitor: context && context.monitor ? context.monitor : "",
    workspace: context && typeof context.id === "number" ? context.id : 0,
    workspaceName: context && context.name ? String(context.name) : "",
    rowActive: scrollingRow && !!(context && context.active), ordinal: ordinal,
    address: window.address, app: window.app, title: window.title,
    inView: !!window.inView, floating: !!window.floating, state: slot.captureReport };
}

/**
 * One report row. Window titles and addresses appear only when detail is
 * requested, keeping the default report scannable and safe to paste.
 * @param {SlotRecord} record
 * @param {boolean} detail
 * @returns {SlotRow}
 */
function slotRow(record, detail) {
  var snapshot = record.state;
  var row = { surface: record.surface, monitor: record.monitor, workspace: record.workspace,
    workspaceName: record.workspaceName, ordinal: record.ordinal, app: record.app,
    state: slotState(snapshot) };
  if (row.state !== "live") {
    var reason = slotReason(record);
    if (reason) row.reason = reason;
  }
  if (row.state === "cached") row.capturedAt = snapshot.capturedAt;
  if (detail) {
    row.title = record.title;
    row.address = record.address;
  }
  return row;
}

/**
 * The per-host capture report. Hosts key the reply so the standalone app and
 * the optional bar host stay separate in one paste. A surface that shows
 * thumbnails but cannot self-report is listed as a coverage gap, never omitted.
 * @param {Array<{name: string, slots: SlotRecord[], cacheRetained: number, cacheBound: number, gaps?: Array<{surface: string, reason: string}>}>} hosts
 * @param {boolean} detail
 * @returns {Object<string, {slots: SlotRow[], cache: {retained: number, bound: number}, coverageGaps?: Array<{surface: string, reason: string}>}>}
 */
function buildReport(hosts, detail) {
  var report = {};
  hosts.forEach(function(host) {
    report[host.name] = { slots: host.slots.map(function(record) { return slotRow(record, detail); }),
      cache: { retained: host.cacheRetained, bound: host.cacheBound } };
    if (host.gaps && host.gaps.length) report[host.name].coverageGaps = host.gaps;
  });
  return report;
}
