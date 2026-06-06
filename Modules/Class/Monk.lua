local addonName, ns = ...

-- Modules/Class/Monk.lua
-- Monk class file: registers the Monk spec submodules into ns.ClassSubmodules.MONK
-- and adds the Monk-specific behaviour as methods on the shared ns.ClassModule.
-- Each specialisation is a submodule { settings, Load, Unload, OnSettingChanged }.

local ClassModule = ns.ClassModule
local SUBMODULES = ns.ClassSubmodules
SUBMODULES.MONK = SUBMODULES.MONK or {}

local EXPEL_HARM = 322101
local GRACE_OF_CRANE = 388811   -- passive talent: increases healing taken
local TIGER_PALM = 100780
local KEG_SMASH  = 121253
local SPINNING_CRANE_KICK = 101546   -- 8-yd PBAoE; efficient at 3+ targets

-- bar-learning hooks + debug command are global; install once per session
local hookInstalled = false
local powerHookInstalled = false
local aoeCmdDone = false

-- ---- spell-data helpers ---------------------------------------------------
-- Grace of the Crane raises all healing taken by a flat % the Expel Harm tooltip
-- doesn't fold in -- read that % from its own description (defaults 4%). 1.0 when
-- not talented.
local function healingTakenMultiplier()
    if not (IsPlayerSpell and IsPlayerSpell(GRACE_OF_CRANE)) then return 1 end
    local desc = C_Spell and C_Spell.GetSpellDescription and C_Spell.GetSpellDescription(GRACE_OF_CRANE)
    local pct = tonumber(desc and desc:match("by%s*(%d+)%%")) or 4
    return 1 + pct / 100
end

-- Parse "healing for N" out of the spell description (enUS) + the talent bonus.
local function readExpelHarmHeal()
    local desc = C_Spell and C_Spell.GetSpellDescription and C_Spell.GetSpellDescription(EXPEL_HARM)
    if not desc or desc == "" then return nil end
    local n = desc:match("healing for%s*([%d,]+)")
    if not n then return nil end
    local heal = tonumber((n:gsub(",", "")))
    if not heal then return nil end
    return math.floor(heal * healingTakenMultiplier() + 0.5)
end

-- ===========================================================================
-- Submodules
-- ===========================================================================

-- Base: the no-specialisation submodule, providing the Expel Harm marker every
-- Monk has. Other specs extend it.
local Base = {
    settings = {
        { type = "header", text = "Expel Harm" },
        { type = "toggle", key = "expelHarm", label = "Show heal-threshold marker", default = true,
          desc = "A line on your health bar marking where Expel Harm would heal you to full." },
        { type = "color", key = "expelColor", label = "Ready colour", default = { 1, 1, 1 } },
        { type = "color", key = "expelInactiveColor", label = "On-cooldown colour", default = { 1, 0, 0 } },
    },
    OnSettingChanged = function(self)
        self:_ScheduleUpdate()
    end,
    Load = function(self)
        local p = self:_p()

        -- install the player health-bar learning hook once (captures the real bar)
        if not hookInstalled and type(UnitFrameHealthBar_Update) == "function" then
            hooksecurefunc("UnitFrameHealthBar_Update", function(statusbar, unit)
                -- Only the real PlayerFrame bar. Other frames (pet/target-of-target)
                -- transiently carry unit "player" during vehicle/art swaps; touching
                -- them here can flush a pending resize that compares secret health.
                if unit == "player" and statusbar.unitFrame == PlayerFrame then
                    self:_p().bar = statusbar
                    self:_ScheduleUpdate()
                end
            end)
            hookInstalled = true
        end
        -- one-time debug commands
        if not aoeCmdDone and ns.SlashCommand then
            aoeCmdDone = true
            ns.SlashCommand:Register("aoe", function() self:_DumpAoE() end, "debug the AoE greying helper")
            ns.SlashCommand:Register("npdist", function() self:_DumpNpDist() end, "debug enemy nameplate range brackets")
        end
        -- migrate the old cyan marker default to the new white default
        local db = self:GetDB()
        if db and type(db.expelColor) == "table" and db.expelColor[1] == 0.29 then db.expelColor = nil end

        -- heal scales with spell power, so re-read it on anything that changes it
        self:_Sub("UNIT_MAXHEALTH",             function(_, u) if u == "player" then self:_ScheduleUpdate() end end)
        self:_Sub("PLAYER_EQUIPMENT_CHANGED",   function() self:_RefreshHeal() end)
        self:_Sub("PLAYER_LEVEL_UP",            function() self:_RefreshHeal() end)
        self:_Sub("SPELLS_CHANGED",             function() self:_RefreshHeal() end)
        self:_Sub("TRAIT_CONFIG_UPDATED",       function() self:_RefreshHeal() end)
        self:_Sub("ACTIVE_COMBAT_CONFIG_CHANGED", function() self:_RefreshHeal() end)
        self:_Sub("UNIT_AURA",                  function(_, u) if u == "player" then self:_RefreshHeal() end end)
        p.onCooldown = false
        p.expelActive = true
        -- recolour the marker (ready <-> on-cooldown) via the secret-safe Cooldowns
        -- service (cast + non-secret booleans + base-cooldown timer).
        p.expelWatch = ns.Cooldowns:Watch(EXPEL_HARM, function(onCD)
            p.onCooldown = onCD
            self:_ScheduleUpdate()
        end)
        self:_RefreshHeal()
    end,
    Unload = function(self)
        local p = self:_p()
        self:_UnloadSubs()
        p.expelActive = false
        p.onCooldown = false
        if p.expelWatch then ns.Cooldowns:Unwatch(p.expelWatch); p.expelWatch = nil end
        if p.marker then p.marker:Hide() end
    end,
}

