local addonName, ns = ...
local Class = ns.Class

-- Core/Nameplates.lua
-- Service over the visible nameplates: iterate the attackable, alive enemy units
-- and count how many are in range of a spell. Centralises the nameplate plumbing
-- so features (e.g. the Monk AoE helper) don't each re-walk C_NamePlate.
--
-- NOTE on range: there is NO reliable native way to count enemies at an exact
-- yardage in combat. IsSpellInRange returns nil for self-cast/no-target spells
-- (e.g. Spinning Crane Kick), CheckInteractDistance is forbidden in combat, and
-- UnitInRange only works on party/raid. So callers pass a TARGETED harm spell of
-- similar range as the probe (e.g. Tiger Palm ~5 yd for SCK's 8 yd).

local Nameplates = Class.new("Nameplates")

function Nameplates:Initialize() end

-- Call fn(unit) for each attackable, alive enemy nameplate unit.
function Nameplates:EachEnemy(fn)
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
    for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
        local u = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
        if u and UnitCanAttack("player", u) and not UnitIsDead(u) then
            fn(u)
        end
    end
end

-- Number of enemy nameplates in range of `spellID` (a targeted probe spell;
-- C_Spell.IsSpellInRange must return a boolean for it).
function Nameplates:CountInSpellRange(spellID)
    if not (C_Spell and C_Spell.IsSpellInRange) then return 0 end
    local n = 0
    self:EachEnemy(function(u)
        if C_Spell.IsSpellInRange(spellID, u) == true then n = n + 1 end
    end)
    return n
end

-- Number of enemy nameplates in range of a harm ITEM (C_Item.IsItemInRange -- the
-- ONLY way to range-check a fixed yardage in combat; works for items whose data is
-- cached, no ownership needed). Falls back to `fallbackSpellID` per unit if the
-- item gives no range data (nil).
function Nameplates:CountInItemRange(itemID, fallbackSpellID)
    local itemFn = C_Item and C_Item.IsItemInRange
    local spellFn = C_Spell and C_Spell.IsSpellInRange
    local n = 0
    self:EachEnemy(function(u)
        local r = itemFn and itemFn(itemID, u)
        if r == nil and fallbackSpellID and spellFn then
            r = spellFn(fallbackSpellID, u) == true
        end
        if r == true then n = n + 1 end
    end)
    return n
end

ns.Nameplates = Nameplates
