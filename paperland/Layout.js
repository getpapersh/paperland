function monitorRect(monitor) {
  var rotated = monitor.transform % 2 !== 0;
  return {
    x: monitor.x, y: monitor.y,
    width: (rotated ? monitor.height : monitor.width) / monitor.scale,
    height: (rotated ? monitor.width : monitor.height) / monitor.scale
  };
}

function intersects(a, b) {
  return a.x < b.x + b.width && a.x + a.width > b.x
    && a.y < b.y + b.height && a.y + a.height > b.y;
}

/** Smallest logical rectangle holding the viewport and every window. */
function span(viewport, windows) {
  var left = viewport.x, top = viewport.y;
  var right = viewport.x + viewport.width, bottom = viewport.y + viewport.height;
  windows.forEach(function(w) {
    left = Math.min(left, w.rect.x); top = Math.min(top, w.rect.y);
    right = Math.max(right, w.rect.x + w.rect.width);
    bottom = Math.max(bottom, w.rect.y + w.rect.height);
  });
  return { x: left, y: top, width: right - left, height: bottom - top };
}

/** Hyprland always floats pinned windows; neither kind has a column on the canvas. */
function isFloating(window) { return !!(window.floating || window.pinned); }

/**
 * The row as the minimap strip draws it: tiled windows only, with bounds that
 * span the viewport and those windows. Other views keep the full row.
 * @param {object} row
 * @return {object}
 */
function tiledRow(row) {
  if (!row) return row;
  var windows = row.windows.filter(function(w) { return !isFloating(w); });
  if (windows.length === row.windows.length) return row;
  return Object.assign({}, row, { windows: windows, bounds: span(row.viewport, windows) });
}

/** Native scrolling columns in visual order; stacked members share a main-axis box. */
function columns(row) {
  if (!row) return [];
  var groups = [];
  tiledRow(row).windows.forEach(function(window) {
    var start = row.vertical ? window.rect.y : window.rect.x;
    var size = row.vertical ? window.rect.height : window.rect.width;
    var last = groups[groups.length - 1];
    if (last && last.start === start && last.size === size) last.windows.push(window);
    else groups.push({ start: start, size: size, windows: [window] });
  });
  return groups;
}

/** True only when every native member of at least one multiwindow stack is selected. */
function hasCompleteStack(row, addresses) {
  return columns(row).some(function(column) {
    return column.windows.length > 1 && column.windows.every(function(window) { return addresses.indexOf(window.address) >= 0; });
  });
}

/** Native promote/swap sequence for a same-Desktop card drop. */
function reorderPlan(row, addresses, anchor, after) {
  if (!row || !addresses.length || addresses.indexOf(anchor) >= 0) return null;
  var reversed = row.direction === "left" || row.direction === "up";
  var selected = function(address) { return addresses.indexOf(address) >= 0; };
  var current = [], promotions = [];
  columns(row).forEach(function(column) {
    var members = column.windows.map(function(window) { return window.address; });
    var chosen = members.filter(selected), remaining = members.filter(function(address) { return !selected(address); });
    if (chosen.length && remaining.length) {
      if (!reversed) current.push({ members: remaining, selected: false });
      chosen.forEach(function(address) { current.push({ members: [address], selected: true }); });
      if (reversed) current.push({ members: remaining, selected: false });
      (reversed ? chosen : chosen.slice().reverse()).forEach(function(address) {
        promotions.push({ kind: "promote", address: address });
      });
    } else current.push({ members: members, selected: chosen.length > 0 });
  });
  var target = current.find(function(column) { return column.members.indexOf(anchor) >= 0; });
  if (!target || target.selected) return null;
  var moving = current.filter(function(column) { return column.selected; });
  if (!moving.length) return null;
  var remainingColumns = current.filter(function(column) { return !column.selected; });
  var insertion = remainingColumns.indexOf(target) + (after ? 1 : 0);
  var desired = remainingColumns.slice();
  desired.splice.apply(desired, [insertion, 0].concat(moving));
  var order = current.slice(), swaps = [];
  function bubble(column, direction) {
    while (order.indexOf(column) !== desired.indexOf(column)) {
      var index = order.indexOf(column), next = index + direction;
      swaps.push({ kind: "swap", address: column.members[0], direction: (reversed ? -direction : direction) > 0 ? "r" : "l" });
      order[index] = order[next]; order[next] = column;
    }
  }
  moving.filter(function(column) { return desired.indexOf(column) < current.indexOf(column); })
    .forEach(function(column) { bubble(column, -1); });
  moving.filter(function(column) { return desired.indexOf(column) > current.indexOf(column); })
    .reverse().forEach(function(column) { bubble(column, 1); });
  return { steps: promotions.concat(swaps), desired: desired.map(function(column) { return column.members; }) };
}