-- Brewmaster: extends Base with a Tiger Palm/Keg Smash energy marker + AoE helper.
local Brewmaster = {
    settings = {
        { type = "header", text = "Expel Harm" },
        { type = "toggle", key = "expelHarm", label = "Show heal-threshold marker", default = true,
          desc = "A line on your health bar marking where Expel Harm would heal you to full." },
        { type = "color", key = "expelColor", label = "Ready colour", default = { 1, 1, 1 } },
        { type = "color", key = "expelInactiveColor", label = "On-cooldown colour", default = { 1, 0, 0 } },
        { type = "header", text = "Tiger Palm" },
        { type = "toggle", key = "tiger", label = "Show energy marker", default = true,
          desc = "A line on the energy bar at the energy needed for Tiger Palm + Keg Smash." },
        { type = "color", key = "tigerColor", label = "Marker colour", default = { 1, 1, 1 } },
        { type = "header", text = "AoE helper" },
        { type = "toggle", key = "aoeHelper", label = "Grey Tiger Palm / Spinning Crane Kick by target count", default = false,
          desc = "In combat: greys Tiger Palm at 3+ enemies in Spinning Crane Kick range (use SCK), or greys Spinning Crane Kick below 3 (use Tiger Palm)." },
    },
    OnSettingChanged = function(self)
        self:_ScheduleUpdate()
        self:_ScheduleTiger()
        self:_UpdateAoE()  -- self-gates; clears the greying immediately if toggled off
    end,
    Load = function(self)
        Base.Load(self)
        local p = self:_p()

        -- install the player power(energy) bar learning hook once
        if not powerHookInstalled and type(UnitFrameManaBar_Update) == "function" then
            hooksecurefunc("UnitFrameManaBar_Update", function(statusbar, unit)
                if unit == "player" and statusbar.unitFrame == PlayerFrame then
                    self:_p().powerBar = statusbar
                    if not self:_p().tigerMarker then self:_ScheduleTiger() end
                end
            end)
            powerHookInstalled = true
        end

        p.tigerActive = true
        self:_Sub("UNIT_MAXPOWER",        function(_, u) if u == "player" then self:_ScheduleTiger() end end)
        self:_Sub("UNIT_DISPLAYPOWER",    function(_, u) if u == "player" then self:_ScheduleTiger() end end)
        self:_Sub("TRAIT_CONFIG_UPDATED", function() self:_ScheduleTiger() end)
        self:_Sub("PLAYER_LEVEL_UP",      function() self:_ScheduleTiger() end)
        self:_ScheduleTiger()
        self:_LoadAoE()
    end,
    Unload = function(self)
        self:_UnloadAoE()
        Base.Unload(self)  -- _UnloadSubs() removes every sub, incl. tiger's
        local p = self:_p()
        p.tigerActive = false
        if p.tigerMarker then p.tigerMarker:Hide() end
    end,
}

