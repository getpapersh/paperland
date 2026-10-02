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
        workspaceId: w.id, monitor: monitor.name, focusOrder: c.focusHistoryID };
      windows[c.address] = item;
      return item;
    });
    entries[w.id] = { id: w.id, name: String(w.name), monitor: monitor.name,
      count: Number.isInteger(w.windows) && w.windows >= 0 ? w.windows : null,
      active: !!active, focused: !!active && !!monitor.focused,
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
