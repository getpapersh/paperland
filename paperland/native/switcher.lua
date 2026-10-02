-- This adapter belongs to the standalone host; the bar shares only rendering.
hl.bind("ALT + Tab", hl.dsp.global("paperland-switcher:next"), { repeating = true, description = "Paperland window switcher" })
hl.bind("ALT + SHIFT + Tab", hl.dsp.global("paperland-switcher:previous"), { repeating = true, description = "Paperland previous window" })
hl.bind("ALT + grave", hl.dsp.global("paperland-switcher:previous"), { repeating = true, description = "Paperland previous window" })
-- Physical XKB Alt only. Preserve key-up delivery before the popup gains focus.
hl.on("input.keyboard.key", function(code, timestamp, state)
  if (code == 64 or code == 108) and (state == 0 or state == 1) then
    hl.dispatch(hl.dsp.global("paperland-switcher:" .. code .. "-" .. state))
  end
end)