/**
 * True when the row has tiled windows but none in view, so a drag past the
 * last column left the canvas empty. Floating windows never count as in view:
 * they sit over the viewport wherever the canvas is.
 * @param {object} row
 * @return {boolean}
 */
function stranded(row) {
  var tiled = row ? row.windows.filter(function(w) { return !isFloating(w); }) : [];
  return tiled.length > 0 && !tiled.some(function(w) { return w.inView; });
}

function build(monitors, workspaces, clients, directions) {
  directions = directions || {};
  var rows = {};
  var ids = [];
  var windows = {};
  workspaces.forEach(function(workspace) {
    if (workspace.tiledLayout !== "scrolling") return;
    var monitor = monitors.find(function(m) { return m.id === workspace.monitorID && !m.disabled; });
    if (!monitor) return;
    var viewport = monitorRect(monitor);
    // While a special workspace is open, activeworkspace keeps reporting the
    // underlying desktop workspace; its open state lives on the monitor's
    // specialWorkspace. Only the scratchpad row may take it, so no other
    // special or named workspace becomes a displayed row.
    var scratchpadOpen = workspace.id < 0 && workspace.name === "special:scratchpad"
      && !!monitor.specialWorkspace && monitor.specialWorkspace.name === workspace.name;
    var active = workspace.id > 0 ? monitor.activeWorkspace.id === workspace.id : scratchpadOpen;
    var items = clients.filter(function(c) {
      // `visible` is false for off-screen/fullscreen-covered windows: these
      // are precisely the windows the map must still make reachable.
      return c.mapped && c.class !== "org.omarchy.screensaver" && (!c.hidden || (c.grouped && c.grouped.length > 1))
        && (c.pinned ? c.monitor === monitor.id && active : c.workspace.id === workspace.id);
    }).map(function(c) {
      var rect = { x: c.at[0], y: c.at[1], width: c.size[0], height: c.size[1] };
      var window = {
        address: c.address, stableId: c.stableId, title: c.title || c.class, app: c.class,
        focusOrder: c.focusHistoryID,
        rect: rect, workspaceId: workspace.id, monitor: monitor.name,
        inView: active && intersects(rect, viewport), visible: active && !c.hidden && c.visible !== false && intersects(rect, viewport), floating: c.floating,
        pinned: c.pinned, fullscreen: c.fullscreen > 0,
        groupSize: c.grouped ? c.grouped.length : 0
      };
      windows[c.address] = window;
      return window;
    });
    var bounds = span(viewport, items);
    var managed = directions.managed;
    var direction = managed && managed.enabled
      ? workspace.id > 0 && !managed.native_direction_available ? ""
        : (workspace.id > 0 && managed.desktops && managed.desktops[workspace.id])
          || managed.monitors[monitor.name] || ""
      : directions[workspace.id] || directions.global || "";
    var desktopDirection = managed && managed.enabled && workspace.id > 0
      && managed.desktops && managed.desktops[workspace.id];
    var vertical = direction ? direction === "up" || direction === "down"
      : bounds.height / viewport.height > bounds.width / viewport.width;
    items.sort(function(a, b) {
      return vertical ? a.rect.y - b.rect.y || a.rect.x - b.rect.x
        : a.rect.x - b.rect.x || a.rect.y - b.rect.y;
    });
    rows[workspace.id] = {
      id: workspace.id, name: workspace.name, monitor: monitor.name,
      active: active, fullscreen: workspace.hasfullscreen, vertical: vertical, direction: direction,
      directionSource: managed && managed.enabled ? (workspace.id > 0 && !managed.native_direction_available ? "unknown"
        : desktopDirection ? "desktop direction"
        : direction ? "monitor policy" : "unknown")
        : directions[workspace.id] ? "workspace setting" : directions.global ? "global setting" : "unknown",
      viewport: viewport,
      bounds: bounds,
      windows: items
    };
    ids.push(workspace.id);
  });
  ids.sort(function(a, b) { return rows[a].monitor.localeCompare(rows[b].monitor) || a - b; });
  return { rows: rows, ids: ids, windows: windows };
}