SUBMODULES.MONK["none"] = Base        -- no specialisation
SUBMODULES.MONK[1]      = Brewmaster  -- + Tiger Palm energy marker + AoE helper

-- ===========================================================================
-- Monk behaviour (methods on the shared ClassModule)
-- ===========================================================================

-- ---- Expel Harm marker ----------------------------------------------------
-- Defer + debounce marker updates to the next frame. Reading bar:GetWidth()
-- synchronously inside Blizzard's frame update can flush a pending resize that
-- compares secret max-health on our tainted path; next-frame avoids that.
function ClassModule:_ScheduleUpdate()
    local p = self:_p()
    if p.updateScheduled then return end
    p.updateScheduled = true
    C_Timer.After(0, function()
        p.updateScheduled = false
        self:_UpdateMarker()
    end)
end

function ClassModule:_RefreshHeal()
    local p = self:_p()
    p.heal = readExpelHarmHeal()
    if not p.heal then
        -- description may not be loaded yet; retry shortly
        C_Timer.After(1, function()
            if p.expelActive and not p.heal then
                p.heal = readExpelHarmHeal()
                self:_ScheduleUpdate()
            end
        end)
    end
    self:_ScheduleUpdate()
end

function ClassModule:_UpdateMarker()
    local p = self:_p()
    local bar = p.bar  -- the real bar captured from the hook
    if not bar then return end

    if not (self:IsEnabled() and p.expelActive and self:GetSetting("expelHarm")) then
        if p.marker then p.marker:Hide() end
        return
    end

    local maxHP = UnitHealthMax("player")
    if (issecretvalue and issecretvalue(maxHP)) or not maxHP or maxHP <= 0 then
        if p.marker then p.marker:Hide() end
        return  -- can't size the offset from a secret/zero max
    end
    local heal = p.heal
    if not heal or heal <= 0 then if p.marker then p.marker:Hide() end return end

    local fill = bar.GetStatusBarTexture and bar:GetStatusBarTexture()
    if not fill then if p.marker then p.marker:Hide() end return end

    -- Clipping host over the bar so the line never spills past the bar end
    -- (e.g. near full health, where current + heal exceeds max).
    if not p.host then
        local h = CreateFrame("Frame", nil, bar)
        h:SetAllPoints(bar)
        if h.SetClipsChildren then h:SetClipsChildren(true) end
        p.host = h
    end
    if not p.marker then
        local m = p.host:CreateTexture(nil, "OVERLAY", nil, 7)
        m:SetWidth(1.5)  -- thin line
        p.marker = m
    end
    local m = p.marker

    -- ready -> the normal colour; on cooldown -> the inactive (default red) colour
    local c = p.onCooldown and (self:GetSetting("expelInactiveColor") or { 1, 0, 0 })
        or (self:GetSetting("expelColor") or { 1, 1, 1 })
    m:SetColorTexture(c[1], c[2], c[3], 1)

    -- Anchor to the fill's right edge (current-health end) + the heal width, so
    -- the line tracks the health bar automatically. We never read the secret
    -- current health — Blizzard moves the fill texture, the line follows.
    local offset = (heal / maxHP) * bar:GetWidth()
    m:ClearAllPoints()
    m:SetPoint("TOP", fill, "TOPRIGHT", offset, 0)
    m:SetPoint("BOTTOM", fill, "BOTTOMRIGHT", offset, 0)
    m:Show()
end

