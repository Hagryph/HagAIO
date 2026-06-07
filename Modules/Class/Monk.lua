local addonName, ns = ...

-- Modules/Class/Monk.lua
-- Monk class file: adds the Monk behaviour as methods on the shared ns.ClassModule
-- and registers the Monk submodule + per-spec submodules with the Submodule framework
-- (Class -> Monk -> spec). Each spec is a table { settings, Load, Unload, OnSettingChanged }
-- driven by a spec condition + PLAYER_SPECIALIZATION_CHANGED, not by manual swapping.

local ClassModule = ns.ClassModule

-- ---- tunables (spell IDs, marker colours, AoE breakpoint) -----------------
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
-- SCK must out-damage Tiger Palm by this factor to be "worth it" -- Tiger Palm also
-- reduces brew cooldowns, so raw damage parity isn't enough to switch off it.
local SCK_BIAS = 1.20

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

-- bar-learning hooks are global; install once per session
local hookInstalled = false
local powerHookInstalled = false

-- ---- spell-data helpers ---------------------------------------------------
-- Grace of the Crane raises all healing taken by a flat % the Expel Harm tooltip
-- doesn't fold in -- read that % from its own description (defaults 4%). 1.0 when
-- not talented.
-- The string-parsing for these tooltip reads lives in ns.SpellTooltipParser (pure +
-- unit-tested); the WoW-specific bits (fetching the description, talent gating, the
-- secret-value guard) stay here.
local function healingTakenMultiplier()
    if not (IsPlayerSpell and IsPlayerSpell(GRACE_OF_CRANE)) then return 1 end
    local desc = C_Spell and C_Spell.GetSpellDescription and C_Spell.GetSpellDescription(GRACE_OF_CRANE)
    local pct = ns.SpellTooltipParser:Percent(desc) or 4
    return 1 + pct / 100
end

-- Parse "healing for N" out of the spell description (enUS) + the talent bonus.
local function readExpelHarmHeal()
    local desc = C_Spell and C_Spell.GetSpellDescription and C_Spell.GetSpellDescription(EXPEL_HARM)
    local heal = ns.SpellTooltipParser:Heal(desc)
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
    local n = ns.SpellTooltipParser:HealsYouFor(desc)
    if not n then return 0 end
    return math.floor(n * healingTakenMultiplier() + 0.5)
end

-- The (current-stat) hit damage parsed from a spell's tooltip description: the
-- number in "... dealing N <school> damage ...". Locale-dependent (enUS phrasing);
-- nil if it can't be read, so callers fall back to a sensible default. Used to
-- compute the Tiger Palm vs Spinning Crane Kick breakpoint live from your gear.
local function spellHitDamage(spellID)
    local desc = C_Spell and C_Spell.GetSpellDescription and C_Spell.GetSpellDescription(spellID)
    local v = ns.SpellTooltipParser:Damage(desc)
    if not v or v <= 0 or (issecretvalue and issecretvalue(v)) then return nil end
    return v
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
        { type = "color", key = "expelColor", label = "Ready colour", default = EXPEL_READY_COLOR, dependsOn = "expelHarm" },
        { type = "color", key = "expelInactiveColor", label = "On-cooldown colour", default = EXPEL_COOLDOWN_COLOR, dependsOn = "expelHarm" },
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

        -- heal scales with spell power, so re-read it on anything that changes it
        self:On("UNIT_MAXHEALTH",             function(_, u) if u == "player" then self:_SnapshotMaxHP(); self:_ScheduleUpdate() end end, "spec")
        self:On("PLAYER_EQUIPMENT_CHANGED",   function() self:_RefreshHeal() end, "spec")
        self:On("PLAYER_LEVEL_UP",            function() self:_RefreshHeal() end, "spec")
        self:On("SPELLS_CHANGED",             function() self:_RefreshHeal() end, "spec")
        self:On("TRAIT_CONFIG_UPDATED",       function() self:_RefreshHeal() end, "spec")
        self:On("ACTIVE_COMBAT_CONFIG_CHANGED", function() self:_RefreshHeal() end, "spec")
        self:On("UNIT_AURA",                  function(_, u) if u == "player" then self:_RefreshHeal() end end, "spec")
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
        self:ReleaseScope("spec")   -- drop every spec event sub + the AoE ticker
        p.expelActive = false
        p.onCooldown = false
        if p.expelWatch then ns.Cooldowns:Unwatch(p.expelWatch); p.expelWatch = nil end
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
        { type = "color", key = "expelColor", label = "Ready colour", default = EXPEL_READY_COLOR, dependsOn = "expelHarm" },
        { type = "color", key = "expelInactiveColor", label = "On-cooldown colour", default = EXPEL_COOLDOWN_COLOR, dependsOn = "expelHarm" },
        { type = "header", text = "Tiger Palm" },
        { type = "toggle", key = "tiger", label = "Show missing-energy bar", default = true,
          desc = "A bar showing how much energy you still need to cast Tiger Palm and Keg Smash. It shrinks as you regenerate and disappears once you can afford both." },
        { type = "color", key = "tigerColor", label = "Bar colour", default = { 1, 1, 1 }, dependsOn = "tiger" },
        { type = "header", text = "AoE helper" },
        { type = "toggle", key = "aoeHelper", label = "Grey Tiger Palm / Spinning Crane Kick by target count", default = false,
          desc = "In combat: greys Tiger Palm once Spinning Crane Kick does more damage for the enemies in range (use SCK), or greys Spinning Crane Kick below that (use Tiger Palm). The breakpoint is read from their tooltips and adjusts with your gear." },
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
        self:On("UNIT_MAXPOWER",        function(_, u) if u == "player" then self:_ScheduleTiger() end end, "spec")
        self:On("UNIT_DISPLAYPOWER",    function(_, u) if u == "player" then self:_ScheduleTiger() end end, "spec")
        self:On("TRAIT_CONFIG_UPDATED", function() self:_ScheduleTiger() end, "spec")
        self:On("PLAYER_LEVEL_UP",      function() self:_ScheduleTiger() end, "spec")
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
        Base.Unload(self)  -- releases the "spec" scope: every sub + AoE ticker, incl. tiger's
        p.tigerActive = false
        if p.tigerMarker then p.tigerMarker:Hide() end
    end,
}

