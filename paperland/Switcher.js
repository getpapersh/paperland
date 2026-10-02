/** Build distinct records from Hyprland clients/monitors IPC snapshots.
 * @param {Array<{address:string, stableId?:string, mapped:boolean, hidden:boolean, grouped:string[], class:string, title:string, monitor:number, workspace:{id:number,name:string}, focusHistoryID:number, floating:boolean, size:number[]}>} clients
 * @param {Array<{id:number,name:string,disabled:boolean}>} monitors
 * @returns {Object<string,{address:string,stableId:string,app:string,title:string,workspaceId:number,workspaceName:string,monitor:string,focusOrder:number,floating:boolean,aspect:number}>}
 */
function windows(clients, monitors) {
  var result = {};
  clients.forEach(function(c) {
    if (!c.mapped || c.class === "org.omarchy.screensaver"
        || (c.hidden && !(c.grouped && c.grouped.length > 1))) return;
    var monitor = monitors.find(function(m) { return m.id === c.monitor && !m.disabled; });
    if (!monitor) return;
    result[c.address] = {address: c.address, stableId: c.stableId || "", app: c.class, title: c.title || c.class,
      workspaceId: c.workspace.id, workspaceName: c.workspace.name,
      monitor: monitor.name, focusOrder: c.focusHistoryID, floating: c.floating,
      aspect: c.size && c.size[1] > 0 ? c.size[0] / c.size[1] : 16 / 9};
  });
  return result;
}
/** Retain observed recency; seed unseen identities from the native snapshot.
 * @param {Object<string,{focusOrder:number}>} windows
 * @param {string[]} previous
 * @param {string} focused
 * @returns {string[]}
 */
function recent(windows, previous, focused) {
  var ids = previous.filter(function(id) { return !!windows[id]; });
  Object.keys(windows).sort(function(a,b) {
    var ar = windows[a].focusOrder, br = windows[b].focusOrder;
    return (ar >= 0 ? ar : Infinity) - (br >= 0 ? br : Infinity) || a.localeCompare(b);
  }).forEach(function(id) { if (ids.indexOf(id) < 0) ids.push(id); });
  if (windows[focused]) ids = [focused].concat(ids.filter(function(id) { return id !== focused; }));
  return ids;
}
/** Navigate a frozen MRU order. Vertical movement skips missing cells in its column.
 * @param {string[]} ids
 * @param {string} selected
 * @param {number} delta Signed 1 or rendered column count.
 * @param {number} columns Positive rendered column count.
 * @returns {string}
 */
function step(ids, selected, delta, columns) {
  if (!ids.length) return "";
  var index = Math.max(0, ids.indexOf(selected));
  if (Math.abs(delta) === 1) return ids[(index + delta + ids.length) % ids.length];
  var rows = Math.ceil(ids.length / columns), column = index % columns;
  var row = Math.floor(index / columns), direction = delta < 0 ? -1 : 1;
  do { row = (row + direction + rows) % rows; } while (row * columns + column >= ids.length);
  return ids[row * columns + column];
}
/** Positional bonus for a matched character: prefix > separator boundary or camel hump > plain.
 * @param {string} c Candidate in original case.
 * @param {number} j Matched index.
 * @returns {number}
 */
function charScore(c, j) {
  if (j === 0) return 13;
  var prev = c[j - 1] || "", ch = c[j] || "";
  if (!/[0-9]/.test(prev) && prev.toLowerCase() === prev.toUpperCase()) return 10;
  if (prev !== prev.toUpperCase() && ch !== ch.toLowerCase()) return 10;
  return 1;
}
/** Best-alignment score of query as a case-insensitive subsequence of candidate (PaperMac FuzzyMatch).
 * @param {string} query
 * @param {string} candidate
 * @returns {number|null} Higher is better; null when query is not a subsequence.
 */
