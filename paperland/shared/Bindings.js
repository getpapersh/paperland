/** @typedef {{modmask?: number, key?: string, keycode?: number, dispatcher?: string, arg?: string, description?: string}} Bind */
/** @typedef {{modmask: number, key: string, dispatcher: string, arg: string, owner: string}} BindEvidence */

var ALT = 8;
var TAB_KEYCODE = 23;
var SWITCHER_PREFIX = "paperland-switcher:";

/** @param {Bind} bind @returns {boolean} */
function hasKeyIdentity(bind) {
  return Number.isInteger(bind.modmask) && ((typeof bind.key === "string" && bind.key !== "")
    || (Number.isInteger(bind.keycode) && bind.keycode > 0));
}

/**
 * Whether the bind names what it dispatches. Hyprland 0.56.2 reports every
 * Lua bind -- hl.dsp.global, hl.dsp.exec_cmd and function callbacks alike --
 * as dispatcher "__lua" with an opaque callback handle in arg, so a Lua bind
 * never carries an attributable dispatch target (bind-fields.md).
 * @param {Bind} bind
 * @returns {boolean}
 */
function hasDispatchDetail(bind) {
  return typeof bind.dispatcher === "string" && bind.dispatcher !== "" && bind.dispatcher !== "__lua"
    && typeof bind.arg === "string";
}

/**
 * Ownership from the dispatch target only; the description never decides it.
 * Only two Paperland binds have an attributable target: the switcher's
 * `paperland-switcher:*` globals and the minimap command setup generates
 * (`LAUNCHER start-hidden && LAUNCHER toggle`). Centering, resize and the
 * strip chord are Lua callbacks with no target, so they are never attributed.
 * @param {Bind} bind
 * @returns {string} "paperland-switcher", "paperland-minimap" or "other"
 */
function owner(bind) {
  if (bind.arg.indexOf(SWITCHER_PREFIX) === 0) return "paperland-switcher";
  if (/(^|\/)paperland'? start-hidden && .*(^|\/)paperland'? toggle$/.test(bind.arg)) return "paperland-minimap";
  return "other";
}

/** @param {Bind} bind @returns {boolean} */
function isAltTab(bind) {
  return bind.modmask === ALT && (String(bind.key).toLowerCase() === "tab" || bind.keycode === TAB_KEYCODE);
}

/**
 * What classifies a bind. Without dispatch detail the owner is unknown and the
 * opaque handle is left out; the description is never shown as evidence.
 * @param {Bind} bind
 * @returns {BindEvidence}
 */
function evidence(bind) {
  var key = bind.key || ("code:" + bind.keycode);
  return hasDispatchDetail(bind)
    ? { modmask: bind.modmask, key: key, dispatcher: bind.dispatcher, arg: bind.arg, owner: owner(bind) }
    : { modmask: bind.modmask, key: key, dispatcher: String(bind.dispatcher || ""), owner: "unknown" };
}

/**
 * Classify a live bind list. Binds missing key identity or dispatch detail
 * are counted, never classified from what remains (their description
 * included), so ownership claims rest only on identified binds. The
 * scratchpad key detection hint (description-based) is reported separately
 * and labelled as inferred.
 * @param {Bind[]} binds
 * @param {{modifiers: number, key: string}|null} scratchpadHint
 * @returns {Object}
 */
function classify(binds, scratchpadHint) {
  var identified = binds.filter(function(bind) { return hasKeyIdentity(bind) && hasDispatchDetail(bind); });
  var unidentified = binds.length - identified.length;
  // Alt+Tab binds with a key identity are listed even when their dispatch is
  // omitted, as owner unknown: the key is taken, by whom is not knowable.
  var altTab = binds.filter(function(bind) { return hasKeyIdentity(bind) && isAltTab(bind); }).map(evidence);
  var owners = altTab.map(function(item) { return item.owner; });
  var switcher = identified.filter(function(bind) { return owner(bind) === "paperland-switcher"; }).length;
  // Any Paperland owner is Paperland's, the switcher first; a Paperland bind
  // other than the switcher on Alt+Tab is never read as another tool's.
  var paperlandOwner = owners.indexOf("paperland-switcher") >= 0 ? "paperland-switcher"
    : owners.find(function(item) { return item.indexOf("paperland-") === 0; });
  var altTabOwner = paperlandOwner ? paperlandOwner
    : owners.indexOf("unknown") >= 0 || (owners.length === 0 && unidentified > 0) ? "unknown"
    : owners.length ? "other" : "unbound";
  // An identified foreign Alt+Tab is bound away even when other binds are
  // unidentified; without one, unidentified binds leave the switcher unknown.
  var switcherState = switcher > 0 ? "reachable"
    : altTabOwner === "other" ? "bound-away"
    : unidentified ? "unknown" : "unbound";
  return {
    incomplete: unidentified > 0,
    unidentified: unidentified,
    altTab: { owner: altTabOwner, binds: altTab },
    // "identified" because, with unidentified binds, zero is not a denial.
    switcher: { state: switcherState, identifiedBinds: switcher },
    identifiedChords: identified.filter(function(bind) { return owner(bind) !== "other"; }).map(evidence),
    scratchpadKey: scratchpadHint ? { inferred: true, basis: "description", modmask: scratchpadHint.modifiers,
      key: scratchpadHint.key } : null
  };
}

/**
 * The diagnostics reply for one finished `hyprctl -j binds` query. Malformed
 * output, a failed query or non-object entries are reported as incomplete
 * with the reason instead of throwing.
 * @param {number} exitCode
 * @param {string} stdout
 * @param {string} stderr
 * @param {function(Bind[]): ({modifiers: number, key: string}|null)} scratchpadHint
 * @returns {string} JSON
 */
function queryResult(exitCode, stdout, stderr, scratchpadHint) {
  try {
    if (exitCode !== 0) throw new Error(stderr.trim() || "hyprctl exited with " + exitCode);
    var reply = JSON.parse(stdout);
    if (!Array.isArray(reply)) throw new Error("the reply is not a bind list");
    var binds = reply.filter(function(bind) { return bind !== null && typeof bind === "object" && !Array.isArray(bind); });
    var report = classify(binds, scratchpadHint(binds));
    if (binds.length !== reply.length) {
      report.incomplete = true;
      report.malformed = reply.length - binds.length;
    }
    return JSON.stringify(report);
  } catch (error) {
    return JSON.stringify({ incomplete: true, reason: "The live bind query failed: " + error.message });
  }
}

/**
 * The diagnostics reply when the bind query has not settled by its deadline:
 * a query that never started (hyprctl missing or not executable) is reported
 * as such rather than as slow.
 * @param {boolean} started
 * @returns {string} JSON
 */
function deadlineResult(started) {
  return JSON.stringify({ incomplete: true, reason: started
    ? "The live bind query did not finish within 4 seconds."
    : "The live bind query could not start hyprctl." });
}