-- Register the Monk submodule tree with the framework: Class (module) -> Monk
-- (loads on Monk characters) -> per-spec submodules (each loads on its matching spec,
-- swapped automatically on PLAYER_SPECIALIZATION_CHANGED). Class no longer decides
-- this -- the submodules' conditions + events do. The spec onLoad/onUnload run the
-- spec table's Load/Unload against the Class module instance (the host).
local classMod = ns.ModuleManager:GetModule("Class")
local function isMonk() return (select(2, UnitClass("player"))) == "MONK" end

ns.SubmoduleManager:Register(ns.Submodule:New("Monk", {
    parent = { module = "Class" },        -- Class is the parent (no separate dependency needed)
    condition = isMonk,
}))

local function registerSpec(name, spec, specKey, serviceDeps)
    -- Every spec refreshes its settings page on load, so SettingsWindow is a
    -- dependency of the shared onLoad below (not spec-specific) -- prepend it to
    -- whatever services the spec's own features use.
    local deps = { "SettingsWindow" }
    for _, d in ipairs(serviceDeps) do deps[#deps + 1] = d end
    ns.SubmoduleManager:Register(ns.Submodule:New(name, {
        parent = { submodule = "Monk" },
        host = classMod,
        serviceDeps = deps,          -- SettingsWindow (shared onLoad) + the services THIS spec uses
        condition = function() return classMod:CurrentSpecKey() == specKey end,
        events = { "PLAYER_SPECIALIZATION_CHANGED", "PLAYER_ENTERING_WORLD" },
        onLoad = function(host)
            host:_p().activeSub = spec
            host:_BuildSettings()
            if spec.Load then spec.Load(host) end
            if ns.UI and ns.UI.SettingsWindow then ns.UI.SettingsWindow:InvalidateModule(host:GetName()) end
        end,
        onUnload = function(host)
            if spec.Unload then spec.Unload(host) end
            host:_p().activeSub = nil
        end,
    }))
end
-- Base: Expel Harm marker (event subs, Cooldowns watch, secret-safe paint).
-- ns.SpellTooltipParser is a pure Lib (always available) -- not a service dep.
registerSpec("Monk-Base", Base, "none",
    { "EventBus", "Cooldowns", "Secrets" })
-- Brewmaster: all of Base + the AoE helper (Range counts, ActionBars greying).
registerSpec("Monk-Brewmaster", Brewmaster, 1,
    { "EventBus", "Cooldowns", "Secrets", "Range", "ActionBars" })

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

    -- Bar WIDTH can also come back SECRET in restricted content (like max health),
    -- and geometry can't consume a secret. Snapshot the last non-secret width and
    -- reuse it. Check Secrets:Is BEFORE any comparison so we never compare a secret.
    local liveWidth = bar:GetWidth()
    if liveWidth and not ns.Secrets:Is(liveWidth) and liveWidth > 0 then p.widthSnap = liveWidth end
    local width = p.widthSnap
    if not width or width <= 0 then return hideAll() end

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
    self:On("ACTIONBAR_SLOT_CHANGED", function() self:_ScanAoEButtons() end, "spec")
    self:On("ACTIONBAR_PAGE_CHANGED", function() self:_ScanAoEButtons() end, "spec")
    self:On("UPDATE_BONUS_ACTIONBAR", function() self:_ScanAoEButtons() end, "spec")
    self:On("PLAYER_ENTERING_WORLD",  function() self:_ScanAoEButtons() end, "spec")
    self:_ScanAoEButtons()

    -- breakpoint between Tiger Palm and Spinning Crane Kick, recomputed when gear /
    -- talents / level change the tooltip damage.
    self:_RefreshAoEThreshold()
    self:On("PLAYER_EQUIPMENT_CHANGED", function() self:_RefreshAoEThreshold() end, "spec")
    self:On("TRAIT_CONFIG_UPDATED",     function() self:_RefreshAoEThreshold() end, "spec")
    self:On("SPELLS_CHANGED",           function() self:_RefreshAoEThreshold() end, "spec")
    self:On("PLAYER_LEVEL_UP",          function() self:_RefreshAoEThreshold() end, "spec")

    -- one always-on throttled ticker that self-gates on combat + the toggle
    -- (avoids races starting/stopping it on combat events). Lives in the "spec"
    -- scope, so it's cancelled automatically when the spec unloads.
    self:Every(0.15, function() self:_UpdateAoE() end, nil, "spec")
end

-- The target count at which Spinning Crane Kick is worth pressing over Tiger Palm.
-- SCK hits every enemy, so at N targets it deals sck*N; we require it to beat Tiger
-- Palm by SCK_BIAS (since Tiger Palm also reduces brew cooldowns), i.e. sck*N >
-- tp*SCK_BIAS -> smallest such N = floor(tp*SCK_BIAS / sck) + 1. Read live from the
-- tooltips; falls back to the conventional 3 if either can't be parsed.
function ClassModule:_RefreshAoEThreshold()
    local p = self:_p()
    local tp  = spellHitDamage(TIGER_PALM)
    local sck = spellHitDamage(SPINNING_CRANE_KICK)
    if tp and sck and sck > 0 then
        p.aoeThreshold = math.max(1, math.floor((tp * SCK_BIAS) / sck) + 1)
    else
        p.aoeThreshold = 3
    end
end

function ClassModule:_UnloadAoE()
    -- The 0.15s ticker is in the "spec" scope (released by Base.Unload), so there's
    -- no handle to cancel here; just clear the greying and mark inactive.
    self:_ClearAoEGrey()
    self:_p().aoeActive = false
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
    -- enemies within SCK's 8 yd (Range uses the item check; TP ~5yd is the fallback);
    -- grey TP once that count reaches the live SCK-beats-TP breakpoint.
    local greyTP = ns.Range:CountEnemies(SCK_RADIUS, TIGER_PALM) >= (p.aoeThreshold or 3)
    for _, b in ipairs(p.tpButtons or {})  do ns.ActionBars:SetGrey(b, greyTP) end
    for _, b in ipairs(p.sckButtons or {}) do ns.ActionBars:SetGrey(b, not greyTP) end
end

function ClassModule:_ClearAoEGrey()
    local p = self:_p()
    for _, b in ipairs(p.tpButtons or {})  do ns.ActionBars:SetGrey(b, false) end
    for _, b in ipairs(p.sckButtons or {}) do ns.ActionBars:SetGrey(b, false) end
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
-- shrinks as energy regenerates, vanishing once you can cast both. Drawn ON TOP, but only
-- over the EMPTY part of the bar (current energy -> cost), so it never overlaps the fill and
-- can't muddy its colour. We never read current energy: the bar's left edge is anchored to
-- the energy fill (Blizzard moves it) and its right edge to the fixed cost point, so it
-- tracks energy for free and collapses to nothing once the fill passes the cost.
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

    -- Bar width can be secret in restricted content -- reuse the last non-secret one.
    local liveW = bar:GetWidth()
    if liveW and not ns.Secrets:Is(liveW) and liveW > 0 then p.powerWidthSnap = liveW end
    local barW = p.powerWidthSnap
    if not barW or barW <= 0 then if p.tigerMarker then p.tigerMarker:Hide() end return end
    local costX = (cost / maxE) * barW  -- the cost point, from the bar's left edge
    m:ClearAllPoints()
    -- left edge tracks current energy (the fill's right edge); right edge is the cost point.
    -- once current >= cost the left passes the right -> zero/negative width -> invisible.
    m:SetPoint("TOPLEFT",     efill, "TOPRIGHT",    0, 0)
    m:SetPoint("BOTTOMLEFT",  efill, "BOTTOMRIGHT", 0, 0)
    m:SetPoint("TOPRIGHT",    bar,   "TOPLEFT", costX, 0)
    m:SetPoint("BOTTOMRIGHT", bar,   "BOTTOMLEFT", costX, 0)
    m:Show()
end
