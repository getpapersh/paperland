// Windows the compositor has closed, remembered so a late refresh reply cannot
// bring one back. Quickshell's Hyprland model adds a window from every
// `j/clients` reply but removes one only on its `closewindow` event, so a reply
// requested before a close and applied after it recreates the closed window as
// a ghost that nothing removes. Paperland refreshes often, so it hides closed
// windows from its own view until the same address opens a new window.

/**
 * Normalizes the first field of a native event payload to a window address.
 * `closewindow` carries the bare hexadecimal address; `openwindow` carries
 * `ADDRESS,WORKSPACE,CLASS,TITLE` and the title may hold commas.
 * @param {unknown} data
 * @returns {string|null} `0x` plus lowercase hex, or null when malformed.
 */
function addressOf(data) {
  if (typeof data !== "string") return null;
  var first = data.split(",")[0];
  return /^[0-9a-f]+$/i.test(first) ? "0x" + first.toLowerCase() : null;
}

/**
 * Applies a native event to the closed set. Returns the same object when the
 * event changes nothing, so a QML binding only updates on real changes.
 * @param {Object<string, number>} closed Address -> Date.now() when it closed.
 * @param {string} name Native event name.
 * @param {unknown} data Native event payload.
 * @param {number} now Date.now()
 * @returns {Object<string, number>}
 */
function note(closed, name, data, now) {
  if (name !== "closewindow" && name !== "openwindow") return closed;
  var address = addressOf(data);
  if (!address) return closed;
  if (name === "closewindow") {
    if (closed[address] !== undefined) return closed;
    var added = Object.assign({}, closed);
    added[address] = now;
    return added;
  }
  if (closed[address] === undefined) return closed;
  var reopened = Object.assign({}, closed);
  delete reopened[address];
  return reopened;
}

/**
 * The clients that are not recorded as closed.
 * @param {Array<{address?: string}>} clients Native client records.
 * @param {Object<string, number>} closed
 * @returns {Array<object>} The same array when nothing is closed.
 */
function live(clients, closed) {
  if (!Object.keys(closed).length) return clients;
  return clients.filter(function(client) {
    return !client || typeof client.address !== "string" || closed[client.address.toLowerCase()] === undefined;
  });
}

/**
 * Forgets a closed address once the model no longer holds it and graceMs has
 * passed: there is nothing left to hide, and a window reusing the address
 * clears the record through its own `openwindow`. A record for an address the
 * model still holds (a ghost) is kept for as long as the ghost lasts.
 * @param {Object<string, number>} closed
 * @param {string[]} present Addresses the model still holds, `0x` + lowercase.
 * @param {number} now Date.now()
 * @param {number} graceMs
 * @returns {Object<string, number>} The same object when nothing is forgotten.
 */
function retain(closed, present, now, graceMs) {
  var held = {};
  present.forEach(function(address) { held[address] = true; });
  var next = null;
  Object.keys(closed).forEach(function(address) {
    if (held[address] || now - closed[address] < graceMs) return;
    if (!next) next = Object.assign({}, closed);
    delete next[address];
  });
  return next || closed;
}
