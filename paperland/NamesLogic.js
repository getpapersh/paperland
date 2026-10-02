.pragma library

var HEADER = "-- Paperland workspace names (owned; generated)";

function isSupportedName(value) {
  if (typeof value !== "string") return false;
  for (var i = 0; i < value.length; i++) {
    var code = value.charCodeAt(i);
    if (code === 0 || code === 10 || code === 13 || code < 32 || (code >= 127 && code <= 159)) return false;
  }
  return true;
}

function normalizeName(value) {
  if (!isSupportedName(value)) return { ok: false, message: "Name contains an unsupported control character." };
  var name = value.trim();
  if (name.length > 0 && !isSupportedName(name)) return { ok: false, message: "Name contains an unsupported control character." };
  return { ok: true, name: name };
}

function positiveId(value) {
  var text = String(value);
  if (!/^[1-9][0-9]*$/.test(text)) return 0;
  var id = Number(text);
  return Number.isSafeInteger(id) && id > 0 ? id : 0;
}

function luaQuote(value) {
  if (!isSupportedName(value)) return null;
  return '"' + value.replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"';
}

function decodeLuaString(token) {
  if (!/^"(?:[^"\\]|\\["\\])*"$/.test(token + "")) return null;
  var body = token.slice(1, -1);
  var out = "";
  for (var i = 0; i < body.length; i++) {
    if (body[i] !== "\\") out += body[i];
    else {
      i++;
      if (i >= body.length || (body[i] !== "\\" && body[i] !== '"')) return null;
      out += body[i];
    }
  }
  return isSupportedName(out) ? out : null;
}

function parseLine(line) {
  var match = line.match(/^hl\.workspace_rule\(\{ workspace = "([1-9][0-9]*)", default_name = ("(?:[^"\\]|\\["\\])*") \}\)$/);
  if (!match) return null;
  var id = positiveId(match[1]);
  var name = decodeLuaString(match[2]);
  if (!id || name === null || name.trim() !== name || name.length === 0) return null;
  return { id: id, name: name };
}

function parse(text) {
  if (typeof text !== "string") return { ok: false, message: "Owned names file is not text." };
  if (text === "") return { ok: true, entries: {} };
  var lines = text.split("\n");
  if (lines[lines.length - 1] === "") lines.pop();
  if (lines.length === 0 || lines[0] !== HEADER) return { ok: false, message: "Owned names file has an invalid header." };
  var entries = {};
  for (var i = 1; i < lines.length; i++) {
    var row = parseLine(lines[i]);
    if (!row || entries[row.id]) return { ok: false, message: "Owned names file has an invalid or duplicate rule." };
    entries[row.id] = row.name;
  }
  return { ok: true, entries: entries };
}

function cloneEntries(entries) {
  var result = {};
  Object.keys(entries || {}).forEach(function(id) { result[id] = entries[id]; });
  return result;
}

function replaceEntry(entries, id, name) {
  var result = cloneEntries(entries);
  var key = String(positiveId(id));
  if (!positiveId(id)) throw new Error("Invalid workspace ID");
  if (name === "") delete result[key];
  else result[key] = name;
  return result;
}

function format(entries) {
  var ids = Object.keys(entries || {}).map(Number).sort(function(a, b) { return a - b; });
  var lines = [HEADER];
  ids.forEach(function(id) {
    var name = entries[id];
    var encoded = luaQuote(name);
    if (!positiveId(id) || encoded === null || name.trim() !== name || name.length === 0) throw new Error("Invalid owned name entry");
    lines.push('hl.workspace_rule({ workspace = "' + id + '", default_name = ' + encoded + ' })');
  });
  return lines.join("\n") + "\n";
}

function revision(entries, id) {
  var key = String(positiveId(id));
  return entries && Object.prototype.hasOwnProperty.call(entries, key) ? entries[key] : null;
}

function nativeRules(raw) {
  if (!Array.isArray(raw)) return { ok: false, message: "Native workspace rules reply is not an array." };
  return { ok: true, rules: raw };
}

function ruleConflict(rules, entries) {
  var conflicts = [];
  for (var i = 0; i < rules.length; i++) {
    var rule = rules[i] || {};
    if (rule.enabled === false || rule.defaultName === undefined || rule.defaultName === null || rule.defaultName === "") continue;
    var selector = String(rule.workspaceString || "");
    var id = positiveId(selector);
    if (!id || revision(entries, id) !== String(rule.defaultName)) {
      conflicts.push({ selector: selector, defaultName: String(rule.defaultName) });
    }
  }
  return conflicts;
}

function ruleMatches(rules, id, name) {
  var wanted = String(positiveId(id));
  for (var i = 0; i < rules.length; i++) {
    var rule = rules[i] || {};
    if (rule.enabled !== false && String(rule.workspaceString || "") === wanted && String(rule.defaultName || "") === name) return true;
  }
  return false;
}

function allRulesOwn(rules, entries) {
  return ruleConflict(rules, entries).length === 0;
}
