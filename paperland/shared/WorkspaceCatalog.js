// IDs are native identities, never list positions or parsed display labels.
function build(monitors, workspaces, clients) {
  var entries = {}, windows = {};
  workspaces.forEach(function(w) {
    if (!(w.id > 0)) return;
    var monitor = monitors.find(function(m) { return m.id === w.monitorID && !m.disabled; });
    if (!monitor) return;
    var active = monitor.activeWorkspace && monitor.activeWorkspace.id === w.id;
    var items = clients.filter(function(c) {
      return c.mapped && c.class !== "org.omarchy.screensaver"
        && (!c.hidden || (c.grouped && c.grouped.length > 1))
        && (c.pinned ? c.monitor === monitor.id && active : c.workspace.id === w.id);
    }).map(function(c) {
      var item = { address: c.address, stableId: c.stableId || "", title: c.title || c.class, app: c.class,
        workspaceId: w.id, monitor: monitor.name, focusOrder: c.focusHistoryID,
        floating: !!c.floating, pinned: !!c.pinned };
      windows[c.address] = item;
      return item;
    });
    entries[w.id] = { id: w.id, name: String(w.name), monitor: monitor.name,
      count: Number.isInteger(w.windows) && w.windows >= 0 ? w.windows : null,
      active: !!active, focused: !!active && !!monitor.focused, persistent: !!w.ispersistent, lastWindow: w.lastwindow || "",
      layout: w.tiledLayout, windows: items };
  });
  return { entries: entries, windows: windows };
}
function forMonitor(catalog, monitor) {
  var items = Object.keys(catalog.entries).map(function(id) { return catalog.entries[id]; })
    .filter(function(w) { return w.monitor === monitor; });
  return items.sort(function(a, b) { return a.id - b.id; });
}
function customName(entry) {
  if (!entry) return "";
  if (isSpecial(entry)) {
    var name = String(entry.name || "").replace(/^special:/, "");
    return name.toLowerCase() === "scratchpad" ? "Scratchpad" : name;
  }
  return entry.name !== String(entry.id) ? entry.name : "";
}
function isSpecial(entry) {
  return !!entry && (entry.special === true || (typeof entry.id === "number" && entry.id < 0)
    || String(entry.id || "").indexOf("special:") === 0
    || String(entry.name || "").indexOf("special:") === 0);
}
function accessibleName(entry) {
  if (!entry) return "";
  if (entry.special) return "Scratchpad, " + entry.count + (entry.count === 1 ? " window" : " windows");
  var name = customName(entry);
  return (isSpecial(entry) ? "Special workspace" + (name ? " " + name : "")
    : "Workspace " + entry.id + (name ? ", " + name : ""))
    + (entry.count === null ? ", window count unavailable" : ", " + entry.count + " windows")
    + (entry.active ? ", current on " + entry.monitor : ", on " + entry.monitor)
    + (entry.focused ? ", keyboard focused" : "");
}
/** Windows close-all would close: the positive workspace's own windows, each
 * identified by address and native stable ID so a recycled address never matches.
 * @param {{special?:boolean, windows?:{address:string, stableId?:string}[]}|null} entry
 * @returns {{address:string, stableId:string}[]}
 */
function closableWindows(entry) {
  if (!entry || isSpecial(entry) || !entry.windows) return [];
  return entry.windows.filter(function(w) {
    return /^0x[0-9a-f]+$/i.test(w.address) && /^[0-9a-f]+$/i.test(w.stableId || "");
  }).map(function(w) { return { address: w.address.toLowerCase(), stableId: w.stableId }; });
}
// PaperMac's Desktop menu wording, including its title case.
function closeAllLabel(count) {
  return "Close All " + count + " Window" + (count === 1 ? "" : "s");
}
/** PaperMac's close-all confirmation wording.
 * @param {number} count
 * @returns {{title:string, detail:string, confirm:string}}
 */
