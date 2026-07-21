local addonName, ns = ...
local Color = ns.Color

-- UI/Theme.lua
-- Static design system ported from the LoL Game Helper desktop app's
-- "dark + blue" language: near-black blue-tinted panels, a single cyan accent
-- (#4ab3e6, descendant of GrepolisMod's #4ad), restrained 1px accent borders,
-- uppercase dim section labels, and green/amber/red signal colours so results
-- read before words.
--
-- Palette keys are named by ROLE (accent, text*) or by HUE (green, amber, red,
-- grey, gold, purple); the Logger maps its levels onto the hues and feature
-- modules pick a hue for their log tag.
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
    green     = "3fb27f",  -- success / positive
    amber     = "e0a955",  -- warning
    red       = "e0556b",  -- error / negative
    grey      = "8a93a3",  -- muted / neutral
    gold      = "e0b34a",
    purple    = "b483e0",
}

-- ns.Color values (r/g/b/a in 0..1; the hex above converted). Reached via Theme.Unpack(key).
Theme.rgb = {
    bg0          = Color:New(0.039, 0.047, 0.063, 1.00),  -- #0a0c10
    bg1          = Color:New(0.055, 0.067, 0.090, 1.00),  -- #0e1117
    panel        = Color:New(0.078, 0.090, 0.118, 0.97),
    panel2       = Color:New(0.110, 0.125, 0.161, 0.98),
    panelHover   = Color:New(0.141, 0.161, 0.204, 0.98),
    border       = Color:New(0.290, 0.702, 0.902, 0.16),  -- accent @ low alpha
    borderStrong = Color:New(0.290, 0.702, 0.902, 0.45),
    accent       = Color:New(0.290, 0.702, 0.902, 1.00),  -- #4ab3e6
    accentDim    = Color:New(0.184, 0.498, 0.690, 1.00),  -- #2f7fb0
    accentSoft   = Color:New(0.290, 0.702, 0.902, 0.12),  -- active-nav tint
    green        = Color:New(0.247, 0.698, 0.498, 1.00),  -- #3fb27f
    amber        = Color:New(0.878, 0.663, 0.333, 1.00),  -- #e0a955
    red          = Color:New(0.878, 0.333, 0.420, 1.00),  -- #e0556b
    grey         = Color:New(0.541, 0.576, 0.639, 1.00),  -- #8a93a3
    text         = Color:New(0.906, 0.925, 0.953, 1.00),  -- #e7ecf3
    textDim      = Color:New(0.541, 0.576, 0.639, 1.00),  -- #8a93a3
    textFaint    = Color:New(0.357, 0.392, 0.451, 1.00),  -- #5b6473
    purple       = Color:New(0.706, 0.514, 0.878, 1.00),  -- #b483e0

    -- Surface roles used by the modern application shell. The original names above remain the
    -- low-level palette; these roles make hierarchy intentional instead of letting every caller
    -- choose an arbitrary shade. WoW has no CSS blur/radius, so elevation comes from restrained
    -- shadows, highlights and borders composed by the widget layer.
    surface      = Color:New(0.078, 0.090, 0.118, 0.98),
    surfaceRaised= Color:New(0.094, 0.108, 0.141, 0.99),
    control      = Color:New(0.110, 0.125, 0.161, 0.98),
    controlHover = Color:New(0.141, 0.161, 0.204, 0.98),
    shadow       = Color:New(0.000, 0.000, 0.000, 0.36),
    highlight    = Color:New(0.290, 0.702, 0.902, 0.09),
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
    local r, g, b, a = (Theme.rgb[key] or Theme.rgb.text):Unpack()
    return r, g, b, alphaOverride or a
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
