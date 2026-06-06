local addonName, ns = ...

-- Modules/Class/Monk.lua
-- Monk class file: registers the Monk spec submodules into ns.ClassSubmodules.MONK
-- and adds the Monk-specific behaviour as methods on the shared ns.ClassModule.
-- Each specialisation is a submodule { settings, Load, Unload, OnSettingChanged }.

local ClassModule = ns.ClassModule
local SUBMODULES = ns.ClassSubmodules
SUBMODULES.MONK = SUBMODULES.MONK or {}

local EXPEL_HARM = 322101
-- Expel Harm bar colours. Ready = cyan accent (stands out against the green->yellow->red
-- health gradient); on cooldown = white (cool, also off-gradient). Avoid green/yellow/red:
-- the health bar fades through them, so those would camouflage exactly when health is low.
local EXPEL_READY_COLOR    = { 0.29, 0.702, 0.902 }  -- #4ab3e6 cyan accent
local EXPEL_COOLDOWN_COLOR = { 1, 1, 1 }             -- white
local GRACE_OF_CRANE = 388811   -- passive talent: increases healing taken
local GIFT_OF_THE_OX = 124502    -- Brewmaster talent: spheres on damage taken
local SPIRIT_OF_THE_OX = 400629  -- Brewmaster talent: spheres from Blackout Kick
local TIGER_PALM = 100780
local KEG_SMASH  = 121253
local SPINNING_CRANE_KICK = 101546   -- 8-yd PBAoE; efficient at 3+ targets
local SCK_RADIUS = 8                  -- yards; the Range service resolves the checker

-- Orb-count marker. C_Spell.GetSpellCastCount(EXPEL_HARM) is the absorbable Gift-of-the-Ox
-- sphere count -- a SECRET NUMBER in restricted content (M+/raid/PvP), so we can't read,
-- compare, or do arithmetic on it, and ColorCurve:Evaluate REJECTS a secret argument in
-- addon (tainted) code ("Secret values are only allowed during untainted execution"). The
-- health-bar tint dodges this by passing its curve into UnitHealthPercent (Blizzard
-- evaluates it untainted); there is no such accessor for a spell cast count.
--
-- The one sanctioned sink that turns the secret count into on-screen geometry from tainted
-- code is StatusBar:SetValue (tagged SecretArguments): we set min/max + width with plain
-- math, then SetValue(secretCount) and the ENGINE computes the fill extent untainted. So we
-- overlay a StatusBar that starts at the CURRENT HEALTH edge and fills to the total Expel
-- Harm heal (baseHeal + count*orbHeal) -- the heal-to point including orbs, or just the
-- base heal at 0 orbs. It tracks the orbs IN and OUT of combat. 5 = Gift of the Ox cap.
local ORB_MAX_COUNT = 5

-- bar-learning hooks + debug command are global; install once per session
local hookInstalled = false
local powerHookInstalled = false
local castCountCmdDone = false

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