function closeConfirmation(count) {
  var one = count === 1;
  return { title: one ? "Close this window?" : "Close all " + count + " windows?",
    detail: "This closes " + count + (one ? " window" : " windows")
      + " on the workspace. Apps with unsaved changes may ask to save.",
    confirm: one ? "Close Window" : "Close " + count + " Windows" };
}
/** One compositor-side function that re-resolves each confirmed window and
 * closes it only when its stable ID, address and workspace all still match, so a
 * window that moved or a new window reusing an address is never closed.
 * @param {number} workspaceId
 * @param {{address:string, stableId:string}[]} targets Snapshot taken when the confirmation opened.
 * @returns {string} Empty when nothing valid remains.
 */
function closeCommand(workspaceId, targets) {
  if (!Number.isInteger(workspaceId) || workspaceId <= 0 || !Array.isArray(targets)) return "";
  var valid = targets.filter(function(t) {
    return !!t && /^0x[0-9a-f]+$/i.test(t.address) && /^[0-9a-f]+$/i.test(t.stableId);
  });
  if (!valid.length) return "";
  return 'function() for _,t in ipairs({' + valid.map(function(t) {
    return '{"' + t.address.toLowerCase() + '","' + t.stableId + '"}';
  }).join(",") + '}) do local w=hl.get_window("stableid:"..t[2]); '
    + 'if w and type(w.address)=="string" and string.lower(w.address)==t[1] '
    + 'and w.workspace and w.workspace.id==' + workspaceId + ' '
    + 'then hl.dispatch(hl.dsp.window.close({window=w})) end end end';
}

// ---- Remove Desktop: the Desktop's windows move to a chosen Desktop, then Hyprland deletes it.

/** @typedef {{id:number, name:string, monitor:string, active:boolean, persistent?:boolean, count:(number|null), windows:Object[]}} DesktopEntry */

/** Whether windows sent to this Desktop arrive in reverse send order. Hyprland's scrolling layout places a
 * sent window right after the focused column and does not move focus, so that happens only when the Desktop is
 * the keyboard-focused Desktop and its last focused window is tiled; a current Desktop on a display without
 * keyboard focus, an inactive Desktop or a floating last focus keeps send order
 * (nested probes, Hyprland 0.56.2).
 * @param {DesktopEntry|null} entry @returns {boolean} */
function arrivalInverts(entry) {
  if (!entry || !entry.focused || !entry.lastWindow) return false;
  var last = (entry.windows || []).find(function(w) { return w.address === entry.lastWindow; });
  return !!last && !last.floating && !last.pinned;
}
/** The order a group is dispatched to a destination so it arrives in source order.
 * @param {Array} targets Source visual order. @param {{kind:string, id:number}} destination
 * @param {Object<string, DesktopEntry>} entries Catalog entries by ID. @returns {Array} */
function groupDispatchOrder(targets, destination, entries) {
  var inverts = !!destination && destination.kind === "existing" && arrivalInverts(entries[destination.id]);
  return inverts ? targets.slice().reverse() : targets.slice();
}
/** Entries of one display in ID order. @param {DesktopEntry[]} all @param {string} monitor */
function displayEntries(all, monitor) {
  return all.filter(function(e) { return e.monitor === monitor && e.id > 0; }).sort(function(a, b) { return a.id - b.id; });
}
/** The nearest other Desktop on a display, the lower ID when both neighbours exist.
 * @param {DesktopEntry[]} all @param {{id:number, monitor:string}} entry @returns {number} 0 when there is none */
function nearestOther(all, entry) {
  var others = displayEntries(all, entry.monitor).filter(function(e) { return e.id !== entry.id; });
  var lower = others.filter(function(e) { return e.id < entry.id; });
  if (lower.length) return lower[lower.length - 1].id;
  return others.length ? others[0].id : 0;
}
/** Whether the menu offers Remove, and why it is disabled.
 * @param {DesktopEntry|null} entry @param {DesktopEntry[]} all
 * @returns {{offered:boolean, enabled:boolean, label:string}} */
