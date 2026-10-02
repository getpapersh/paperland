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