-- ---- AoE helper: grey Tiger Palm vs Spinning Crane Kick by target count -------
-- NOTE on range: Spinning Crane Kick is self-cast (no target) so
-- C_Spell.IsSpellInRange(SCK) is nil -- it can't be range-checked. There is also
-- no 8-yd targetable Monk harm spell and CheckInteractDistance is forbidden in
-- combat, so we probe with Tiger Palm (targeted melee, ~5 yd) via the Nameplates
-- service. That's a touch tighter than SCK's 8 yd, which only ever under-counts.
function ClassModule:_LoadAoE()
    local p = self:_p()
    p.aoeActive = true
    -- re-find the spell buttons whenever the bars change
    self:_Sub("ACTIONBAR_SLOT_CHANGED", function() self:_ScanAoEButtons() end)
    self:_Sub("ACTIONBAR_PAGE_CHANGED", function() self:_ScanAoEButtons() end)
    self:_Sub("UPDATE_BONUS_ACTIONBAR", function() self:_ScanAoEButtons() end)
    self:_Sub("PLAYER_ENTERING_WORLD",  function() self:_ScanAoEButtons() end)
    self:_ScanAoEButtons()
    -- one always-on throttled ticker that self-gates on combat + the toggle
    -- (avoids races starting/stopping it on combat events).
    if not p.aoeTicker then
        p.aoeTicker = C_Timer.NewTicker(0.15, function() self:_UpdateAoE() end)
    end
end

function ClassModule:_UnloadAoE()
    local p = self:_p()
    if p.aoeTicker then p.aoeTicker:Cancel(); p.aoeTicker = nil end
    self:_ClearAoEGrey()
    p.aoeActive = false
end

function ClassModule:_ScanAoEButtons()
    local p = self:_p()
    p.tpButtons  = ns.ActionBars:FindSpell(TIGER_PALM)
    p.sckButtons = ns.ActionBars:FindSpell(SPINNING_CRANE_KICK)
end

function ClassModule:_UpdateAoE()
    local p = self:_p()
    if not (p.aoeActive and self:IsEnabled() and self:GetSetting("aoeHelper") and InCombatLockdown()) then
        return self:_ClearAoEGrey()
    end
    local greyTP = ns.Nameplates:CountInSpellRange(TIGER_PALM) >= 3  -- 3+: AoE -> grey TP
    for _, b in ipairs(p.tpButtons or {})  do ns.ActionBars:SetGrey(b, greyTP) end
    for _, b in ipairs(p.sckButtons or {}) do ns.ActionBars:SetGrey(b, not greyTP) end
end

function ClassModule:_ClearAoEGrey()
    local p = self:_p()
    for _, b in ipairs(p.tpButtons or {})  do ns.ActionBars:SetGrey(b, false) end
    for _, b in ipairs(p.sckButtons or {}) do ns.ActionBars:SetGrey(b, false) end
end