-- Per-sphere heal of a Healing Sphere (Expel Harm absorbs them). Only when a sphere
-- talent is learned (Gift of the Ox / Spirit of the Ox -- both Brewmaster). Parse
-- "heals you for N" from whichever is learned; 0 otherwise. Apply the same healing-taken
-- bonus the tooltip leaves out (Grace of the Crane). Used out of combat to MOVE the
-- marker by (count x per-sphere heal); in combat the count is secret so the line can't
-- move and only the colour ladder conveys it.
local function orbHealAmount()
    if not IsPlayerSpell then return 0 end
    local id = (IsPlayerSpell(GIFT_OF_THE_OX) and GIFT_OF_THE_OX)
        or (IsPlayerSpell(SPIRIT_OF_THE_OX) and SPIRIT_OF_THE_OX)
    if not id then return 0 end
    local desc = C_Spell and C_Spell.GetSpellDescription and C_Spell.GetSpellDescription(id)
    local n = desc and desc:match("heals you for%s*([%d,]+)")
    if not n then return 0 end
    return math.floor((tonumber((n:gsub(",", ""))) or 0) * healingTakenMultiplier() + 0.5)
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
        { type = "color", key = "expelColor", label = "Ready colour", default = EXPEL_READY_COLOR },
        { type = "color", key = "expelInactiveColor", label = "On-cooldown colour", default = EXPEL_COOLDOWN_COLOR },
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
        -- one-time debug command: watch C_Spell.GetSpellCastCount (Expel Harm orbs)
        if not castCountCmdDone and ns.SlashCommand then
            castCountCmdDone = true
            ns.SlashCommand:Register("scc", function() self:_ToggleCastCountDebug() end,
                "toggle a per-second log of Expel Harm's GetSpellCastCount (orb count)")
        end

        -- heal scales with spell power, so re-read it on anything that changes it
        self:_Sub("UNIT_MAXHEALTH",             function(_, u) if u == "player" then self:_SnapshotMaxHP(); self:_ScheduleUpdate() end end)
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
        if p.sccTicker then p.sccTicker:Cancel(); p.sccTicker = nil end
        if p.marker then p.marker:Hide() end
        self:_HideOrbFill()
    end,
}

