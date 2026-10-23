// Workspace pill settings and strip slot resolution. Native column identity
// arrives from the Lua snapshot; geometry only orders those columns along the
// row's effective direction. Shared by the bar widget and its Bun checks.
var ADDRESS = /^0x[0-9a-f]+$/i;
var DIRECTIONS = ["right", "left", "up", "down"];

function finiteNumber(value) {
  return typeof value === "number" && isFinite(value);
}

function asBoolean(value, fallback) {
  return typeof value === "boolean" ? value : fallback;
}

function asEnum(value, allowed, fallback) {
  return allowed.indexOf(value) >= 0 ? value : fallback;
}

// Integers only: fractions, non-numbers and non-finite values fall back before
// the 1–8 clamp, so "many" or 2.5 cannot produce a fractional slot count.
function asSlotLimit(value, fallback) {
  if (!finiteNumber(value) || value !== Math.floor(value)) return fallback;
  return Math.max(1, Math.min(8, value));
}

/**
 * Normalize one module-settings reader. Every invalid field independently uses
 * its default; `read(key, fallback)` returns the raw stored module value.
 * @param {function(string, any): any} read
 */
function normalizePillSettings(read) {
  read = read || function() { return undefined; };
  return {
    showId: asBoolean(read("showId", true), true),
    showCount: asBoolean(read("showCount", true), true),
    showName: asBoolean(read("showName", true), true),
    showIcons: asBoolean(read("showIcons", true), true),
    showFocusedTitle: asBoolean(read("showFocusedTitle", false), false),
    iconsOn: asEnum(read("iconsOn", "active"), ["all", "active", "hover"], "active"),
    maxIcons: asSlotLimit(read("maxIcons", 4), 4),
    groupByApp: asBoolean(read("groupByApp", false), false),
    iconStyle: asEnum(read("iconStyle", "color"), ["color", "mono"], "color")
  };
}

/**
 * Whether one positive-ID pill shows icons. `hover` means the hovered pill
 * only (its open passive preview counts as still hovered), never active plus
 * hover.
 * @param {{showIcons:boolean, iconsOn:string}} settings Normalized settings.
 * @param {{active:boolean, hovered:boolean}} state
 * @returns {boolean}
 */
function iconsVisible(settings, state) {
  if (!settings.showIcons) return false;
  if (settings.iconsOn === "all") return true;
  if (settings.iconsOn === "hover") return !!state.hovered;
  return !!state.active;
}

function channel(value) {
  return value <= 0.04045 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4);
}

/** WCAG contrast ratio of two colors with r, g, b in 0–1 (QML colors qualify). */
function contrastRatio(a, b) {
  function luminance(c) { return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b); }
  var x = luminance(a), y = luminance(b);
  return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
}

/**
 * Ink for mono glyphs and letter tiles against the actual pill or bar surface:
 * whichever of `dark`/`light` contrasts more, with the other as the tile fill
 * so the fill raises rather than erodes the letter's contrast.
 * @returns {{ink:object, fill:object, ratio:number}}
 */
function surfaceInk(surface, dark, light) {
  var darkRatio = contrastRatio(surface, dark), lightRatio = contrastRatio(surface, light);
  return darkRatio >= lightRatio ? { ink: dark, fill: light, ratio: darkRatio }
    : { ink: light, fill: dark, ratio: lightRatio };
}

/** A bar width read must be a finite positive logical width before Math.min. */
function finiteWidth(value, fallback) {
  return finiteNumber(value) && value > 0 ? value : fallback;
}