function matches(window, query) {
  return !query || (window.title + " " + window.app + " " + window.monitor).toLowerCase().indexOf(query.toLowerCase()) !== -1;
}

function sidebar(rows, ids, query, scope, monitor, workspace, workspaceNameFor) {
  var ordered = ids.filter(function(id) { return !!rows[id]; });
  // Bring the opening display forward without letting later focus events
  // reorder the list underneath keyboard navigation.
  ordered = ordered.filter(function(id) { return rows[id].monitor === monitor; })
    .concat(ordered.filter(function(id) { return rows[id].monitor !== monitor; }));
  var seen = {};
  var items = [];
  ordered.forEach(function(id) {
    var row = rows[id];
    if (scope !== "all" && row.monitor !== monitor) return;
    if (scope === "workspace" && row.id !== workspace) return;
    var windows = row.windows.filter(function(w) {
      if (seen[w.address] || !matches(w, query)) return false;
      seen[w.address] = true;
      return true;
    });
    var customName = workspaceNameFor ? workspaceNameFor(row) : "";
    windows.forEach(function(w) {
      items.push({ address: w.address,
        sectionLabel: row.monitor + " · " + (customName || row.name) });
    });
  });
  return items;
}

/** @param {string} app @returns {string} Browser web-app host, or empty for other classes. */
function webAppHost(app) {
  var match = /^(?:google-chrome|microsoft-edge|brave-browser|chrome|chromium|brave|msedge|vivaldi|opera|helium)-([a-z0-9-]+(?:\.[a-z0-9-]+)+)__-?.*$/i.exec(app);
  return match ? match[1].toLowerCase() : "";
}

function appName(app) {
  var host = webAppHost(app);
  if (host) {
    // Generic subdomains identify the web launcher, not the product.
    var label = host.replace(/^(?:(?:www|app|web)\.)+/, "").split(".")[0];
    return label.charAt(0).toUpperCase() + label.slice(1);
  }
  return app.replace(/^com\.|^org\./, "").split(".").pop().replace(/^google-/, "").replace(/-/g, " ");
}

/**
 * @param {Array<{id:string,name:string,execString?:string}>} entries Installed desktop entry records.
 * @param {string} app Hyprland window class.
 * @returns {{id:string,name:string,execString?:string}|null}
 */
