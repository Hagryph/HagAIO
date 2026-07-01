local addonName, ns = ...

-- Lib/Color.lua
-- ns.Color -- an RGBA colour VALUE TYPE (ns.Type). Immutable; r/g/b/a in 0..1. Built once
-- for the palette (ns.Theme) and usable anywhere a colour is handed to WoW. :Unpack() spreads
-- it into the colour setters (SetVertexColor / SetTextColor / ...).
--   local c = ns.Color:New(0.29, 0.70, 0.90)   -- a defaults to 1
--   fontString:SetTextColor(c:Unpack())
--   local dim = c:WithAlpha(0.5)                -- immutable -> a new Color

local Color = ns.Type.new("Color", { "r", "g", "b", "a" }, { r = 1, g = 1, b = 1, a = 1 })

local floor = math.floor

-- r, g, b, a -- spread straight into a WoW colour setter.
function Color:Unpack() local p = self:_p(); return p.r, p.g, p.b, p.a end

-- A copy with a different alpha (immutable -> a new Color).
function Color:WithAlpha(a) local p = self:_p(); return Color:New(p.r, p.g, p.b, a) end

-- "RRGGBB" (no alpha), for |cff..|r chat escapes.
function Color:Hex()
    local p = self:_p()
    return ("%02x%02x%02x"):format(floor(p.r * 255 + 0.5), floor(p.g * 255 + 0.5), floor(p.b * 255 + 0.5))
end

-- Build from "RRGGBB" (alpha defaults to 1); nil if the string isn't six hex digits.
function Color.FromHex(hex)
    local r, g, b = tostring(hex):match("(%x%x)(%x%x)(%x%x)")
    if not r then return nil end
    return Color:New(tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255, 1)
end

-- True iff x is an ns.Color (a metatable-identity check -- safe on ANY value, including nil,
-- scalars and plain tables, all of which answer false). Lets the settings pipeline tell an
-- ns.Color default/value apart from a raw { r, g, b } triple at its boundaries.
function Color.Is(x) return getmetatable(x) == Color end

-- Direct assignment, NOT LibManager:RegisterValue: Color is pinned BEFORE Core/LibManager.lua
-- in the load order (ns.Theme is built from it), so the manager doesn't exist yet. The
-- NamespaceSlots generator documents it via its Core-slot map instead.
ns.Color = Color