function removeAvailability(entry, all) {
  if (!entry || isSpecial(entry) || !(entry.id > 0)) return { offered: false, enabled: false, label: "" };
  if (entry.persistent) return { offered: true, enabled: false, label: "Remove Desktop (held open by Hyprland)" };
  if (!nearestOther(all, entry)) return { offered: true, enabled: false, label: "Remove Desktop (only Desktop on this display)" };
  return { offered: true, enabled: true, label: "Remove Desktop…" };
}
/** Windows a removal moves: everything but pinned windows, with native identity.
 * @param {DesktopEntry|null} entry @returns {{address:string, stableId:string, floating:boolean}[]} */
function removableWindows(entry) {
  if (!entry || isSpecial(entry) || !entry.windows) return [];
  return entry.windows.filter(function(w) {
    return !w.pinned && /^0x[0-9a-f]+$/i.test(w.address) && /^[0-9a-f]+$/i.test(w.stableId || "");
  }).map(function(w) { return { address: w.address.toLowerCase(), stableId: w.stableId, floating: !!w.floating }; });
}
/** Destination rows for the card: headers by display (own display first) and one choice per other positive Desktop.
 * @param {DesktopEntry} entry
 * @param {DesktopEntry[]} all Catalog entries.
 * @param {Object[]} destinations `WindowDestinations.entries` records, the shape the native move validates.
 * @returns {{rows:Object[], defaultIndex:number}} Rows are {header,title} or {title,note,destination}. */
function removeChoices(entry, all, destinations) {
  var byId = {};
  all.forEach(function(e) { byId[e.id] = e; });
  var monitors = [entry.monitor];
  all.forEach(function(e) { if (e.id > 0 && monitors.indexOf(e.monitor) < 0) monitors.push(e.monitor); });
  var preferred = nearestOther(all, entry), rows = [], defaultIndex = -1;
  monitors.forEach(function(monitor) {
    var items = displayEntries(all, monitor).filter(function(e) { return e.id !== entry.id; });
    if (!items.length) return;
    rows.push({ header: true, title: monitor === entry.monitor ? monitor + " (this display)" : monitor });
    items.forEach(function(e) {
      var d = destinations.find(function(x) { return x.kind === "existing" && x.id === e.id && x.monitor === e.monitor; });
      if (!d) return;
      var named = customName(e), n = e.count;
      var parts = [];
      if (named) parts.push(named);
      if (e.id === preferred) parts.push("next to Desktop " + entry.id);
      parts.push(n === 0 ? "Empty" : n === null ? "" : n + (n === 1 ? " window" : " windows"));
      if (e.id === preferred) defaultIndex = rows.length;
      rows.push({ title: "Desktop " + e.id, note: parts.filter(Boolean).join(" · "), destination: Object.assign({}, d) });
    });
  });
  return { rows: rows, defaultIndex: defaultIndex };
}
/** The Desktop to land the source's display on so Hyprland can delete the emptied one.
 * @param {DesktopEntry} entry @param {DesktopEntry[]} all @param {{id:number, monitor:string}} destination
 * @returns {number} 0 when the source is not shown on its display */
function removeLanding(entry, all, destination) {
  if (!entry.active) return 0;
  return destination.monitor === entry.monitor ? destination.id : nearestOther(all, entry);
}
/** Card wording. @param {number} id @param {number} count */
function removeConfirmation(id, count, destinationId, landingId) {
  return { title: "Remove Desktop " + id + "?",
    detail: count ? "Its " + (count === 1 ? "1 window moves" : count + " windows move") + " to the Desktop you choose. No window is closed."
      : "It has no windows. This display switches to Desktop " + landingId + " and Hyprland removes Desktop " + id + ".",
    note: "Windows keep their order. " + (destinationId ? "You land on Desktop " + destinationId + ", and " : "")
      + "Desktop " + id + " goes away once it is empty.",
    confirm: "Remove Desktop" };
}
/** Order of the moved tiled windows inside their destination compared with where they were.
 * @param {string[]} stableIds Source visual order. @param {Object[]} clients Native clients.
 * @param {boolean} vertical Destination scrolls vertically. */
