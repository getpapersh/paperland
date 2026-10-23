.pragma library

/**
 * Reads the [General] section of the INI file Qt Settings used to write and the shared writer
 * (shared/settings_ini.py) writes now. The shell only reads; every write goes through the writer.
 * Qt quotes values holding ; , = " \ or edge whitespace and escapes inside the quotes; maps it
 * saved (workspaceDirections) are an opaque @Variant(...) byte string.
 */

var ESCAPES = { "0": "\0", "a": "\x07", "b": "\b", "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v", "\\": "\\", "\"": "\"", "'": "'", "?": "?" };

/** @returns {string} the text of a Qt INI value with its quotes removed and backslash escapes resolved. */
function unescape(raw) {
  var text = raw.length >= 2 && raw[0] === "\"" && raw[raw.length - 1] === "\"" ? raw.slice(1, -1) : raw;
  var out = "";
  for (var i = 0; i < text.length; i++) {
    var c = text[i];
    if (c !== "\\" || i + 1 >= text.length) { out += c; continue; }
    var next = text[++i];
    if (next === "x") {
      var j = i + 1;
      while (j < text.length && j < i + 5 && /[0-9a-fA-F]/.test(text[j])) j++;
      out += String.fromCharCode(parseInt(text.slice(i + 1, j), 16) || 0);
      i = j - 1;
    } else out += next in ESCAPES ? ESCAPES[next] : next;
  }
  return out;
}

/** Decodes a Qt 6 QVariantMap of QStrings; null when the bytes are anything else. */
function decodeStringMap(bytes) {
  var at = 0;
  function u32() {
    if (at + 4 > bytes.length) throw new Error("short");
    var v = bytes.charCodeAt(at) * 16777216 + (bytes.charCodeAt(at + 1) << 16) + (bytes.charCodeAt(at + 2) << 8) + bytes.charCodeAt(at + 3);
    at += 4;
    return v;
  }
  function str() {
    var length = u32();
    if (length % 2 || at + length > bytes.length) throw new Error("bad string");
    var s = "";
    for (var i = 0; i < length; i += 2) s += String.fromCharCode(bytes.charCodeAt(at + i) * 256 + bytes.charCodeAt(at + i + 1));
    at += length;
    return s;
  }
  try {
    if (u32() !== 8) return null;
    var count = u32(), map = {};
    for (var i = 0; i < count; i++) {
      var key = str();
      if (u32() !== 10) return null;
      map[key] = str();
    }
    return at === bytes.length ? map : null;
  } catch (error) { return null; }
}

/**
 * @param {string} text the whole file
 * @returns {Object<string, (string|Object)>} each [General] key's text (entries before any section header count); a decodable @Variant map as an
 *   object. Qt merges repeated entries and the last one wins; a key whose value cannot be read is left out.
 */
function parse(text) {
  var values = {}, general = true; // entries before any header belong to [General], as in Qt
  var lines = String(text || "").split(/\r?\n/);
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    if (line[0] === "[") { general = line.trim() === "[General]"; continue; }
    var eq = line.indexOf("=");
    if (!general || eq < 1) continue;
    var key = line.slice(0, eq).trim(), raw = line.slice(eq + 1).trim();
    if (key[0] === ";" || key[0] === "#") continue;
    if (raw.indexOf("@Variant(") === 0 && raw[raw.length - 1] === ")") {
      var map = decodeStringMap(unescape(raw.slice(9, -1)));
      if (map) values[key] = map; else delete values[key];
    } else values[key] = unescape(raw);
  }
  return values;
}
