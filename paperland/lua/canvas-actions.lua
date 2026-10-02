-- Paperland canvas actions. Installer-owned; change with `paperland setup`.
--
-- Everything here runs through Hyprland alone. Unlike native/, which forwards
-- input to the Paperland process, these actions work with the app stopped.
-- Shortcuts arrive as globals set by the generated setup file before dofile.

local centering = _G.paperland_centering_shortcut

if centering then
  hl.unbind(centering)
  hl.bind(centering, function()
    -- 0 centers the focused column and lets the strip run off both screen
    -- edges; 1 scrolls it the minimum distance into view. Hyprland recomputes
    -- the camera offset on the next focus or column change, so the strip does
    -- not move on this keypress -- do not "fix" that by nudging focus here.
    local was_centered = (hl.get_config("scrolling.focus_fit_method") or 0) == 0
    hl.config({ scrolling = { focus_fit_method = was_centered and 1 or 0 } })
    -- hyprctl ships with the running compositor; notify-send needs a daemon.
    hl.exec_cmd(("hyprctl notify -1 1500 0 %q"):format(
      was_centered and "Paperland: columns packed" or "Paperland: columns centered"))
  end, { description = "Paperland: toggle column centering" })
end
