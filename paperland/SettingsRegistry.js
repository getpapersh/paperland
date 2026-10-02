.pragma library

/**
 * Every preference `paperland config` may read or change, with its saved default.
 * config.py parses the object between the BEGIN/END markers with json.loads, so it
 * must stay strict JSON. `implies` maps a value (as text) to other keys it also sets.
 * @typedef {{type: "bool"|"int"|"choice", default: (boolean|number|string),
 *   min?: number, max?: number, values?: string[],
 *   implies?: Object<string, Object<string, (boolean|number|string)>>}} SettingSpec
 * @type {Object<string, SettingSpec>}
 */
// BEGIN registry
var KEYS = {
  "pinned": { "type": "bool", "default": true, "implies": { "true": { "peek": false }, "false": { "peek": true } } },
  "peek": { "type": "bool", "default": false, "implies": { "true": { "pinned": false } } },
  "peekSeconds": { "type": "int", "default": 3, "min": 1, "max": 60 },
  "minimapOpacityMode": { "type": "choice", "default": "background", "values": ["background", "entire"] },
  "minimapBackgroundOpacity": { "type": "int", "default": 96, "min": 0, "max": 100 },
  "minimapEntireOpacity": { "type": "int", "default": 100, "min": 20, "max": 100 },
  "overviewWindowList": { "type": "bool", "default": true },
  "overviewDensity": { "type": "int", "default": 0, "min": 0, "max": 2 },
  "scratchpadFollow": { "type": "bool", "default": true }
};
// END registry

/** @returns {string} the allowed values of a known key, for error messages. */
function describe(key) {
  var spec = KEYS[key];
  if (spec.type === "bool") return "true or false";
  if (spec.type === "int") return "an integer from " + spec.min + " through " + spec.max;
  return spec.values.join(", ");
}

/**
 * Parses text (or a value QSettings already typed) for a key.
 * @returns {{ok: true, value: (boolean|number|string)} | {ok: false, error: string, detail: string}}
 */
function parse(key, raw) {
  if (!Object.prototype.hasOwnProperty.call(KEYS, key))
    return { ok: false, error: "unknownKey", detail: "Unknown setting: " + key + ". Known settings: " + Object.keys(KEYS).join(", ") };
  var spec = KEYS[key], text = String(raw);
  var value = null;
  if (spec.type === "bool") { if (text === "true" || text === "false") value = text === "true"; }
  else if (spec.type === "int") { if (/^-?[0-9]+$/.test(text) && Number(text) >= spec.min && Number(text) <= spec.max) value = Number(text); }
  else if (spec.values.indexOf(text) >= 0) value = text;
  if (value === null) return { ok: false, error: "invalidValue", detail: key + " must be " + describe(key) + "; got " + JSON.stringify(text) };
  return { ok: true, value: value };
}

/** @returns {Object<string, (boolean|number|string)>} the key's value plus any coupled values. */
function changes(key, value) {
  var result = {};
  result[key] = value;
  var implied = (KEYS[key].implies || {})[String(value)] || {};
  for (var other in implied) result[other] = implied[other];
  return result;
}

/** Validated changes for `config set`. */
function resolve(key, raw) {
  var parsed = parse(key, raw);
  return parsed.ok ? { ok: true, changes: changes(key, parsed.value) } : parsed;
}

/** Validated changes for `config unset`: the registry default and its coupled values. */
function reset(key) {
  return resolve(key, Object.prototype.hasOwnProperty.call(KEYS, key) ? KEYS[key].default : undefined);
}

/** @returns {Object<string, *>} the current value of every registered key from an object holding them. */
function snapshot(source) {
  var result = {};
  for (var key in KEYS) result[key] = source[key];
  return result;
}

/**
 * Reads every key through `get(key, fallback)`, as Settings.value does, keeping invalid
 * saved entries out of the result and reporting them instead. `current` holds the live
 * values that a rejected entry leaves in place, so the resulting pin/Peek pair is checked.
 * @returns {{values: Object<string, *>, errors: Array<{key: string, detail: string}>}}
 */
function read(get, current) {
  var values = {}, errors = [];
  for (var key in KEYS) {
    var parsed = parse(key, get(key, KEYS[key].default));
    if (parsed.ok) values[key] = parsed.value;
    else errors.push({ key: key, detail: parsed.detail });
  }
  // Pin and Peek are exclusive modes; keep the live pair rather than apply both.
  var live = current || {};
  var pinned = "pinned" in values ? values.pinned : live.pinned;
  var peek = "peek" in values ? values.peek : live.peek;
  if (pinned === true && peek === true) {
    delete values.pinned;
    delete values.peek;
    errors.push({ key: "peek", detail: "pinned and peek cannot both be true" });
  }
  return { values: values, errors: errors };
}

/**
 * Assigns values to a QtCore Settings object and writes them through before returning.
 * Settings delays property writes by 500 ms and sync() does not flush them, so without
 * setValue an immediate reload would reread the old file and undo an acknowledged change.
 */
function apply(store, values) {
  for (var key in values) {
    store[key] = values[key];
    store.setValue(key, values[key]);
  }
  store.sync();
}

/** Rereads the file into a Settings object; invalid entries keep the live value. */
function reload(store) {
  store.sync();
  var result = read(function(key, fallback) { return store.value(key, fallback); }, store);
  apply(store, result.values);
  return result;
}
