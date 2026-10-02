-- Hyprland reports XKB keycodes (evdev + 8): left/right physical Ctrl.
-- Forward only their state; do not retain, log, consume, or forward other keys.
-- Native key events preserve releases after chords and avoid wheel-bind delay.
hl.on("input.keyboard.key", function(code, timestamp, state)
  if (code == 37 or code == 105) and (state == 0 or state == 1) then
    hl.dispatch(hl.dsp.global("paperland-preview:" .. code .. "-" .. state))
  end
end)
