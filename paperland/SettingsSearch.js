.pragma library

/**
 * Exact search over the Settings index.
 *
 * Entries are plain records; `control` holds the objectName of the focus target
 * and `button` the text of a segmented button. An entry with neither targets its
 * card heading, which is how dynamic Display rows behave when no actual control
 * row exists. rank() reads nothing outside its arguments, so QML and the Bun vm
 * tests exercise the same code.
 */

/**
 * The searchable index of every user-visible Settings card and control.
 * @returns {Array<{label: string, card: string, section: string, synonyms: string, control: string, button: string}>}
 */
function entries() {
  return [
    {label: "Strip mode", card: "Visibility", section: "Minimap", synonyms: "pinned peek manual show hide mode", control: "", button: "Pinned"},
    {label: "Peek lasts", card: "Visibility", section: "Minimap", synonyms: "peek duration seconds delay number", control: "settings-peek-seconds", button: ""},
    {label: "Opacity", card: "Appearance", section: "Minimap", synonyms: "background entire transparency percent slider translucent", control: "settings-opacity-slider", button: ""},
    {label: "Blur background", card: "Appearance", section: "Minimap", synonyms: "blur soften compositor", control: "settings-minimap-blur", button: ""},
    {label: "Follow Scratchpad", card: "Contents", section: "Minimap", synonyms: "scratchpad track contents", control: "settings-scratchpad-follow", button: ""},
    {label: "Show window list", card: "Window list", section: "Overview", synonyms: "docked sidebar visible list", control: "settings-overview-window-list", button: ""},
    {label: "Preview density", card: "Previews", section: "Overview", synonyms: "full icons timeline thumbnails", control: "", button: "Full"},
    {label: "Monitor-aware integration", card: "Monitor-aware integration", section: "Displays", synonyms: "monitor integration aware", control: "settings-monitor-integration", button: ""},
    {label: "Monitor direction", card: "Monitor direction", section: "Displays", synonyms: "monitor display horizontal vertical auto right down", control: "", button: ""},
    {label: "Desktop direction", card: "Desktop direction", section: "Displays", synonyms: "desktop numbered horizontal vertical auto right down", control: "", button: ""},
    {label: "Open minimap", card: "Window navigation", section: "Shortcuts", synonyms: "hotkey keybind key super m shortcut", control: "settings-shortcut", button: ""},
    {label: "Numbered strip focus", card: "Window navigation", section: "Shortcuts", synonyms: "numbered 1 2 3 4 5 6 7 8 9 super ctrl hotkey strip", control: "settings-strip-chord", button: ""},
    {label: "Resize columns", card: "Canvas actions", section: "Shortcuts", synonyms: "resize system incremental presets hotkey columns", control: "settings-resize", button: ""},
    {label: "Center columns", card: "Canvas actions", section: "Shortcuts", synonyms: "center centering super c hotkey columns", control: "settings-centering", button: ""},
    {label: "Start Paperland hidden at login", card: "Startup", section: "Startup & Bar", synonyms: "login autostart startup hidden sign in", control: "settings-startup-hidden", button: ""},
    {label: "Use Paperland in Omarchy Bar", card: "Omarchy Bar", section: "Startup & Bar", synonyms: "bar omarchy integration panel", control: "settings-bar-integration", button: ""},
    {label: "Show Scratchpad pill", card: "Omarchy Bar", section: "Startup & Bar", synonyms: "pill scratchpad bar", control: "settings-bar-scratchpad", button: ""},
    // Kept last: its label contains "bar", so index order must not outrank the
    // Omarchy Bar card for the "bar" query.
    {label: "Bar panel shortcuts", card: "Window navigation", section: "Shortcuts", synonyms: "relocate drop omarchy alt move remove", control: "settings-bar-panels", button: ""},
  ];
}

/**
 * Card headings for one section, in index order, without repeated controls.
 * @param {Array<{card: string, section: string}>} entries
 * @param {string} section
 * @returns {Array<string>}
 */
function cards(entries, section) {
  var headings = [];
  entries.forEach(function(entry) {
    if (entry.section === section && headings.indexOf(entry.card) === -1) headings.push(entry.card);
  });
  return headings;
}

/**
 * Return the entries matching every query word, best first.
 *
 * A word matches as a case-insensitive substring. All query words must match the
 * combined searchable fields (label, card, section, synonyms). Results are tiered
 * so entries whose label alone matches every word rank first, then label+card,
 * then entries that needed section or synonym text; index order breaks ties so
 * ranking stays deterministic regardless of engine sort stability.
 * @param {Array<{label: string, card: string, section: string, synonyms: string, control: string, button: string}>} entries
 * @param {string} query raw user text.
 * @returns {Array<{label: string, card: string, section: string, breadcrumb: string, control: string, button: string}>}
 */
function rank(entries, query) {
  var words = String(query || "").toLowerCase().trim().split(/\s+/).filter(function(word) { return word; });
  if (!words.length) return [];
  var matches = [];
  for (var i = 0; i < entries.length; i++) {
    var entry = entries[i];
    var label = String(entry.label || "").toLowerCase();
    var withCard = label + " " + String(entry.card || "").toLowerCase();
    var everything = withCard + " " + String(entry.section || "").toLowerCase() + " " + String(entry.synonyms || "").toLowerCase();
    var tiers = [[label, 0], [withCard, 1], [everything, 2]];
    for (var tier = 0; tier < tiers.length; tier++) {
      var missing = words.length;
      for (var word = 0; word < words.length; word++) {
        if (tiers[tier][0].indexOf(words[word]) === -1) break;
        missing--;
      }
      if (missing) continue;
      matches.push({entry: entry, tier: tier, order: i});
      break;
    }
  }
  matches.sort(function(a, b) { return a.tier - b.tier || a.order - b.order; });
  return matches.map(function(match) {
    return {label: match.entry.label, card: match.entry.card, section: match.entry.section,
      breadcrumb: match.entry.section + " › " + match.entry.card,
      control: match.entry.control || "", button: match.entry.button || ""};
  });
}
