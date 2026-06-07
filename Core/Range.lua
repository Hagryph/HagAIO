local addonName, ns = ...
local Class = ns.Class

-- Core/Range.lua
-- Range service: "is this enemy within N yards?" and "how many enemies within N
-- yards?", by yardage. The reliable in-combat primitive is C_Item.IsItemInRange
-- with a harm item of the wanted range (item range checks are NOT combat-forbidden,
-- unlike CheckInteractDistance; and unlike IsSpellInRange they work for any range,
-- including self-cast spells' radii). Item->yardage brackets are curated from
-- LibRangeCheck's HarmItems; a targeted spell can be passed as a per-unit fallback.

local Range = Class.new("Range", ns.Service)

-- Harm items by exact yardage (first cached one is used). From LibRangeCheck.
local HARM_ITEMS = {
    [5]  = { 8149 },                          -- Voodoo Charm
    [8]  = { 33278, 34368, 35943, 37932 },    -- Burning Torch / Attuned Crystal Cores / Jeremiah's Tools / Miner's Lantern
    [10] = { 9606 },                          -- Treant Muisek Vessel
    [15] = { 30651 },                         -- Dertrok's First Wand
    [20] = { 1191 },                          -- Bag of Marbles
    [25] = { 13289 },                         -- Egan's Blaster
    [30] = { 835 },                           -- Large Rope Net
}

function Range:OnInitialize()
    self:_p().resolved = {}   -- yards -> resolved itemID
end

local function cached(itemID)
    return C_Item and C_Item.GetItemInfo and C_Item.GetItemInfo(itemID) ~= nil
end

-- A usable (cached) harm item for `yards`, or nil. Requests uncached candidates so
-- a later call resolves; the result is memoised once found.
function Range:_ItemFor(yards)
    local p = self:_p()
    if p.resolved[yards] then return p.resolved[yards] end
    local list = HARM_ITEMS[yards]
    if not list then return nil end
    for _, id in ipairs(list) do
        if cached(id) then p.resolved[yards] = id; return id end
        if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
    end
    return nil
end

-- Is `unit` within `yards`? true / false / nil (undeterminable).
function Range:UnitInRange(unit, yards)
    local item = self:_ItemFor(yards)
    if item and C_Item and C_Item.IsItemInRange then return C_Item.IsItemInRange(item, unit) end
    return nil
end

-- Iterate attackable, alive enemy nameplate units as fn(unit).
function Range:EachEnemy(fn)
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
    for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
        local u = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
        if u and UnitCanAttack("player", u) and not UnitIsDead(u) then fn(u) end
    end
end

-- Count attackable enemies within `yards`. `fallbackSpellID` (a TARGETED harm spell)
-- covers units the item can't resolve (nil).
function Range:CountEnemies(yards, fallbackSpellID)
    local item = self:_ItemFor(yards)
    local itemFn = C_Item and C_Item.IsItemInRange
    local spellFn = C_Spell and C_Spell.IsSpellInRange
    local n = 0
    self:EachEnemy(function(u)
        local r = item and itemFn and itemFn(item, u)
        if r == nil and fallbackSpellID and spellFn then r = spellFn(fallbackSpellID, u) == true end
        if r == true then n = n + 1 end
    end)
    return n
end

ns.ServiceManager:Register(Range:New("Range"))
