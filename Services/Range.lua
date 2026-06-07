local addonName, ns = ...
local Class = ns.Class

-- Services/Range.lua
-- Range service: "is this enemy within N yards?" and "how many enemies within N
-- yards?", by yardage. The reliable in-combat primitive is C_Item.IsItemInRange
-- with a harm item of the wanted range (item range checks are NOT combat-forbidden,
-- unlike CheckInteractDistance; and unlike IsSpellInRange they work for any range,
-- including self-cast spells' radii). Item->yardage brackets are curated from
-- LibRangeCheck's HarmItems; a targeted spell can be passed as a per-unit fallback.

local Range = Class.new("Range", ns.Service)

-- Upvalue ipairs (the per-tick combat count's loop). UnitCanAttack/UnitIsDead/C_NamePlate
-- stay global lookups: they're swapped by the test harness, and an upvalue would capture
-- their load-time value -- the real win here is the closure-free loop + early exit anyway.
local ipairs = ipairs

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

-- Iterate attackable, alive enemy nameplate units as fn(unit). Kept for callers that
-- want every enemy; CountEnemies has its own closure-free path below.
function Range:EachEnemy(fn)
    local plates = C_NamePlate and C_NamePlate.GetNamePlates and C_NamePlate.GetNamePlates()
    if not plates then return end
    for _, plate in ipairs(plates) do
        local u = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
        if u and UnitCanAttack("player", u) and not UnitIsDead(u) then fn(u) end
    end
end

-- Count attackable enemies within `yards`. `fallbackSpellID` (a TARGETED harm spell)
-- covers units the item can't resolve (nil). `maxNeeded`, if given, stops counting once
-- reached (callers that only test "count >= threshold" pass the threshold). Walks the
-- nameplates inline -- no per-call closure -- since this runs on a combat ticker.
function Range:CountEnemies(yards, fallbackSpellID, maxNeeded)
    local plates = C_NamePlate and C_NamePlate.GetNamePlates and C_NamePlate.GetNamePlates()
    if not plates then return 0 end
    local item = self:_ItemFor(yards)
    local itemFn = C_Item and C_Item.IsItemInRange
    local spellFn = C_Spell and C_Spell.IsSpellInRange
    local n = 0
    for _, plate in ipairs(plates) do
        local u = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
        if u and UnitCanAttack("player", u) and not UnitIsDead(u) then
            local r = item and itemFn and itemFn(item, u)
            if r == nil and fallbackSpellID and spellFn then r = spellFn(fallbackSpellID, u) == true end
            if r == true then
                n = n + 1
                if maxNeeded and n >= maxNeeded then return n end   -- early exit
            end
        end
    end
    return n
end

ns.ServiceManager:Register(Range:New("Range"))
