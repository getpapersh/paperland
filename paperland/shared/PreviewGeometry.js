/** @typedef {{width: number, height: number}} Size */
/** @typedef {{address: string, rect: Size}} Window */

/**
 * Uniform world-to-logical-pixel scale required after the card's label and inset.
 * Known image aspects can differ from current window geometry for cached frames.
 * @param {{windows: Window[]}|null} row
 * @param {number} edge Actual fitted image short edge, in logical pixels.
 * @param {Object<string, number>} aspects Source width divided by height.
 * @returns {number}
 */
function requiredScale(row, edge, aspects) {
  if (!row) return 0;
  return row.windows.reduce(function(scale, window) {
    var r = window.rect;
    var ratio = aspects[window.address] || r.width / r.height;
    return Math.max(scale, (edge * Math.max(1, ratio) + 10) / r.width,
      (edge * Math.max(1, 1 / ratio) + 51) / r.height);
  }, 0);
}

/**
 * @param {number} desired Desired outer extent in logical pixels.
 * @param {number} minimum Nominal outer minimum.
 * @param {number} available Owning monitor space after bar and margins.
 * @returns {number}
 */
function popupExtent(desired, minimum, available) {
  return Math.round(Math.min(Math.max(minimum, desired), available > 0 ? available * 0.8 : minimum));
}

/**
 * Qt applies window DPR to grabToImage's logical target size itself.
 * @param {number} width Item logical width.
 * @param {number} height Item logical height.
 * @param {number} dpr Window device pixel ratio.
 * @param {number} maximum Physical pixel edge limit.
 * @returns {Size}
 */
function captureSize(width, height, dpr, maximum) {
  var scale = Math.min(1, maximum / (Math.max(width, height) * dpr));
  return {width: Math.max(1, Math.floor(width * scale)), height: Math.max(1, Math.floor(height * scale))};
}

/** Fitted image size in logical pixels; overflow preserves the 160-pixel short edge. */
function imageSize(aspect, availableWidth, preferred) {
  var ratio = aspect > 0 ? aspect : 16 / 9;
  var edge = Math.max(160, Math.min(preferred, availableWidth / Math.max(1, ratio)));
  return {width: edge * Math.max(1, ratio), height: edge * Math.max(1, 1 / ratio)};
}

/** @typedef {{x: number, y: number, width: number, height: number}} Rect */

/**
 * The hovered bar pill and its open card in the compositor's global logical
 * space, where `hyprctl -j cursorpos` reports. Bar placement mirrors Widget
 * openPreviewMenu: the window spans from each anchored screen edge inward by
 * its margins, so a top or left bar starts at the margin and a bottom or right
 * bar ends one window size before the far edge.
 * @param {{width: number, height: number, anchors: {left: boolean, top: boolean}, margins: {left: number, top: number, right: number, bottom: number}}} bar
 * @param {{x: number, y: number, width: number, height: number}} screen The bar's screen in global logical coordinates.
 * @param {Rect} pill Anchor item position within the bar window and its size.
 * @param {Rect} card The popup anchor rectangle and size, in bar window coordinates.
 * @returns {Rect[]}
 */
function hoverRects(bar, screen, pill, card) {
  var x = screen.x + (bar.anchors.left ? bar.margins.left : screen.width - bar.width - bar.margins.right);
  var y = screen.y + (bar.anchors.top ? bar.margins.top : screen.height - bar.height - bar.margins.bottom);
  return [
    {x: x + pill.x, y: y + pill.y, width: pill.width, height: pill.height},
    {x: x + card.x, y: y + card.y, width: card.width, height: card.height}];
}

/**
 * Whether the compositor cursor rests inside the hovered pill or its card.
 * All rects share the cursor's global logical space; edges are inclusive so a
 * pointer on the pill's last pixel still counts as hovering it.
 * @param {{x: number, y: number}} cursor From `hyprctl -j cursorpos`.
 * @param {Rect[]} rects The pill and the card, global.
 * @returns {boolean}
 */
function cursorInside(cursor, rects) {
  return rects.some(function(r) {
    return cursor.x >= r.x && cursor.x <= r.x + r.width && cursor.y >= r.y && cursor.y <= r.y + r.height;
  });
}

/** Scale a size down uniformly to fit a bounding box; never scales up.
 * Unlike imageSize, this may go below the 160-pixel edge: a passive popover
 * cannot scroll, so the screen wins.
 * @param {Size} size
 * @param {number} maxWidth
 * @param {number} maxHeight
 * @returns {Size}
 */
function fitWithin(size, maxWidth, maxHeight) {
  var scale = Math.min(1, Math.max(0, maxWidth) / size.width, Math.max(0, maxHeight) / size.height);
  return {width: Math.floor(size.width * scale), height: Math.floor(size.height * scale)};
}
