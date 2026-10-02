// Lua owns the numbering. Both shells use this module to validate reports and
// snapshots without deriving presentation order themselves.
var STALE_MS = 15000;
var MAX_BADGES = 9;

/** @typedef {{address:string, rect:{x:number,y:number,width:number,height:number}, floating:boolean, pinned:boolean, groupSize:number}} BadgeWindow */
/** @typedef {{id:string|number, monitor:string, fullscreen:boolean, windows:BadgeWindow[]}} BadgeRow */
/** @typedef {{addresses:string[],timestamp:number,generation:string,seq:number,layoutSignature:string}} BadgeSnapshot */

function finiteNumber(value) {
  return typeof value === "number" && isFinite(value);
}

/**
 * Parse one launcher payload. A clear is explicit; malformed data cannot turn
 * into a clear that would supersede a valid report.
 * @param {string} payload
 * @returns {{generation:string,seq:number,windows:Array|null}|null}
 */
function parseReport(payload) {
  var report;
  try { report = JSON.parse(payload); } catch (error) { return null; }
  var generation = report && report.generation === undefined ? "legacy" : report && report.generation;
  if (!report || !finiteNumber(report.seq) || report.seq <= 0
      || report.seq !== Math.floor(report.seq)
      || typeof generation !== "string" || !generation
      || !Object.prototype.hasOwnProperty.call(report, "windows")
      || (report.windows !== null && !Array.isArray(report.windows))) return null;
  return { generation: generation, seq: report.seq, windows: report.windows };
}

/**
 * Validate the shared FileView record before comparing or applying it.
 * @param {Object|null} value
 * @returns {BadgeSnapshot|null}
 */
function parseSnapshot(value) {
  var generation = value && value.generation === undefined ? "legacy" : value && value.generation;
  if (!value || typeof value !== "object" || !Array.isArray(value.addresses)
      || value.addresses.length > MAX_BADGES || !finiteNumber(value.timestamp)
      || value.timestamp < 0 || !finiteNumber(value.seq) || value.seq <= 0
      || value.seq !== Math.floor(value.seq) || typeof generation !== "string" || !generation
      || typeof value.layoutSignature !== "string") return null;
  return { addresses: value.addresses, timestamp: value.timestamp, generation: generation, seq: value.seq,
    layoutSignature: value.layoutSignature };
}

/**
 * Validate a Lua show report against native state, including the geometry
 * observed when Lua ordered the windows. Its order is never recomputed.
 * @param {Array<[string, number[]]>} windows
 * @param {BadgeRow|null} row
 * @returns {string[]|null}
 */
function validateShow(windows, row) {
  if (!row || !Array.isArray(windows) || windows.length > MAX_BADGES) return null;
  var addresses = [];
  for (var i = 0; i < windows.length; i++) {
    var entry = windows[i], rect = entry && entry[1];
    if (!Array.isArray(entry) || entry.length !== 2 || !Array.isArray(rect) || rect.length !== 4
        || !rect.every(finiteNumber)) return null;
    addresses.push(entry[0]);
  }
  var clean = validateSnapshot(addresses, row);
  if (!clean) return null;
  var offsetX = 0, offsetY = 0;
  for (var j = 0; j < windows.length; j++) {
    var window = row.windows.find(function(item) { return item.address === clean[j]; });
    var rect = windows[j][1];
    if (!window || rect[2] !== window.rect.width || rect[3] !== window.rect.height) return null;
    var dx = rect[0] - window.rect.x, dy = rect[1] - window.rect.y;
    if (j && (dx !== offsetX || dy !== offsetY)) return null;
    offsetX = dx; offsetY = dy;
  }
  return clean;
}

/**
 * Validate snapshot addresses against the current native row.
 * @param {string[]} addresses
 * @param {BadgeRow|null} row
 * @returns {string[]|null}
 */
