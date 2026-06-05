local addonName, ns = ...

-- Core/Theme.lua
-- Static design system ported from the LoL Game Helper desktop app's
-- "dark + blue" language: near-black blue-tinted panels, a single cyan accent
-- (#4ab3e6, descendant of GrepolisMod's #4ad), restrained 1px accent borders,
-- uppercase dim section labels, and win/warn/loss signal colours so results
-- read before words.
--
-- Exposes BOTH representations because WoW needs each in a different place:
--   * `hex`  RRGGBB strings  -> chat colour escape codes  |cffRRGGBB..|r
--   * `rgb`  {r,g,b,a} floats -> textures / backdrops / fontstring colours

local Theme = {}

-- RRGGBB for |c escape sequences.
Theme.hex = {
    accent    = "4ab3e6",
    accentDim = "2f7fb0",
    text      = "e7ecf3",
    textDim   = "8a93a3",
    textFaint = "5b6473",
    win       = "3fb27f",
    warn      = "e0a955",
    loss      = "e0556b",
    neutral   = "8a93a3",
    gold      = "e0b34a",
}

-- {r, g, b, a} in 0..1 (hex values above converted).
Theme.rgb = {
    bg0          = { 0.039, 0.047, 0.063, 1.00 },  -- #0a0c10
    bg1          = { 0.055, 0.067, 0.090, 1.00 },  -- #0e1117
    panel        = { 0.078, 0.090, 0.118, 0.97 },
    panel2       = { 0.110, 0.125, 0.161, 0.98 },
    panelHover   = { 0.141, 0.161, 0.204, 0.98 },
    border       = { 0.290, 0.702, 0.902, 0.16 },  -- accent @ low alpha
    borderStrong = { 0.290, 0.702, 0.902, 0.45 },
    accent       = { 0.290, 0.702, 0.902, 1.00 },  -- #4ab3e6
    accentDim    = { 0.184, 0.498, 0.690, 1.00 },  -- #2f7fb0
    accentSoft   = { 0.290, 0.702, 0.902, 0.12 },  -- active-nav tint
    win          = { 0.247, 0.698, 0.498, 1.00 },  -- #3fb27f
    warn         = { 0.878, 0.663, 0.333, 1.00 },  -- #e0a955
    loss         = { 0.878, 0.333, 0.420, 1.00 },  -- #e0556b
    neutral      = { 0.541, 0.576, 0.639, 1.00 },
    text         = { 0.906, 0.925, 0.953, 1.00 },  -- #e7ecf3
    textDim      = { 0.541, 0.576, 0.639, 1.00 },  -- #8a93a3
    textFaint    = { 0.357, 0.392, 0.451, 1.00 },  -- #5b6473
}

-- Flat 8x8 white texture: tinted to any colour for solid fills + hairline
-- borders (WoW can't cheaply round corners, so panels are crisp rectangles).
Theme.WHITE = "Interface\\Buttons\\WHITE8X8"

-- Wrap text in a colour escape sequence chosen by palette key.
function Theme.Colorize(key, text)
    return "|cff" .. (Theme.hex[key] or Theme.hex.text) .. tostring(text) .. "|r"
end

-- Return r, g, b, a for a palette key (optional alpha override).
function Theme.Unpack(key, alphaOverride)
    local c = Theme.rgb[key] or Theme.rgb.text
    return c[1], c[2], c[3], alphaOverride or c[4] or 1
end

-- Backdrop info for a solid panel with a 1px (default) border.
function Theme.Backdrop(edgeSize)
    return {
        bgFile   = Theme.WHITE,
        edgeFile = Theme.WHITE,
        edgeSize = edgeSize or 1,
        insets   = { left = 0, right = 0, top = 0, bottom = 0 },
    }
end

ns.Theme = Theme
