/** Native attention state keyed by the same 0x-prefixed identities as Service. */

/** Publish a new snapshot only when a validated native event changes membership.
 * Empty layer focus does not identify a client and clears nothing.
 * @param {Object<string, boolean>} urgent
 * @param {string} name
 * @param {unknown} data Native socket2 data: a bare hexadecimal address.
 * @returns {Object<string, boolean>}
 */
function reduce(urgent, name, data) {
  if (["urgent", "activewindowv2", "closewindow"].indexOf(name) < 0
      || typeof data !== "string" || !/^[0-9a-f]+$/i.test(data)) return urgent;
  var address = "0x" + data.toLowerCase();
  var added = name === "urgent";
  if (!!urgent[address] === added) return urgent;
  var next = Object.assign({}, urgent);
  if (added) next[address] = true;
  else delete next[address];
  return next;
}

/** Same floating contract as Layout.isFloating: Hyprland floats pinned windows. */
function floating(window) { return !!(window.floating || window.pinned); }

/**
 * Workspace ids holding urgent windows, keyed like Catalog entries so pills
 * look their own id up directly. An urgent-before-openwindow address has no
 * record yet and contributes nothing until the window exists.
 * @param {Object<string, boolean>} urgentAddresses
 * @param {Object<string, {workspaceId:number}>} windows Address-keyed window records.
 * @returns {Object<number, boolean>}
 */
function forWorkspaces(urgentAddresses, windows, focusedAddress) {
  var result = {};
  Object.keys(urgentAddresses).forEach(function(address) {
    if (address === focusedAddress) return;
    var window = windows[address];
    if (window) result[window.workspaceId] = true;
  });
  return result;
}

/**
 * Every mapped client, whatever its layout, workspace or display. Pruning must
 * not use a view that drops windows (the scrolling layout omits dwindle and
 * master workspaces, the catalogue omits special workspaces).
 * @param {Array<{address?: string, mapped?: boolean}>} clients Native client records.
 * @returns {Object<string, boolean>}
 */
function mapped(clients) {
  var result = {};
  clients.forEach(function(client) {
    if (client && client.mapped === true && typeof client.address === "string") result[client.address] = true;
  });
  return result;
}

/**
 * Drop records for addresses no mapped client carries after graceMs. A
 * request for a window that never maps (urgent>> precedes the mapped check)
 * or for a reused heap address would otherwise survive forever.
 * @param {Object<string, boolean>} urgent Current records.
 * @param {Object<string, number>} since Address -> Date.now() when recorded.
 * @param {Object<string, unknown>} windows Addresses of every mapped client, from `mapped`.
 * @param {number} now Date.now()
 * @param {number} graceMs How long an unknown address may persist.
 * @returns {{urgent: Object<string, boolean>, since: Object<string, number>}}
 */
function prune(urgent, since, windows, now, graceMs) {
  var nextUrgent = null, nextSince = null;
  Object.keys(urgent).forEach(function(address) {
    if (windows[address] || now - (since[address] || 0) < graceMs) return;
    if (!nextUrgent) {
      nextUrgent = Object.assign({}, urgent);
      nextSince = Object.assign({}, since);
    }
    delete nextUrgent[address];
    delete nextSince[address];
  });
  return { urgent: nextUrgent || urgent, since: nextSince || since };
}

/**
 * Urgent tiled windows parked off a displayed row's viewport, counted per
 * physical side along the scroll axis: `start` is left/top and `end` is
 * right/bottom regardless of the native forward/reverse direction. Floating
 * and pinned windows have no column to park and never count; nor does the
 * focused window. A window counts only when it lies wholly beyond one
 * viewport edge on the scroll axis while overlapping the viewport on the
 * cross axis — cross-axis non-overlap alone is not axis parking.
 * @param {object} row Layout.build row with viewport and window rects.
 * @param {Object<string, boolean>} urgentAddresses
 * @param {string} focusedAddress
 * @returns {{start:{count:number, addresses:string[], titles:string[]}, end:{count:number, addresses:string[], titles:string[]}}}
 */
function parkedCounts(row, urgentAddresses, focusedAddress) {
  var counts = { start: { count: 0, addresses: [], titles: [] }, end: { count: 0, addresses: [], titles: [] } };
  if (!row || !row.viewport) return counts;
  var vertical = !!row.vertical;
  var view = row.viewport;
  row.windows.forEach(function(window) {
    if (!urgentAddresses[window.address] || window.address === focusedAddress || floating(window)) return;
    var rect = window.rect;
    var axisStart = vertical ? rect.y : rect.x;
    var axisSize = vertical ? rect.height : rect.width;
    var viewStart = vertical ? view.y : view.x;
    var viewSize = vertical ? view.height : view.width;
    var crossStart = vertical ? rect.x : rect.y;
    var crossSize = vertical ? rect.width : rect.height;
    var viewCrossStart = vertical ? view.x : view.y;
    var viewCrossSize = vertical ? view.width : view.height;
    if (crossStart >= viewCrossStart + viewCrossSize || crossStart + crossSize <= viewCrossStart) return;
    var side = null;
    if (axisStart >= viewStart + viewSize) side = counts.end;
    else if (axisStart + axisSize <= viewStart) side = counts.start;
    if (!side) return;
    side.count++;
    side.addresses.push(window.address);
    side.titles.push(window.title);
  });
  return counts;
}
