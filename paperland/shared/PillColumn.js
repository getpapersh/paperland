/**
 * Geometry for the Omarchy bar's workspace pill column. Heights are logical pixels.
 * @typedef {{region: string, screen: number, edge: number, left: number, right: number, center: number}} Budget
 */

/**
 * What the host's vertical bar holds around one module slot, in logical pixels, with
 * every instance of the widget's own module left out so widgets never count each
 * other. The host (plugins/bar/Bar.qml) declares the centre section as a flat list
 * hidden when a centre anchor module exists, then a list before the anchor, the
 * anchor slot and a list after it, so those are told apart by their order.
 * @typedef {{where: string, above: number, below: number}} Place where is none, flat, before, after or anchor
 * @typedef {{left: number, right: number, anchored: boolean, anchor: number, before: number,
 *   after: number, flat: number, place: Place}} Surroundings
 */

/**
 * @param {Object|null} bar The host's bar item.
 * @param {Object|null} ownSlot The widget's module slot.
 * @param {string} skipModule
 * @returns {Surroundings}
 */
function surroundings(bar, ownSlot, skipModule) {
  var lists = [], anchorSlot = null;
  function visit(node) {
    if (!node) return;
    if ("region" in node && node.region === "center") {
      if ("item" in node) lists.push(node);
      else if ("moduleName" in node) anchorSlot = node;
      return;
    }
    var kids = node.children || [];
    for (var i = 0; i < kids.length; i++) visit(kids[i]);
  }
  visit(bar);
  function members(list) {
    var out = [], column = list && list.item ? list.item.children || [] : [];
    for (var i = 0; i < column.length; i++) if ("moduleName" in column[i]) out.push(column[i]);
    return out;
  }
  function others(slots) {
    var sum = 0;
    for (var i = 0; i < slots.length; i++) if (slots[i].moduleName !== skipModule) sum += slots[i].implicitHeight;
    return sum;
  }
  var anchored = !!anchorSlot && anchorSlot.visible !== false;
  var found = { where: "none", above: 0, below: 0 };
  var named = anchored ? [["before", lists[1]], ["after", lists[2]]] : [["flat", lists[0]]];
  for (var k = 0; k < named.length; k++) {
    var slots = members(named[k][1]), at = slots.indexOf(ownSlot);
    if (at < 0) continue;
    found = { where: named[k][0], above: others(slots.slice(0, at)), below: others(slots.slice(at + 1)) };
  }
  if (anchored && anchorSlot === ownSlot) found = { where: "anchor", above: 0, below: 0 };
  return {
    left: regionHeight(bar, "left", skipModule), right: regionHeight(bar, "right", skipModule), anchored: anchored,
    anchor: anchored && anchorSlot !== ownSlot ? others([anchorSlot]) : 0,
    before: anchored ? others(members(lists[1])) : 0, after: anchored ? others(members(lists[2])) : 0,
    flat: anchored ? 0 : others(members(lists[0])), place: found };
}

/**
 * The most height the widget may report in a vertical bar. The left list sits at
 * the top and the right list at the bottom, each edge pixels in. A flat centre list
 * is centred; with an anchor, the anchor is centred with the before list stacked
 * above it and the after list below. Left and right modules stop at the centre
 * block, or at each other when there is none; a centre module stops at whatever
 * bounds its own list, which grows away from the anchor or from the middle.
 * @param {string} region left, right or center
 * @param {number} screen Bar length.
 * @param {number} edge Margin at each end.
 * @param {Surroundings} around Heights of the other modules, as surroundings returns.
 * @returns {number}
 */
function heightCap(region, screen, edge, around) {
  var mid = screen / 2, anchor = around.anchor, place = around.place;
  var top, bottom, present;
  if (around.anchored) {
    top = mid - anchor / 2 - around.before; bottom = mid + anchor / 2 + around.after;
    present = anchor + around.before + around.after > 0;
  } else {
    top = mid - around.flat / 2; bottom = mid + around.flat / 2; present = around.flat > 0;
  }
  var cap;
  if (region === "left") cap = (present ? top : screen - edge - around.right) - edge - around.left;
  else if (region === "right") cap = screen - edge - (present ? bottom : edge + around.left) - around.right;
  else if (place.where === "before")
    cap = (mid - anchor / 2 - place.below) - (edge + around.left + place.above);
  else if (place.where === "after")
    cap = (screen - edge - around.right) - (mid + anchor / 2 + place.above) - place.below;
  else if (place.where === "anchor")
    cap = 2 * Math.min(mid - edge - around.left - around.before, mid - edge - around.right - around.after);
  else cap = screen - 2 * Math.max(around.left, around.right) - 2 * edge - around.flat;
  return Math.max(0, cap);
}

/**
 * Height of the scrolling pill viewport: everything when it fits, otherwise a whole
 * number of pills, at least one. The host routes clicks by geometry and ignores the
 * clip, so a half-visible pill would take clicks meant for its neighbours.
 * @param {number} natural Height of all pills.
 * @param {number} room Height left after the fixed buttons.
 * @param {number} pill Height of one pill.
 * @returns {number}
 */