function validateReport(report) {
  if (!report || typeof report.generation !== "string" || !report.generation
      || !finiteNumber(report.seq) || report.seq <= 0 || report.seq !== Math.floor(report.seq)
      || !Array.isArray(report.workspaces)) return null;
  var workspaces = [];
  for (var i = 0; i < report.workspaces.length; i++) {
    var entry = report.workspaces[i];
    if (!entry || !finiteNumber(entry.id) || entry.id <= 0 || entry.id !== Math.floor(entry.id)
        || typeof entry.monitor !== "string" || !Array.isArray(entry.columns)) return null;
    var columns = [], seen = {};
    for (var j = 0; j < entry.columns.length; j++) {
      var members = entry.columns[j];
      if (!Array.isArray(members)) return null;
      var addresses = [];
      for (var k = 0; k < members.length; k++) {
        if (typeof members[k] !== "string" || !ADDRESS.test(members[k])
            || seen[members[k]]) return null;
        seen[members[k]] = true;
        addresses.push(members[k]);
      }
      columns.push(addresses);
    }
    workspaces.push({ id: entry.id, monitor: entry.monitor, columns: columns });
  }
  return { generation: report.generation, seq: report.seq, workspaces: workspaces };
}

/**
 * Parse one launcher payload. Stale addresses are pruned later against the
 * QML row, not rejected here, so routine snapshot skew cannot blank a pill.
 * @param {string} text
 * @returns {{generation:string,seq:number,workspaces:Array}|null}
 */
function parsePayload(text) {
  var report;
  try { report = JSON.parse(text); } catch (error) { return null; }
  return validateReport(report);
}

/** @param {Array<{id:number,columns:string[][]}>} workspaces @param {number} id @returns {string[][]|null} */
function workspaceColumns(workspaces, id) {
  for (var i = 0; i < (workspaces || []).length; i++) {
    if (workspaces[i].id === id) return workspaces[i].columns;
  }
  return null;
}

function origin(windows, axis) {
  var value = windows[0].rect[axis];
  for (var i = 1; i < windows.length; i++) value = Math.min(value, windows[i].rect[axis]);
  return value;
}

// The group count's corner badge. It overlaps its glyph's bottom-right corner
// and overhangs the glyph by `overhangX` right and `overhangY` below; a slot
// reserves only that overhang, so the pill's width stays honest.
var BADGE = { height: 10, overhangX: 5, overhangY: 4 };

/** Badge width for a count: a compact numeral, one digit being a 10 px disc. */
function badgeWidth(count) {
  return Math.max(BADGE.height, String(count).length * 5 + 5);
}

/**
 * Badge rectangle in slot coordinates for a glyph whose top-left is (glyphX,
 * glyphY) and whose side is `glyph`.
 * @returns {{x:number, y:number, width:number, height:number}}
 */
function badgeRect(count, glyphX, glyphY, glyph) {
  var width = badgeWidth(count);
  return { x: glyphX + glyph + BADGE.overhangX - width,
    y: glyphY + glyph + BADGE.overhangY - BADGE.height, width: width, height: BADGE.height };
}

/** True when (x, y) lies inside `rect`. */
function rectContains(rect, x, y) {
  return x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height;
}

/**
 * Slots to show: `maxIcons`, further capped by a logical-pixel width budget
 * when one is given. Under width pressure the overflow chip's width is
 * reserved and the cap may reach 0, leaving only the honest +N chip.
 * @param {{maxIcons?:number, widthBudget?:number, slotPitch?:number, chipWidth?:number}} options
 * @param {number} total
 * @returns {number}
 */
function slotLimit(options, total) {
  var limit = asSlotLimit(options.maxIcons, 4);
  var budget = options.widthBudget, pitch = options.slotPitch;
  if (!finiteNumber(budget) || !finiteNumber(pitch) || pitch <= 0) return limit;
  var chip = finiteNumber(options.chipWidth) ? options.chipWidth : 0;
  var shown = Math.min(limit, total);
  if (shown * pitch + (total > shown ? chip : 0) <= budget) return limit;
  return Math.max(0, Math.min(limit, Math.floor((budget - chip) / pitch)));
}

function bound(slots, maxIcons) {
  var truncated = slots.length > maxIcons;
  var omittedWindows = 0;
  for (var i = maxIcons; i < slots.length; i++) omittedWindows += slots[i].members.length;
  return { slots: slots.slice(0, maxIcons), hidden: truncated ? slots.length - maxIcons : 0,
    omittedWindows: omittedWindows, truncated: truncated };
}