function orderKept(stableIds, clients, vertical) {
  var main = vertical ? 1 : 0, cross = vertical ? 0 : 1;
  var found = stableIds.map(function(id) { return clients.find(function(c) { return c.stableId === id; }); });
  if (found.some(function(c) { return !c || !c.at; })) return false;
  var sorted = found.slice().sort(function(a, b) { return a.at[main] - b.at[main] || a.at[cross] - b.at[cross]; });
  return sorted.every(function(c, i) { return c === found[i] || (c.at[main] === found[i].at[main] && c.at[cross] === found[i].at[cross]); });
}
/** Outcome from native read-back after a removal.
 * @param {number} source @param {number} destination Destination ID.
 * @param {{stableId:string, floating:boolean}[]} snapshot Windows the card counted, in source order.
 * @param {Object[]} clients `hyprctl -j clients`. @param {Object[]} workspaces `hyprctl -j workspaces`.
 * @param {boolean} vertical
 * @returns {{removed:boolean, moved:number, remaining:number, arrived:number, total:number, orderKept:boolean}} */
function removeReadback(source, destination, snapshot, clients, workspaces, vertical) {
  var mapped = clients.filter(function(c) { return c.mapped; });
  var moved = 0, remaining = 0;
  snapshot.forEach(function(w) {
    var c = mapped.find(function(x) { return x.stableId === w.stableId; });
    if (!c) return;
    if (c.workspace && c.workspace.id === destination) moved++;
    else if (c.workspace && c.workspace.id === source) remaining++;
  });
  var known = snapshot.map(function(w) { return w.stableId; });
  var arrived = mapped.filter(function(c) {
    return !c.pinned && c.workspace && c.workspace.id === source && known.indexOf(c.stableId) < 0;
  }).length;
  var tiled = snapshot.filter(function(w) { return !w.floating; }).map(function(w) { return w.stableId; });
  var onDestination = tiled.filter(function(id) {
    var c = mapped.find(function(x) { return x.stableId === id; });
    return c && c.workspace && c.workspace.id === destination;
  });
  return { removed: !workspaces.some(function(w) { return w.id === source; }), moved: moved, remaining: remaining,
    arrived: arrived, total: snapshot.length, orderKept: orderKept(onDestination, mapped, !!vertical) };
}
/** Result card wording. @param {{removed:boolean, moved:number, remaining:number, arrived:number, total:number, orderKept:boolean}} r */
function removeOutcome(r, source, destination) {
  var windows = function(n) { return n + (n === 1 ? " window" : " windows"); };
  if (r.removed) return { ok: true, title: "Desktop " + source + " removed",
    detail: (r.total ? windows(r.moved) + " moved to Desktop " + destination + "." : "It had no windows.")
      + (r.orderKept ? "" : " Their order in Desktop " + destination + " could not be confirmed.") };
  var left = r.remaining + r.arrived;
  if (!left) return { ok: false, retry: true, title: "Desktop " + source + " was not removed",
    detail: "Desktop " + source + " has no windows but Hyprland has kept it, perhaps because a display still shows it. "
      + "No window was closed. Try Again lands the display again." };
  return { ok: false, retry: true, title: "Desktop " + source + " was not removed",
    detail: (r.remaining ? r.moved + " of " + r.total + " windows are on Desktop " + destination + ". "
          : r.total ? "All " + windows(r.total) + " moved to Desktop " + destination + ". " : "")
      + windows(left) + (left === 1 ? " is" : " are") + " still on Desktop " + source + ", so it stays. No window was closed. "
      + "Try Again moves every window now on Desktop " + source + "." };
}
/** Outcome for a removal that could not start because another move is in progress. @param {number} source */
function removeBusyOutcome(source) {
  return { ok: false, retry: true, title: "Desktop " + source + " was not removed",
    detail: "Paperland is still moving other windows. Nothing was moved. Try Again in a moment." };
}