function validateSnapshot(addresses, row) {
  if (!row || !Array.isArray(addresses) || addresses.length > MAX_BADGES) return null;
  var eligible = (row.windows || []).filter(function(window) {
    return !window.floating && !window.pinned;
  });
  var clean = [];
  for (var i = 0; i < addresses.length; i++) {
    var address = addresses[i];
    if (typeof address !== "string" || !/^0x[0-9a-f]+$/i.test(address)
        || clean.indexOf(address) >= 0
        || !eligible.some(function(window) { return window.address === address; })) return null;
    clean.push(address);
  }
  return clean;
}

/**
 * Canonical native fingerprint of a row, independent of presentation order,
 * direction overrides, and orientation.
 * @param {BadgeRow|null} row
 * @returns {string}
 */
function canonicalSignature(row) {
  if (!row) return "";
  var origins = {};
  (row.windows || []).forEach(function(window) {
    var group = window.pinned ? "pinned" : window.floating ? "floating" : "tiled";
    var origin = origins[group];
    if (!origin) origins[group] = { x: window.rect.x, y: window.rect.y };
    else {
      origin.x = Math.min(origin.x, window.rect.x);
      origin.y = Math.min(origin.y, window.rect.y);
    }
  });
  var windows = (row.windows || []).map(function(window) {
    var group = window.pinned ? "pinned" : window.floating ? "floating" : "tiled";
    var origin = origins[group];
    return [window.address, window.rect.x - origin.x, window.rect.y - origin.y,
      window.rect.width,
      window.rect.height, window.floating, window.pinned, window.groupSize];
  });
  windows.sort(function(a, b) { return a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0; });
  return JSON.stringify([row.id, row.monitor, row.fullscreen, windows]);
}

/** @param {number} timestamp @param {number} now @returns {boolean} */
function isFresh(timestamp, now) {
  return finiteNumber(timestamp) && finiteNumber(now)
    && now >= timestamp && now - timestamp < STALE_MS;
}

/**
 * The sequence orders Lua reports; timestamps order same-sequence local clears
 * against stale reads from FileView.
 * @param {{generation?:string,seq:number,timestamp?:number}|null} value
 * @param {{generation?:string,seq:number,appliedAt:number}} held
 * @returns {boolean}
 */
function isNewer(value, held) {
  if (!value || !finiteNumber(value.seq)) return false;
  if ((value.generation || "legacy") !== (held.generation || "legacy")) return true;
  if (value.seq > held.seq) return true;
  return finiteNumber(value.timestamp) && value.seq === held.seq && value.timestamp > held.appliedAt;
}

/**
 * Validate a fresh shared snapshot, retaining it while the active row is not
 * available yet. Geometry is checked relative to the row, so scrolling alone
 * does not invalidate badges.
 * @param {BadgeSnapshot|null} snapshot
 * @param {BadgeRow|null} row
 * @param {number} now
 * @returns {{pending:boolean,addresses:string[],layoutSignature:string,deadline:number}|null}
 */
function resolveSnapshot(snapshot, row, now) {
  if (!snapshot) return null;
  if (!snapshot.addresses.length) return { pending: false, addresses: [], layoutSignature: "", deadline: 0 };
  if (!isFresh(snapshot.timestamp, now)) return null;
  if (!row) return { pending: true, addresses: [], layoutSignature: "", deadline: snapshot.timestamp + STALE_MS };
  var clean = validateSnapshot(snapshot.addresses, row);
  var signature = canonicalSignature(row);
  if (!clean || snapshot.layoutSignature !== signature) return null;
  return { pending: false, addresses: clean, layoutSignature: signature,
    deadline: snapshot.timestamp + STALE_MS };
}

/** @param {any} candidate @param {any} current @returns {any} */
function retainOnMismatch(candidate, current) {
  return candidate === null ? current : candidate;
}

/**
 * @param {BadgeSnapshot|null} snapshot
 * @param {{generation?:string,seq:number,appliedAt:number}} held
 * @param {BadgeRow|null} row
 * @param {number} now
 * @returns {{pending:boolean,addresses:string[],layoutSignature:string,deadline:number}|null}
 */
function resumeSnapshot(snapshot, held, row, now) {
  if (!snapshot || snapshot.generation !== (held.generation || "legacy")
      || snapshot.seq !== held.seq || snapshot.timestamp !== held.appliedAt) return null;
  return resolveSnapshot(snapshot, row, now);
}