function viewport(natural, room, pill) {
  if (natural <= room) return natural;
  return Math.max(pill, Math.floor(Math.max(0, room) / pill) * pill);
}

/**
 * Whether an item lies wholly inside the viewport along the scroll axis.
 * @param {number} start Item position in content coordinates.
 * @param {number} size Item extent.
 * @param {number} scroll Content offset.
 * @param {number} view Viewport extent.
 * @returns {boolean}
 */
function fullyVisible(start, size, scroll, view) {
  var slack = 0.5;
  return start >= scroll - slack && start + size <= scroll + view + slack;
}

/**
 * Whether any part of an item lies inside the viewport along the scroll axis.
 * @param {number} start
 * @param {number} size
 * @param {number} scroll
 * @param {number} view
 * @returns {boolean}
 */
function intersects(start, size, scroll, view) {
  return start < scroll + view && start + size > scroll;
}

/**
 * The content offset that brings an item wholly into view, moving as little as
 * possible and staying within the scrollable range.
 * @param {number} start
 * @param {number} size
 * @param {number} scroll
 * @param {number} view
 * @param {number} content Total content extent.
 * @returns {number}
 */
function revealed(start, size, scroll, view, content) {
  var next = scroll;
  if (start < scroll) next = start;
  else if (start + size > scroll + view) next = start + size - view;
  return Math.max(0, Math.min(Math.max(0, content - view), next));
}

/**
 * The offset one wheel step leaves, one pill per 120 units of wheel delta.
 * @param {number} scroll
 * @param {number} delta Wheel angle delta; positive scrolls toward the start.
 * @param {number} pill
 * @param {number} view
 * @param {number} content
 * @returns {number}
 */
function wheeled(scroll, delta, pill, view, content) {
  return Math.max(0, Math.min(Math.max(0, content - view), scroll - delta / 120 * pill));
}

/**
 * The whole-pill offset nearest an offset.
 * @param {number} scroll
 * @param {number} pill
 * @param {number} view
 * @param {number} content
 * @returns {number}
 */
function settled(scroll, pill, view, content) {
  return Math.max(0, Math.min(Math.max(0, content - view), Math.round(scroll / pill) * pill));
}

/** Corner radius of the vertical-bar pill, a rounded rectangle rather than a capsule. */
var VERTICAL_PILL_RADIUS = 6;

/**
 * The highlighted pill's rectangle inside its bar cell. Horizontal bars keep the
 * capsule inset two pixels each side. Vertical bars fill the slab, so a two-digit
 * identifier with a two-digit count stays off the rounded corners.
 * @param {boolean} vertical
 * @param {number} cellWidth
 * @param {number} cellHeight
 * @returns {{width: number, height: number, radius: number}}
 */
function pillShape(vertical, cellWidth, cellHeight) {
  var height = Math.min(cellHeight - 6, 26);
  if (vertical) return { width: cellWidth, height: height, radius: VERTICAL_PILL_RADIUS };
  return { width: cellWidth - 4, height: height, radius: height / 2 };
}

/**
 * The host's vertical bar item, found from this widget's module slot: the nearest
 * ancestor with a left or right module list (a Loader with a region) among its
 * children. Sibling module slots also carry a region, so the list must have an item
 * property to count.
 * @param {Object} slot The widget's module slot.
 * @returns {Object|null}
 */
function findBar(slot) {
  for (var node = slot; node; node = node.parent) {
    var kids = node.children || [];
    for (var i = 0; i < kids.length; i++)
      if ("item" in kids[i] && "region" in kids[i] && kids[i].region === "left") return node;
  }
  return null;
}

/**
 * Module slots of one bar region, in any nesting: the host keeps the centre list
 * inside a Loader of its own and may split it around an anchor module.
 * @param {Object|null} bar
 * @param {string} region left, right or center
 * @returns {Object[]}
 */
function regionSlots(bar, region) {
  var slots = [];
  function visit(node) {
    if (!node) return;
    if ("region" in node && node.region === region) {
      if (node.item) {
        var column = node.item.children || [];
        for (var i = 0; i < column.length; i++) if ("moduleName" in column[i]) slots.push(column[i]);
      } else if ("moduleName" in node) slots.push(node);
      return;
    }
    var kids = node.children || [];
    for (var j = 0; j < kids.length; j++) visit(kids[j]);
  }
  visit(bar);
  return slots;
}

/**
 * Summed height of a region's slots, leaving out every instance of one module so
 * widgets that read each other's size never form a loop.
 * @param {Object|null} bar
 * @param {string} region
 * @param {string} skipModule
 * @returns {number}
 */
function regionHeight(bar, region, skipModule) {
  var slots = regionSlots(bar, region), height = 0;
  for (var i = 0; i < slots.length; i++)
    if (slots[i].moduleName !== skipModule) height += slots[i].implicitHeight;
  return height;
}