// A slot is parked only on a row with a current viewport and only when every
// member is outside it; dividers mark each parked/in-view transition.
function makeSlot(windows, stack, options, hasViewport) {
  var representative = null;
  windows.forEach(function(w) {
    if (!representative && w.address === options.focusedAddress) representative = w;
  });
  if (!representative) representative = windows[0];
  return { representative: representative.address, app: representative.app,
    title: representative.title, stack: stack && windows.length > 1, group: false, floatStart: false,
    count: windows.length,
    parked: hasViewport && windows.every(function(w) { return !w.inView; }), divider: false,
    members: windows.map(function(w) { return w.address; }) };
}

function markDividers(slots) {
  for (var i = 1; i < slots.length; i++) slots[i].divider = slots[i].parked !== slots[i - 1].parked;
  return slots;
}

// One slot per resolved app identity in first-appearance order across every
// window in display order, so mixed-app stack members count toward their own
// apps rather than the column's representative.
function appGroups(windows, options, hasViewport) {
  var key = typeof options.appKey === "function" ? options.appKey : function(app) { return app; };
  var groups = [], byKey = {};
  windows.forEach(function(w) {
    var id = String(key(w.app));
    if (!Object.prototype.hasOwnProperty.call(byKey, id)) {
      byKey[id] = [];
      groups.push(byKey[id]);
    }
    byKey[id].push(w);
  });
  return groups.map(function(members) {
    var slot = makeSlot(members, false, options, hasViewport);
    slot.group = true;
    return slot;
  });
}

/**
 * Ordered pill slots for one scrolling row. Columns keep native membership;
 * column order follows the growth origin of the row's effective direction
 * (right/down increasing, left/up decreasing along the scroll axis) and stack
 * members read along the cross axis. Floating and pinned clients trail the
 * column run. With `groupByApp`, every window in that order is grouped by app
 * instead. Slots past `maxIcons` are reported as hidden; order is never
 * changed to promote a focused window.
 * @param {object|null} row Layout.js row; windows carry address, rect, inView,
 *   floating, pinned, app, title.
 * @param {string[][]|null} columns Native column membership for this workspace.
 * @param {{focusedAddress?:string, maxIcons?:number, groupByApp?:boolean,
 *   appKey?:function(string):string, widthBudget?:number, slotPitch?:number,
 *   chipWidth?:number}} options See slotLimit for the width budget.
 * @returns {{slots:Array, hidden:number, omittedWindows:number, truncated:boolean}|null}
 *   null when no native column survives, or when the snapshot is stale against
 *   the row: a tiled window it does not cover, a column whose members do not
 *   share one main-axis origin, or two columns at one origin (consume, expel or
 *   a move without a layout event). Fullscreen and group-hidden windows are
 *   covered but never decide those origin checks.
 *   Callers then use catalog order and request a fresh snapshot. A slot:
 *   {representative, app, title,
 *   stack, group, floatStart, count, parked, divider, members}.
 */