function desktopEntry(entries, app) {
  var host = webAppHost(app);
  if (host) {
    // Match the launch URL before a short label can select an unrelated app.
    var byUrl = entries.find(function(entry) {
      var url = /https?:\/\/([^/\s"'?#:]+)/i.exec(entry.execString || "");
      return url && url[1].toLowerCase() === host;
    });
    if (byUrl) return byUrl;
    // A specific subdomain can share its short label with an unrelated desktop app.
    if (host.split(".").length > 2 && !/^(?:www|app|web)\./.test(host)) return null;
  }
  var wanted = appName(app).toLowerCase();
  return entries.find(function(entry) {
    return entry.id.toLowerCase() === wanted || entry.name.toLowerCase() === wanted;
  }) || null;
}

function hitTest(row, x, y, focused) {
  var hits = row.windows.filter(function(w) {
    return x >= w.rect.x && x <= w.rect.x + w.rect.width
      && y >= w.rect.y && y <= w.rect.y + w.rect.height;
  });
  return hits.find(function(w) { return w.address === focused; }) || hits[hits.length - 1] || null;
}

function panRequest(row, delta) {
  if (!row || !row.active || row.fullscreen || !isFinite(delta) || !validDirection(row.direction)) return null;
  // Numeric layout moves use tape coordinates; LEFT/UP reverse their physical
  // translation. The map gesture is always right/down in logical pixels.
  var sign = row.direction === "left" || row.direction === "up" ? 1 : -1;
  return 'hl.dsp.layout("move ' + String(sign * Math.round(delta)) + '")';
}

/**
 * Lua guard for a wrapped pan dispatch. The QML snapshot can go stale between
 * the eligibility check and the compositor running the move, and the unqualified
 * layoutmsg acts on whichever tape is displayed then — so the active monitor
 * must still own the row, and the scratchpad must be open for a followed row
 * and closed for a desktop row. `sp` is the active special workspace or nil.
 * @param {boolean} followedRow True for a negative (followed scratchpad) row.
 * @return {string}
 */
function panGuard(followedRow) {
  return followedRow
    ? 'if sp == nil or sp.name ~= "special:scratchpad" then return end '
    : 'if sp ~= nil then return end ';
}

function validDirection(value) { return ["right", "left", "down", "up"].indexOf(value) >= 0; }

/**
 * Address of the tiled window whose centre is nearest the viewport centre along
 * the scrolling axis, or "" when the row has none. Floating windows have no
 * column to settle on, so they are never the landing. Read from observed geometry, not
 * from a requested displacement: Hyprland clamps at canvas boundaries, so the
 * window a drag lands on is not always the one its delta aimed at.
 * @param {object} row
 * @return {string}
 */
function centreWindow(row) {
  if (!row || !row.windows || !row.windows.length) return "";
  var vertical = !!row.vertical;
  var view = row.viewport;
  var middle = vertical ? view.y + view.height / 2 : view.x + view.width / 2;
  var best = null, bestDistance = Infinity;
  row.windows.forEach(function(window) {
    if (isFloating(window)) return;
    var rect = window.rect;
    var centre = vertical ? rect.y + rect.height / 2 : rect.x + rect.width / 2;
    var distance = Math.abs(centre - middle);
    // Ties resolve to the earlier window in the row's own sorted order, so the
    // preview does not flicker between two equidistant columns mid-drag.
    if (distance < bestDistance) { best = window; bestDistance = distance; }
  });
  return best ? best.address : "";
}

/** Special workspaces (negative id or "special:" name) sort after the numbered desktops. */
function isSpecialRow(row) {
  return !!row && (row.id < 0 || String(row.name || "").indexOf("special:") === 0);
}

/**
 * Displays currently rendering a strip: monitors whose remembered visibility
 * is revealed AND that have a displayed row right now. A display parked on a
 * non-scrolling workspace keeps its revealed state while drawing nothing, so
 * counting visibility alone over-reports and the minimap toggle hides into
 * nothing, needing a second press.
 * @param {Record<string, boolean>} displayVisibility Remembered per-monitor strip visibility.
 * @param {function(string): boolean} hasDisplayedRow True when the monitor's strip has a row to draw.
 * @return {number}
 */
function countVisibleDisplays(displayVisibility, hasDisplayedRow) {
  var count = 0;
  Object.keys(displayVisibility).forEach(function(monitor) {
    if (displayVisibility[monitor] && hasDisplayedRow(monitor)) count++;
  });
  return count;
}

/** Order scrolling workspace identities without including mutable window snapshots. */
function overviewOrder(rows, ids, openingMonitor) {
  return ids.filter(function(id) { return !!rows[id]; }).sort(function(a, b) {
    var left = rows[a], right = rows[b];
    if (left.monitor !== right.monitor) {
      if (left.monitor === openingMonitor) return -1;
      if (right.monitor === openingMonitor) return 1;
      return left.monitor.localeCompare(right.monitor);
    }
    var leftSpecial = isSpecialRow(left), rightSpecial = isSpecialRow(right);
    if (leftSpecial !== rightSpecial) return leftSpecial ? 1 : -1;
    return Number(!!right.active) - Number(!!left.active) || a - b;
  });
}

/** The spatial layout also admits named workspace IDs omitted by the numeric bar catalog. */
function overviewEntry(catalog, row) {
  if (!row) return null;
  return catalog.entries[row.id] || {id: row.id, name: row.name, monitor: row.monitor,
    active: row.active, count: null, windows: row.windows};
}
