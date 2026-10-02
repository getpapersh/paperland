/**
 * @typedef {{kind:string, items:string[]}} ReleaseSection
 * @typedef {{version:string, date:string, headline:string, sections:ReleaseSection[]}} ReleaseNote
 */

/** Parse a SemVer 2.0 version; build metadata is ignored for precedence.
 * @param {string} text
 * @returns {{core:number[], pre:string[]}|null}
 */
function parseVersion(text) {
  // Numeric prerelease identifiers have no leading zeros; no identifier is empty (SemVer rules 9-10).
  var pre = "(?:0|[1-9]\\d*|\\d*[A-Za-z-][0-9A-Za-z-]*)";
  var match = new RegExp("^(0|[1-9]\\d*)\\.(0|[1-9]\\d*)\\.(0|[1-9]\\d*)(?:-(" + pre + "(?:\\." + pre
    + ")*))?(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?$").exec(typeof text === "string" ? text.trim() : "");
  if (!match) return null;
  return {core: [Number(match[1]), Number(match[2]), Number(match[3])], pre: match[4] ? match[4].split(".") : []};
}

/** SemVer precedence of two parsed versions: negative, zero or positive.
 * @param {{core:number[], pre:string[]}} a
 * @param {{core:number[], pre:string[]}} b
 * @returns {number}
 */
function compareParsed(a, b) {
  for (var i = 0; i < 3; i++) if (a.core[i] !== b.core[i]) return a.core[i] - b.core[i];
  // A release outranks any of its prereleases.
  if (!a.pre.length || !b.pre.length) return b.pre.length - a.pre.length;
  for (var j = 0; j < Math.min(a.pre.length, b.pre.length); j++) {
    var x = a.pre[j], y = b.pre[j], xn = /^\d+$/.test(x), yn = /^\d+$/.test(y);
    if (x === y) continue;
    if (xn && yn) return Number(x) - Number(y);
    if (xn !== yn) return xn ? -1 : 1;
    return x < y ? -1 : 1;
  }
  return a.pre.length - b.pre.length;
}

/** Validate the bundled manifest text; invalid entries are dropped, invalid JSON yields [].
 * @param {string} text
 * @returns {ReleaseNote[]}
 */
function parseNotes(text) {
  var data;
  try { data = JSON.parse(text); } catch (error) { return []; }
  if (!Array.isArray(data)) return [];
  return data.filter(function(entry) {
    return entry && typeof entry === "object" && parseVersion(entry.version) !== null && Array.isArray(entry.sections)
      && entry.sections.every(function(section) {
        return section && typeof section.kind === "string" && Array.isArray(section.items)
          && section.items.every(function(item) { return typeof item === "string"; });
      });
  }).map(function(entry) {
    return {version: entry.version.trim(), date: typeof entry.date === "string" ? entry.date : "",
      headline: typeof entry.headline === "string" ? entry.headline : "",
      sections: entry.sections.map(function(section) { return {kind: section.kind, items: section.items.slice()}; })};
  });
}

/** Releases no newer than the running version, newest first; [] when the running version is invalid.
 * @param {ReleaseNote[]} notes
 * @param {string} current
 * @returns {ReleaseNote[]}
 */
function history(notes, current) {
  var running = parseVersion(current);
  if (!running) return [];
  return notes.filter(function(note) { return compareParsed(parseVersion(note.version), running) <= 0; })
    .sort(function(a, b) { return compareParsed(parseVersion(b.version), parseVersion(a.version)); });
}

/** Releases to show at startup: newer than lastSeen, no newer than current. An empty or
 * invalid lastSeen is a fresh install and shows nothing; the caller then saves current.
 * @param {ReleaseNote[]} notes
 * @param {string} lastSeen
 * @param {string} current
 * @returns {ReleaseNote[]}
 */
function unseen(notes, lastSeen, current) {
  var seen = parseVersion(lastSeen);
  if (!seen) return [];
  return history(notes, current).filter(function(note) { return compareParsed(parseVersion(note.version), seen) > 0; });
}
