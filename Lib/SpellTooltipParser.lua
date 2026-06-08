local addonName, ns = ...
local Class = ns.Class

-- Lib/SpellTooltipParser.lua
-- Pure parsers for the numbers embedded in a spell's description text. NO WoW API:
-- callers fetch the description (C_Spell.GetSpellDescription) and pass the string in,
-- so the regex/number extraction is unit-testable in isolation. Locale-dependent
-- (enUS phrasing); every parser returns nil when the pattern isn't found.

local SpellTooltipParser = Class.new("SpellTooltipParser", ns.Lib)

-- "12,345" -> 12345 (strips thousands commas); nil for nil/no-match input.
local function num(s) return s and tonumber((s:gsub(",", ""))) or nil end

-- "... healing for N ..." -> N, or nil.
function SpellTooltipParser:Heal(desc)
    if type(desc) ~= "string" then return nil end
    return num(desc:match("healing for%s*([%d,]+)"))
end

-- "... heals you for N ..." -> N, or nil (e.g. a Healing Sphere's per-orb heal).
function SpellTooltipParser:HealsYouFor(desc)
    if type(desc) ~= "string" then return nil end
    return num(desc:match("heals you for%s*([%d,]+)"))
end

-- "... by N% ..." -> N (the integer percent), or nil.
function SpellTooltipParser:Percent(desc)
    if type(desc) ~= "string" then return nil end
    return num(desc:match("by%s*(%d+)%%"))
end

-- "... up to N% ..." -> N (the integer percent), or nil. Separate from :Percent because
-- "increased by up to 100%" has "up to" between "by" and the number (e.g. Strength of
-- Spirit's "Expel Harm's healing is increased by up to N%, based on your missing health").
function SpellTooltipParser:UpToPercent(desc)
    if type(desc) ~= "string" then return nil end
    return num(desc:match("up to%s*(%d+)%%"))
end

-- Hit damage from "... dealing N ..." / "N <school> damage" / "N damage" -> N, or nil.
function SpellTooltipParser:Damage(desc)
    if type(desc) ~= "string" then return nil end
    local n = desc:match("dealing%s+([%d,]+)")
        or desc:match("([%d,]+)%s+%a+%s+damage")
        or desc:match("([%d,]+)%s+damage")
    return num(n)
end

ns.LibManager:Register(SpellTooltipParser:New("SpellTooltipParser"))
