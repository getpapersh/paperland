function axis(row) {
  if (!row) return { start: 0, extent: 1, viewStart: 0, viewExtent: 1 };
  return row.vertical
    ? { start: row.bounds.y, extent: row.bounds.height, viewStart: row.viewport.y, viewExtent: row.viewport.height }
    : { start: row.bounds.x, extent: row.bounds.width, viewStart: row.viewport.x, viewExtent: row.viewport.width };
}

function thumb(row, length) {
  var a = axis(row);
  var size = Math.min(length, Math.max(28, length * a.viewExtent / a.extent));
  var range = Math.max(0, a.extent - a.viewExtent);
  var travel = Math.max(0, length - size);
  var position = range ? Math.max(0, Math.min(1, (a.viewStart - a.start) / range)) * travel : 0;
  // The minimum thumb size changes its travel; dragging must still reach the
  // entire logical canvas, including very long strips with tiny view fractions.
  return { size: size, position: position, pixelsToCanvas: travel ? range / travel : 0 };
}

function box(row, window, length) {
  var a = axis(row);
  var start = row.vertical ? window.rect.y : window.rect.x;
  var extent = row.vertical ? window.rect.height : window.rect.width;
  return { position: (start - a.start) / a.extent * length, size: Math.max(9, extent / a.extent * length - 2) };
}

function crossBox(row, window, length) {
  var starts = row.windows.map(function(w) { return row.vertical ? w.rect.x : w.rect.y; });
  var ends = row.windows.map(function(w) { return row.vertical ? w.rect.x + w.rect.width : w.rect.y + w.rect.height; });
  var first = Math.min.apply(null, starts);
  var last = Math.max.apply(null, ends);
  var start = row.vertical ? window.rect.x : window.rect.y;
  var end = start + (row.vertical ? window.rect.width : window.rect.height);
  // Keep native column stacks distinct without shrinking the usual single
  // full-height card. Gutters belong only between cross-axis neighbors.
  var leading = start > first ? 1 : 0;
  var trailing = end < last ? 1 : 0;
  return { position: (start - first) / (last - first) * length + leading,
    size: Math.max(1, (end - start) / (last - first) * length - leading - trailing) };
}

/**
 * Height a host gives the strip: its own collapsed height, otherwise a
 * display-scaled rail that can grow for visible Desktop pills, or the fixed
 * landscape panel. Logical pixels.
 */
function stripHeight(collapsed, vertical, minimumHeight, screenHeight) {
  if (collapsed) return minimumHeight;
  if (!vertical) return 104;
  var usualHeight = Math.min(900, Math.max(360, screenHeight * 0.5));
  return Math.min(screenHeight - 24, Math.max(usualHeight, minimumHeight));
}

// Floating chips occupy 22 px hit targets 4 px apart; sizes are logical pixels.
var chipPitch = 26;

/** Width of the landscape Floating group: padding, label and at most five slots. */
function floatGroupWidth(labelWidth, count) {
  var slots = Math.min(5, count);
  return slots ? 12 + labelWidth + 4 + slots * chipPitch - 4 : 0;
}

/**
 * True when the full group fits beside the controls and every workspace pill at
 * its natural width. Floating windows must never take width the pills would
 * have without them, so anything less condenses to the count chip.
 */
function floatGroupFits(header, pills, controls, group) {
  return pills + 8 + group + 6 + controls <= header;
}

/** Slots in a portrait rail's single chip row of the given inner width. */
function railSlots(inner) {
  return Math.max(1, Math.floor((inner - 8) / chipPitch));
}

/** How many of `count` windows get chips in `slots`, and how many the "+N" summary counts. */
function chipSplit(count, slots) {
  return count > slots ? { shown: slots - 1, overflow: count - slots + 1 } : { shown: count, overflow: 0 };
}

/**
 * Placement keeping the floating count list on its display. `list` is its
 * natural { width, height }; `strip` and `tab` are { x, y, width, height }
 * rectangles in display coordinates (the tab reaches above the strip, so its
 * y may be negative); `display` is the host surface { width, height }, or
 * zeros when the strip has no parent yet. Returns { x, y, width, height,
 * above } in display coordinates. The list opens above the tab when it fits
 * there, otherwise below the strip, else on whichever side is roomier; its
 * height caps to that side's room so the rows scroll inside, never below one
 * row in its 8 px of padding (38 px); x and y clamp to keep every edge on
 * the display with 8 px side margins.
 */
function floatListPlacement(list, strip, tab, display) {
  var aboveRoom = Math.max(0, tab.y - 6);
  var belowRoom = display.width > 0 ? Math.max(0, display.height - (strip.y + strip.height) - 6) : list.height;
  var above = list.height <= aboveRoom || aboveRoom >= belowRoom;
  var height = Math.min(list.height, Math.max(above ? aboveRoom : belowRoom, Math.min(list.height, 38)));
  var y = above ? tab.y - height - 6 : strip.y + strip.height + 6;
  y = Math.max(0, Math.min(y, display.height - height));
  var x = Math.max(8, Math.min(strip.x + strip.width - 12 - list.width, display.width - 8 - list.width));
  return { x: x, y: y, width: list.width, height: height, above: above };
}