-- Brewmaster: extends Base with a Tiger Palm/Keg Smash energy marker + AoE helper.
local Brewmaster = {
    settings = {
        { type = "header", text = "Expel Harm" },
        { type = "toggle", key = "expelHarm", label = "Show heal bar", default = true,
          desc = "A bar that fills from your current health to where Expel Harm would heal you, including Gift of the Ox orbs." },
        { type = "color", key = "expelColor", label = "Ready colour", default = EXPEL_READY_COLOR },
        { type = "color", key = "expelInactiveColor", label = "On-cooldown colour", default = EXPEL_COOLDOWN_COLOR },
        { type = "header", text = "Tiger Palm" },
        { type = "toggle", key = "tiger", label = "Show missing-energy bar", default = true,
          desc = "A bar showing how much energy you still need to cast Tiger Palm and Keg Smash. It shrinks as you regenerate and disappears once you can afford both." },
        { type = "color", key = "tigerColor", label = "Bar colour", default = { 1, 1, 1 } },
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

        -- The sphere count changes with no event of its own (orbs spawn/get absorbed as
        -- you move), so poll to keep the orb-count ladder colour live: fast (0.1s) in
        -- combat where it actually changes, lazy (0.5s) out of combat. Self-reschedules
        -- (NewTicker can't vary its rate); a generation token retires a stale loop on a
        -- re-Load so two never run at once. Self-gates on the talent; _ScheduleUpdate
        -- debounces to one repaint per frame.
        p.orbPollGen = (p.orbPollGen or 0) + 1
        local gen = p.orbPollGen
        local function poll()
            local pp = self:_p()
            if pp.orbPollGen ~= gen then return end   -- superseded / unloaded
            if pp.orbTalented then self:_ScheduleUpdate() end
            C_Timer.After(InCombatLockdown() and 0.1 or 0.5, poll)
        end
        poll()
    end,
    Unload = function(self)
        self:_UnloadAoE()
        local p = self:_p()
        p.orbPollGen = (p.orbPollGen or 0) + 1   -- retire the poll loop
        Base.Unload(self)  -- _UnloadSubs() removes every sub, incl. tiger's
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

-- Cache UnitHealthMax while it is readable (non-secret). In restricted content the
-- live value is secret and geometry can't consume it, so the marker offset is laid out
-- from this last-known plain number instead. maxHP only moves on stamina/aura swaps,
-- which fire UNIT_MAXHEALTH (out of combat / pre-pull) and re-snapshot here.
function ClassModule:_SnapshotMaxHP()
    local p = self:_p()
    local mh = UnitHealthMax("player")
    if mh and mh > 0 and not (issecretvalue and issecretvalue(mh)) then
        p.maxHPSnap = mh
    end
end

-- Re-read the (stat-dependent) base Expel Harm heal + whether a sphere-generating
-- talent is learned (gates the orb-count colour ladder; Brewmaster only).
function ClassModule:_RefreshHeal()
    local p = self:_p()
    p.baseHeal = readExpelHarmHeal()
    p.orbHeal = orbHealAmount()
    p.orbTalented = IsPlayerSpell and (IsPlayerSpell(GIFT_OF_THE_OX) or IsPlayerSpell(SPIRIT_OF_THE_OX)) or false
    self:_SnapshotMaxHP()
    if not p.baseHeal then
        -- description may not be loaded yet; retry shortly
        C_Timer.After(1, function()
            if p.expelActive and not p.baseHeal then
                p.baseHeal = readExpelHarmHeal()
                self:_ScheduleUpdate()
            end
        end)
    end
    self:_ScheduleUpdate()
end

-- The ready/on-cooldown colour the marker draws in this frame.
function ClassModule:_ExpelColor()
    return self:_p().onCooldown and (self:GetSetting("expelInactiveColor") or EXPEL_COOLDOWN_COLOR)
        or (self:GetSetting("expelColor") or EXPEL_READY_COLOR)
end

-- Shared host frame over the bar (clips children so a line never spills past the end).
function ClassModule:_EnsureHost(bar)
    local p = self:_p()
    if not p.host then
        local h = CreateFrame("Frame", nil, bar)
        h:SetAllPoints(bar)
        if h.SetClipsChildren then h:SetClipsChildren(true) end
        p.host = h
    end
    return p.host
end

-- The marker line texture (created lazily over the bar's clipping host).
function ClassModule:_EnsureMarker()
    local p = self:_p()
    if not p.marker then
        local m = p.host:CreateTexture(nil, "OVERLAY", nil, 7)
        m:SetWidth(1)  -- thin line
        p.marker = m
    end
    return p.marker
end

-- The orb-fill StatusBar (lazily created over the bar's clipping host). A flat white
-- fill we tint; min/max are set per-draw (they depend on the live base/orb heal).
function ClassModule:_EnsureOrbBar()
    local p = self:_p()
    if not p.orbBar then
        local sb = CreateFrame("StatusBar", nil, p.host)
        sb:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")  -- flat: tints to a clean colour
        local tex = sb:GetStatusBarTexture()
        if tex and tex.SetDesaturated then tex:SetDesaturated(true) end
        p.orbBar = sb
    end
    return p.orbBar
end

-- Drive the heal-amount fill off the (secret) cast count. The bar starts at the CURRENT
-- HEALTH edge and fills to (baseHeal + count*orbHeal) -- the total you'd be healed to,
-- including orbs (or just baseHeal at 0 orbs). Only SetValue takes the secret; the engine
-- computes the fill extent untainted, so it's live in AND out of combat.
--
-- The fill fraction must equal (baseHeal + count*orbHeal)/span where span = the bar width
-- in heal (baseHeal + ORB_MAX_COUNT*orbHeal). StatusBar fraction = (value-min)/(max-min),
-- and value is the secret count we cannot offset/scale ourselves -- so we bake the base
-- heal into min/max instead (plain math): with min = -baseHeal/orbHeal and max =
-- ORB_MAX_COUNT, fraction at value=count is exactly (baseHeal + count*orbHeal)/span. Width
-- is the full span so the fill's right edge lands at the true heal-to point. Returns true.
function ClassModule:_DrawOrbFill(fill, maxHP, width)
    local p = self:_p()
    if not (p.orbTalented and p.orbHeal and p.orbHeal > 0
            and C_Spell and C_Spell.GetSpellCastCount) then
        return false
    end
    local span = (p.baseHeal + ORB_MAX_COUNT * p.orbHeal) / maxHP * width  -- full bar width (px)
    local c = self:_ExpelColor()

    local sb = self:_EnsureOrbBar()
    sb:SetStatusBarColor(c[1], c[2], c[3], 0.55)           -- translucent: predicted-heal band
    sb:SetMinMaxValues(-p.baseHeal / p.orbHeal, ORB_MAX_COUNT)  -- min bakes in the base heal
    sb:ClearAllPoints()
    sb:SetPoint("TOPLEFT",    fill, "TOPRIGHT",    0, 0)    -- start AT current health
    sb:SetPoint("BOTTOMLEFT", fill, "BOTTOMRIGHT", 0, 0)
    sb:SetWidth(span)
    sb:SetValue(C_Spell.GetSpellCastCount(EXPEL_HARM))     -- SECRET value -> engine fills it
    sb:Show()
    return true
end

function ClassModule:_HideOrbFill()
    local p = self:_p()
    if p.orbBar then p.orbBar:Hide() end
end

function ClassModule:_UpdateMarker()
    local p = self:_p()
    local bar = p.bar  -- the real bar captured from the hook
    if not bar then return end

    local function hideAll()
        if p.marker then p.marker:Hide() end
        self:_HideOrbFill()
    end

    if not (self:IsEnabled() and p.expelActive and self:GetSetting("expelHarm")) then
        return hideAll()
    end
    if not p.baseHeal or p.baseHeal <= 0 then return hideAll() end

    local fill = bar.GetStatusBarTexture and bar:GetStatusBarTexture()
    if not fill then return hideAll() end
    self:_EnsureHost(bar)

    -- Effective max health: prefer the live value, fall back to the last non-secret
    -- snapshot in restricted content (where the live one is secret and unusable for
    -- geometry). Without either we can't size any offset.
    local liveMax = UnitHealthMax("player")
    local maxHP = (liveMax and liveMax > 0 and not ns.Secrets:Is(liveMax)) and liveMax or p.maxHPSnap
    if not maxHP or maxHP <= 0 then return hideAll() end
    local width = bar:GetWidth()

    -- Brewmaster with a sphere talent: one orb fill StatusBar with stop ticks at each
    -- sphere count carries the whole marker (stop 0 = base heal). The fill is driven by the
    -- secret count via SetValue, so it tracks the orbs in and out of combat.
    if self:_DrawOrbFill(fill, maxHP, width) then
        if p.marker then p.marker:Hide() end
        return
    end
    self:_HideOrbFill()

    -- Otherwise: a single base-heal line at where Expel Harm alone heals you to. Anchor to
    -- the fill's right edge (current-health end) + the heal width, so it tracks the health
    -- bar automatically. We never read the secret current health — Blizzard moves the fill
    -- texture, the line follows. Reset vertex colour to white (shown = texture x vertex).
    local m = self:_EnsureMarker()
    local c = self:_ExpelColor()
    m:SetColorTexture(c[1], c[2], c[3], 1)
    m:SetVertexColor(1, 1, 1, 1)
    local offset = (p.baseHeal / maxHP) * width
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
    -- prime the 8-yd checker (the Range service caches the item data)
    ns.Range:UnitInRange("player", SCK_RADIUS)
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
    -- enemies within SCK's 8 yd (Range uses the item check; TP ~5yd is the fallback)
    local greyTP = ns.Range:CountEnemies(SCK_RADIUS, TIGER_PALM) >= 3  -- 3+: AoE -> grey TP
    for _, b in ipairs(p.tpButtons or {})  do ns.ActionBars:SetGrey(b, greyTP) end
    for _, b in ipairs(p.sckButtons or {}) do ns.ActionBars:SetGrey(b, not greyTP) end
end

function ClassModule:_ClearAoEGrey()
    local p = self:_p()
    for _, b in ipairs(p.tpButtons or {})  do ns.ActionBars:SetGrey(b, false) end
    for _, b in ipairs(p.sckButtons or {}) do ns.ActionBars:SetGrey(b, false) end
end

-- ---- debug: C_Spell.GetSpellCastCount (Expel Harm orb count) ---------------
-- /hag scc toggles a 1s log of what GetSpellCastCount returns for Expel Harm so we
-- can see how it behaves out in the open vs. in restricted content (M+/raid/PvP),
-- where the orb count is expected to come back as a SECRET value. Each line reports
-- combat state and routes the value through the secret-safe Secrets service rather
-- than touching it directly (a raw tostring/compare on a secret would throw).
function ClassModule:_DumpCastCount()
    local L = ns.Log
    local fn = C_Spell and C_Spell.GetSpellCastCount
    if not fn then L.Print("|cffff4444GetSpellCastCount unavailable|r"); return end

    -- The call itself is safe; what it RETURNS may be a secret. Never tostring/compare
    -- it directly -- ask Secrets first, then only read it when it's plainly a number.
    local raw = fn(EXPEL_HARM)
    local isSecret = ns.Secrets:Is(raw)
    local num = ns.Secrets:Number(raw)         -- nil when secret / non-numeric
    local shown = isSecret and "|cffff8800<secret>|r" or tostring(raw)

    -- Exercise the secret-value sink: paint the (possibly secret) value via Secrets:Text
    -- onto a throwaway FontString -- the one legal way to "use" a secret we can't read.
    local p = self:_p()
    if not p.sccProbe then
        p.sccProbe = UIParent:CreateFontString(nil, "BACKGROUND", "GameFontNormal")
        p.sccProbe:Hide()   -- never shown; just proves the secret-safe call path works
    end
    local painted = ns.Secrets:Text(p.sccProbe, raw)

    L.Print(("scc: combat=%s restricted=%s | raw=%s type=%s secret=%s Number=%s painted=%s"):format(
        tostring(InCombatLockdown()), tostring(ns.Secrets:Restricted()),
        shown, type(raw), tostring(isSecret), tostring(num), tostring(painted)))
end

function ClassModule:_ToggleCastCountDebug()
    local p = self:_p()
    if p.sccTicker then
        p.sccTicker:Cancel(); p.sccTicker = nil
        ns.Log.Print("|cffffff00scc debug off|r")
        return
    end
    ns.Log.Print("|cffffff00scc debug on|r - logging Expel Harm GetSpellCastCount every 1s (/hag scc to stop)")
    self:_DumpCastCount()
    p.sccTicker = C_Timer.NewTicker(1, function() self:_DumpCastCount() end)
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

-- A reverse-filling bar on the energy bar showing the MISSING energy until you can afford
-- Tiger Palm + Keg Smash. It spans from your current energy to the (TP+KS) cost point and
-- shrinks as energy regenerates, vanishing once you can cast both. We never read current
-- energy: the bar's left edge is anchored to the energy fill (Blizzard moves it) and its
-- right edge to the fixed cost point, so when energy passes the cost the left edge crosses
-- the right and the bar collapses to nothing on its own.
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

    local efill = bar.GetStatusBarTexture and bar:GetStatusBarTexture()
    if not efill then if p.tigerMarker then p.tigerMarker:Hide() end return end

    if not p.tigerHost then
        local h = CreateFrame("Frame", nil, bar)
        h:SetAllPoints(bar)
        if h.SetClipsChildren then h:SetClipsChildren(true) end
        p.tigerHost = h
    end
    if not p.tigerMarker then
        p.tigerMarker = p.tigerHost:CreateTexture(nil, "OVERLAY", nil, 7)
    end
    local m = p.tigerMarker
    local c = self:GetSetting("tigerColor") or { 1, 1, 1 }
    m:SetColorTexture(c[1], c[2], c[3], 0.55)  -- translucent band over the deficit

    local costX = (cost / maxE) * bar:GetWidth()  -- the cost point, from the bar's left edge
    m:ClearAllPoints()
    -- left edge tracks current energy (the fill's right edge); right edge is the cost point.
    -- once current >= cost the left passes the right -> zero/negative width -> invisible.
    m:SetPoint("TOPLEFT",     efill, "TOPRIGHT",    0, 0)
    m:SetPoint("BOTTOMLEFT",  efill, "BOTTOMRIGHT", 0, 0)
    m:SetPoint("TOPRIGHT",    bar,   "TOPLEFT", costX, 0)
    m:SetPoint("BOTTOMRIGHT", bar,   "BOTTOMLEFT", costX, 0)
    m:Show()
end