function ClassModule:_DumpAoE()
    local L, p = ns.Log, self:_p()
    L.Print("=== AoE helper ===")
    L.Print(("enabled=%s setting=%s active=%s combat=%s ticker=%s"):format(
        tostring(self:IsEnabled()), tostring(self:GetSetting("aoeHelper")),
        tostring(p.aoeActive), tostring(InCombatLockdown()), tostring(p.aoeTicker ~= nil)))

    local tp  = ns.ActionBars and ns.ActionBars:FindSpell(TIGER_PALM) or {}
    local sck = ns.ActionBars and ns.ActionBars:FindSpell(SPINNING_CRANE_KICK) or {}
    L.Print(("Tiger Palm buttons=%d   SCK buttons=%d"):format(#tp, #sck))

    local rangeFn = C_Spell and C_Spell.IsSpellInRange
    L.Print(("IsSpellInRange present=%s"):format(tostring(rangeFn ~= nil)))
    if rangeFn then
        L.Print(("  SCK vs target = %s   TP vs target = %s"):format(
            tostring(rangeFn(SPINNING_CRANE_KICK, "target")), tostring(rangeFn(TIGER_PALM, "target"))))
    end

    local plates = C_NamePlate and C_NamePlate.GetNamePlates and C_NamePlate.GetNamePlates() or {}
    local total, attackable, inRange = #plates, 0, 0
    for _, plate in ipairs(plates) do
        local u = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
        if u and UnitCanAttack("player", u) and not UnitIsDead(u) then
            attackable = attackable + 1
            local r = rangeFn and rangeFn(TIGER_PALM, u)   -- probe with TP (SCK is nil)
            if r == true then inRange = inRange + 1 end
            L.Print(("  %s tp-range=%s"):format(tostring(UnitName(u)), tostring(r)))
        end
    end
    L.Print(("nameplates total=%d attackable=%d inRange(TP)=%d"):format(total, attackable, inRange))
end

-- Per enemy nameplate, show IsSpellInRange for several known-range spells to
-- bracket the distance (there is no native exact-yardage API for enemies).
function ClassModule:_DumpNpDist()
    local L = ns.Log
    local probes = {
        { TIGER_PALM, "TP~5" },
        { SPINNING_CRANE_KICK, "SCK(self)" },
        { 115078, "Paralysis~20" },
        { 115546, "Provoke~30" },
        { 117952, "CrackleJade~40" },
    }
    L.Print("=== nameplate range brackets ===")
    local rangeFn = C_Spell and C_Spell.IsSpellInRange
    if not rangeFn then L.Print("  IsSpellInRange unavailable"); return end
    ns.Nameplates:EachEnemy(function(u)
        local parts = {}
        for _, pr in ipairs(probes) do
            parts[#parts + 1] = pr[2] .. "=" .. tostring(rangeFn(pr[1], u))
        end
        L.Print(("  %s: %s"):format(tostring(UnitName(u)), table.concat(parts, "  ")))
    end)
end

-- ---- Tiger Palm energy marker (Brewmaster) --------------------------------
-- Combined energy cost of Tiger Palm + Keg Smash (non-secret spell data).
function ClassModule:_TigerCost()
    local energy = Enum and Enum.PowerType and Enum.PowerType.Energy
    local total = 0
    for _, id in ipairs({ TIGER_PALM, KEG_SMASH }) do
        local costs = C_Spell and C_Spell.GetSpellPowerCost and C_Spell.GetSpellPowerCost(id)
        if costs then
            for _, c in ipairs(costs) do
                if c.type == energy and c.cost and not (issecretvalue and issecretvalue(c.cost)) then
                    total = total + c.cost
                end
            end
        end
    end
    return total
end

function ClassModule:_ScheduleTiger()
    local p = self:_p()
    if p.tigerScheduled then return end
    p.tigerScheduled = true
    C_Timer.After(0, function() p.tigerScheduled = false; self:_UpdateTiger() end)
end

-- A fixed line on the energy bar at (Tiger Palm + Keg Smash) energy. When your
-- energy fill reaches it you can afford both.
function ClassModule:_UpdateTiger()
    local p = self:_p()
    local bar = p.powerBar
    if not bar then return end

    if not (self:IsEnabled() and p.tigerActive and self:GetSetting("tiger")) then
        if p.tigerMarker then p.tigerMarker:Hide() end
        return
    end

    local energy = Enum and Enum.PowerType and Enum.PowerType.Energy
    local maxE = UnitPowerMax("player", energy)
    if (issecretvalue and issecretvalue(maxE)) or not maxE or maxE <= 0 then
        if p.tigerMarker then p.tigerMarker:Hide() end
        return
    end
    local cost = self:_TigerCost()
    if cost <= 0 then if p.tigerMarker then p.tigerMarker:Hide() end return end

    if not p.tigerHost then
        local h = CreateFrame("Frame", nil, bar)
        h:SetAllPoints(bar)
        if h.SetClipsChildren then h:SetClipsChildren(true) end
        p.tigerHost = h
    end
    if not p.tigerMarker then
        local m = p.tigerHost:CreateTexture(nil, "OVERLAY", nil, 7)
        m:SetWidth(1.5)
        p.tigerMarker = m
    end
    local m = p.tigerMarker
    local c = self:GetSetting("tigerColor") or { 1, 1, 1 }
    m:SetColorTexture(c[1], c[2], c[3], 1)

    local frac = cost / maxE
    local x = frac * bar:GetWidth()
    m:ClearAllPoints()
    m:SetPoint("TOP", bar, "TOPLEFT", x, 0)
    m:SetPoint("BOTTOM", bar, "BOTTOMLEFT", x, 0)
    m:Show()
end