function columnSlots(row, columns, options) {
  if (!row || !Array.isArray(columns) || !columns.length) return null;
  options = options || {};
  var byAddress = {};
  row.windows.forEach(function(w) {
    if (!w.floating && !w.pinned) byAddress[w.address] = w;
  });
  var direction = DIRECTIONS.indexOf(row.direction) >= 0 ? row.direction
    : (row.vertical ? "down" : "right");
  var mainAxis = direction === "up" || direction === "down" ? "y" : "x";
  var crossAxis = mainAxis === "x" ? "y" : "x";
  var sign = direction === "left" || direction === "up" ? -1 : 1;
  // A fullscreen or maximized window, or a group member another tab hides,
  // reports geometry that is not its column's: it still counts as covered, but
  // never decides whether the snapshot's columns agree with the row.
  function placed(w) { return !w.fullscreen && !w.hidden; }
  var columnList = [], covered = {}, consistent = true;
  columns.forEach(function(members) {
    var windows = [];
    (members || []).forEach(function(address) {
      var w = byAddress[address];
      if (w && windows.indexOf(w) < 0) windows.push(w);
    });
    if (!windows.length) return;
    var anchor = windows.filter(placed)[0];
    windows.forEach(function(w) {
      covered[w.address] = true;
      if (anchor && placed(w) && w.rect[mainAxis] !== anchor.rect[mainAxis]) consistent = false;
    });
    windows.sort(function(a, b) { return a.rect[crossAxis] - b.rect[crossAxis]; });
    columnList.push(windows);
  });
  if (!columnList.length || !consistent) return null;
  for (var address in byAddress) if (!covered[address]) return null;
  // Distinct native columns never share an origin: two that do were merged
  // (consume) after the snapshot was taken.
  var origins = {};
  function columnOrigin(windows) {
    var settled = windows.filter(placed);
    return origin(settled.length ? settled : windows, mainAxis);
  }
  for (var c = 0; c < columnList.length; c++) {
    if (!columnList[c].some(placed)) continue;
    var start = columnOrigin(columnList[c]);
    if (origins[start]) return null;
    origins[start] = true;
  }
  columnList.sort(function(a, b) {
    return sign * (columnOrigin(a) - columnOrigin(b));
  });
  // A viewport claim exists only on the active row; inactive rows stay neutral.
  var hasViewport = !!row.active;
  var floats = row.windows.filter(function(w) { return w.floating || w.pinned; });
  var slots;
  if (options.groupByApp) {
    var ordered = [];
    columnList.forEach(function(windows) { ordered = ordered.concat(windows); });
    slots = appGroups(ordered.concat(floats), options, hasViewport);
  } else {
    slots = columnList.map(function(windows) { return makeSlot(windows, true, options, hasViewport); })
      .concat(floats.map(function(w, i) {
        // The first floating or pinned slot opens a separate trailing run.
        var slot = makeSlot([w], false, options, hasViewport);
        slot.floatStart = i === 0;
        return slot;
      }));
  }
  return bound(markDividers(slots), slotLimit(options, slots.length));
}

/**
 * Column slots that survive the gap between a window event and its fresh
 * snapshot. A window opening or closing makes the row move first (about 60 ms)
 * while the snapshot needs the Lua settle, a launcher round trip and a file
 * watch (a few hundred ms); catalog order in between would split stacks and
 * drop parked dimming for a flash. While the resolver refuses, the last good
 * result for the same workspace is held for `holdMs`, then given up.
 * @param {{result:object|null, at:number}|null} held The last good result.
 * @param {object|null} fresh This evaluation's columnSlots result.
 * @param {number} now Milliseconds.
 * @param {number} holdMs
 * @returns {{show:object|null, held:{result:object|null, at:number}|null, stale:boolean}}
 *   `show` is what to draw (null means catalog order); `stale` asks for a fresh snapshot.
 */
function holdColumns(held, fresh, now, holdMs) {
  if (fresh) return { show: fresh, held: { result: fresh, at: now }, stale: false };
  if (held && held.result && now - held.at < holdMs) return { show: held.result, held: held, stale: true };
  return { show: null, held: null, stale: true };
}

/**
 * Fallback slots for workspaces without native strip columns: activatable
 * clients in catalog order with no column or parked-state claim, grouped by
 * app with `groupByApp`.
 * @param {Array<{address:string,app:string,title:string}>} windows
 * @param {{focusedAddress?:string, maxIcons?:number, groupByApp?:boolean,
 *   appKey?:function(string):string}} options
 * @returns {{slots:Array, hidden:number, omittedWindows:number, truncated:boolean}}
 */
function catalogSlots(windows, options) {
  options = options || {};
  windows = windows || [];
  var slots = options.groupByApp ? appGroups(windows, options, false)
    : windows.map(function(w) { return makeSlot([w], false, options, false); });
  return bound(slots, slotLimit(options, slots.length));
}