function fuzzyScore(query, candidate) {
  if (!query) return 0;
  var q = query.toLowerCase(), cl = candidate.toLowerCase(), none = -Infinity;
  if (q.length > cl.length) return null;
  var row = [], i, j;
  for (j = 0; j < cl.length; j++) row.push(cl[j] === q[0] ? charScore(candidate, j) - Math.min(j, 6) : none);
  for (i = 1; i < q.length; i++) {
    var next = [], before = none;
    for (j = 0; j < cl.length; j++) {
      var prior = before;
      if (j > 0) prior = Math.max(prior, row[j - 1] + 6);
      next.push(cl[j] === q[i] && prior !== none ? charScore(candidate, j) + prior : none);
      before = Math.max(before, row[j]);
    }
    row = next;
  }
  var best = Math.max.apply(null, row);
  return best === none ? null : best;
}
/** Rank switcher candidates for a typed query. Fuzzy splits on whitespace into AND tokens and
 * sorts by score (stable); exact keeps input order of case-insensitive substring matches.
 * @param {string} query
 * @param {string} mode "fuzzy" or "exact".
 * @param {Array<{id:string, fields:string[]}>} candidates Fields most significant first.
 * @returns {string[]} Matching ids, best first.
 */
function search(query, mode, candidates) {
  var all = candidates.map(function(c) { return c.id; });
  if (mode === "exact") {
    var needle = query.trim().toLowerCase();
    if (!needle) return all;
    return candidates.filter(function(c) {
      return c.fields.some(function(f) { return f.toLowerCase().indexOf(needle) >= 0; });
    }).map(function(c) { return c.id; });
  }
  var tokens = query.split(/\s+/).filter(function(t) { return t; });
  if (!tokens.length) return all;
  var scored = [];
  candidates.forEach(function(c, index) {
    var total = 0;
    for (var t = 0; t < tokens.length; t++) {
      var best = null;
      c.fields.forEach(function(f, fi) {
        var s = fuzzyScore(tokens[t], f);
        // An app-name hit edges out an equal title hit.
        if (s !== null) best = Math.max(best === null ? -Infinity : best, s + c.fields.length - 1 - fi);
      });
      if (best === null) return;
      total += best;
    }
    scored.push({id: c.id, score: total, index: index});
  });
  scored.sort(function(a, b) { return b.score - a.score || a.index - b.index; });
  return scored.map(function(s) { return s.id; });
}
/** Whether key text should edit the switcher query.
 * @param {string} text
 * @returns {boolean}
 */
function printable(text) {
  if (!text) return false;
  for (var i = 0; i < text.length; i++) {
    var code = text.charCodeAt(i);
    if (code < 32 || code === 127) return false;
  }
  return true;
}
/** Card size presets in cycle order (PaperMac's SWITCHER SIZE control). Large is the default. */
var SIZES = ["small", "medium", "large", "xl"];
var SIZE_LABELS = {small: "Small", medium: "Medium", large: "Large", xl: "XL"};
var SIZE_HINTS = {small: "760×520", medium: "940×680", large: "1120×80%", xl: "Full height"};
/** The preset after `preset`, wrapping XL to Small; an unknown preset counts as Large.
 * @param {string} preset
 * @returns {string}
 */
function nextSize(preset) {
  var index = SIZES.indexOf(preset);
  return SIZES[((index < 0 ? 2 : index) + 1) % SIZES.length];
}
/** Card caps for a preset on a display, in logical pixels. Non-XL cards shrink to their content.
 * @param {string} preset
 * @param {number} width Display width.
 * @param {number} height Display height.
 * @returns {{width:number, height:number, fill:boolean}} fill: XL stretches to the cap.
 */
function cardSize(preset, width, height) {
  var w = preset === "small" ? 760 : preset === "medium" ? 940 : 1120;
  var h = preset === "small" ? 520 : preset === "medium" ? 680 : preset === "xl" ? height - 80 : height * 0.8;
  return {width: Math.max(0, Math.min(w, width - 48)), height: Math.max(0, Math.min(h, height - 80)), fill: preset === "xl"};
}
/** Card location. Special workspaces (such as the scratchpad) are PaperMac's “Other” bucket; named
 * workspaces also have negative ids but are ordinary workspaces, so the name prefix decides.
 * @param {{monitor:string, workspaceName:string}} w
 * @returns {string}
 */
function location(w) {
  var name = String(w.workspaceName || "");
  if (name.indexOf("special:") !== 0) return w.monitor + " · " + name;
  name = name.slice(8);
  return w.monitor + " · Other" + (!name ? "" : " · " + (name.toLowerCase() === "scratchpad" ? "Scratchpad" : name));
}
