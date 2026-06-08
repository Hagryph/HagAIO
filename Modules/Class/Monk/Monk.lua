local addonName, ns = ...

-- Modules/Class/Monk/Monk.lua
-- Monk module entry point (loads before its per-spec siblings): the shared Monk behaviour
-- as methods on ns.ClassModule, the Monk submodule registration (loads on Monk characters,
-- parent = the Class module), and the ns.Monk surface the spec files build on. The specs
-- themselves are ns.ClassSpec subclasses in Base.lua / Brewmaster.lua, each registered via
-- ns.Monk.registerSpec.

local ClassModule = ns.ClassModule

-- Upvalue the globals the combat tickers hit each tick.
local InCombatLockdown = InCombatLockdown

-- Pure combat arithmetic (breakpoint, orb-fill geometry, energy cost) -- unit-tested.
local MonkMath = ns.MonkMath

-- ---- tunables (spell IDs, marker colours, AoE breakpoint) -----------------
-- Monk spell / talent IDs: a frozen set. The values feed the spell APIs and the ns.Monk
-- surface; the enum keeps them grouped and typo-safe (an unknown member errors loudly).
local Spell = ns.Enum.new("MonkSpell", {
    EXPEL_HARM          = 322101,
    GRACE_OF_CRANE      = 388811,   -- passive talent: increases healing taken
    GIFT_OF_THE_OX      = 124502,   -- Brewmaster talent: spheres on damage taken
    SPIRIT_OF_THE_OX    = 400629,   -- Brewmaster talent: spheres from Blackout Kick
    STRENGTH_OF_SPIRIT  = 387276,   -- talent: Expel Harm heals more the more health you're missing
    TIGER_PALM          = 100780,
    KEG_SMASH           = 121253,
    SPINNING_CRANE_KICK = 101546,   -- 8-yd PBAoE; efficient at 3+ targets
})
local TIGER_COST_SPELLS = { Spell.TIGER_PALM, Spell.KEG_SMASH }  -- hoisted: no per-call table alloc

-- Expel Harm bar colours. Ready = cyan accent (stands out against the green->yellow->red
-- health gradient); on cooldown = white (cool, also off-gradient). Avoid green/yellow/red:
-- the health bar fades through them, so those would camouflage exactly when health is low.
local EXPEL_READY_COLOR    = { 0.29, 0.702, 0.902 }  -- #4ab3e6 cyan accent
local EXPEL_COOLDOWN_COLOR = { 1, 1, 1 }             -- white

local SCK_RADIUS = 8                  -- yards; the Range service resolves the checker
-- SCK must out-damage Tiger Palm by this factor to be "worth it" -- Tiger Palm also
-- reduces brew cooldowns, so raw damage parity isn't enough to switch off it.
local SCK_BIAS = 1.20

-- Orb-count marker. C_Spell.GetSpellCastCount(Spell.EXPEL_HARM) is the absorbable Gift-of-the-Ox
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

-- Strength-of-Spirit LADDER (restricted content only). With Expel Harm's heal scaled by your
-- missing health AND the orb count both secret, no single StatusBar can show it (their product
-- can't be formed). Instead we stack one orb bar per health band: each bakes the SoS multiplier
-- for its band's health % as a PLAIN constant, and a per-band colour curve evaluated by the
-- engine against UnitHealthPercent reveals only the band that matches your live (secret) health.
--
-- The band COUNT is derived from the bonus, one band per 1% of healing increase: a +80% bonus
-- ramps the multiplier 1.00 -> 1.80 over the health axis, so 80 bands = a 1%-per-step heal edge
-- (the ramp is linear, so equal multiplier steps are equal health steps). Bars are created
-- lazily up to ORB_LADDER_MAX_BANDS (caps a 100% bonus). ORB_BAND_ALPHA = the translucent fill
-- alpha. See ClassModule:_LadderBands for the count.
local ORB_LADDER_MAX_BANDS = 100
local ORB_BAND_ALPHA       = 0.55

-- ---- spell-data helpers ---------------------------------------------------
-- Grace of the Crane raises all healing taken by a flat % the Expel Harm tooltip
-- doesn't fold in -- read that % from its own description (defaults 4%). 1.0 when
-- not talented.
-- The string-parsing for these tooltip reads lives in ns.SpellTooltipParser (pure +
-- unit-tested); the WoW-specific bits (fetching the description, talent gating, the
-- secret-value guard) stay here.
local function healingTakenMultiplier()
    if not (IsPlayerSpell and IsPlayerSpell(Spell.GRACE_OF_CRANE)) then return 1 end
    local desc = C_Spell and C_Spell.GetSpellDescription and C_Spell.GetSpellDescription(Spell.GRACE_OF_CRANE)
    local pct = ns.SpellTooltipParser:Percent(desc) or 4
    return 1 + pct / 100
end

-- Parse "healing for N" out of the spell description (enUS) + the talent bonus.
local function readExpelHarmHeal()
    local desc = C_Spell and C_Spell.GetSpellDescription and C_Spell.GetSpellDescription(Spell.EXPEL_HARM)
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
    local id = (IsPlayerSpell(Spell.GIFT_OF_THE_OX) and Spell.GIFT_OF_THE_OX)
        or (IsPlayerSpell(Spell.SPIRIT_OF_THE_OX) and Spell.SPIRIT_OF_THE_OX)
    if not id then return 0 end
    local desc = C_Spell and C_Spell.GetSpellDescription and C_Spell.GetSpellDescription(id)
    local n = ns.SpellTooltipParser:HealsYouFor(desc)
    if not n then return 0 end
    return math.floor(n * healingTakenMultiplier() + 0.5)
end

-- Strength of Spirit (talent): Expel Harm's healing is increased by "up to N%", scaling
-- linearly with your MISSING health (full bonus at 0% HP, none at full) -- SimC's
-- missing_health_percentage_t with highPct=100, lowPct=0, no plateau. Read the N from the
-- talent's own description (it has changed between builds -- 100% then 30% -- so never
-- hardcode it; see [[feedback_check-simcraft]]) and return it as a fraction, or nil when the
-- talent isn't learned. The health-dependent factor itself is applied per-draw (it needs the
-- live health %), not folded into the stored heal like the flat Grace of the Crane bonus.
local function strengthOfSpiritBonus()
    if not (IsPlayerSpell and IsPlayerSpell(Spell.STRENGTH_OF_SPIRIT)) then return nil end
    local desc = C_Spell and C_Spell.GetSpellDescription and C_Spell.GetSpellDescription(Spell.STRENGTH_OF_SPIRIT)
    local pct = ns.SpellTooltipParser:UpToPercent(desc)
    if not pct then return nil end
    return pct / 100
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

-- Register the Monk submodule under the Class module (it loads on Monk characters). The
-- per-spec files (Base.lua, Brewmaster.lua) load after this one and register their spec
-- submodules under it via ns.Monk.registerSpec.
local classMod = ns.ModuleManager:GetModule("Class")
assert(classMod, "Monk submodule requires the Class module (load Modules/Class.lua first)")
local function isMonk() return (select(2, UnitClass("player"))) == "MONK" end

ns.SubmoduleManager:Register(ns.Submodule:New("Monk", {
    parent = { module = "Class" },        -- Class is the parent (no separate dependency needed)
    condition = isMonk,
}))

-- Shared surface for the per-spec files: the few constants their settings/Load need, plus
-- registerSpec. A spec file defines its ns.ClassSpec subclass, sets ns.Monk.<Name> so a
-- deeper spec can extend it, then calls ns.Monk.registerSpec to wire it as a submodule.
ns.Monk = {
    EXPEL_HARM           = Spell.EXPEL_HARM,
    EXPEL_READY_COLOR    = EXPEL_READY_COLOR,
    EXPEL_COOLDOWN_COLOR = EXPEL_COOLDOWN_COLOR,
}

-- Wire a spec class as a submodule under Monk. SpecClass is an ns.ClassSpec subclass; one
-- instance (bound to the Class module host) drives its load/unload. specKey is what
-- CurrentSpecKey() returns for this spec ("none" or a spec index). serviceDeps are the
-- services the spec uses; SettingsWindow (the shared settings refresh) is prepended.
function ns.Monk.registerSpec(name, SpecClass, specKey, serviceDeps)
    local spec = SpecClass:New(classMod)
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
            spec:Load()
            if ns.UI and ns.UI.SettingsWindow then ns.UI.SettingsWindow:InvalidateModule(host:GetName()) end
        end,
        onUnload = function(host)
            spec:Unload()
            host:_p().activeSub = nil
        end,
    }))
end

-- ===========================================================================
-- Monk behaviour (methods on the shared ClassModule)
-- ===========================================================================
-- depcheck-allow: Secrets, Scaling, Range, ActionBars, Scheduler  -- used by the host methods
-- below; the per-spec submodules that actually drive them declare them (Base.lua:
-- Secrets/Scaling; Brewmaster.lua adds Range/ActionBars/Scheduler), which enforces load order.

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

-- Poll the orb count to keep the colour live: fast (0.1s) in combat where the count
-- changes; out of combat keep the slow (0.5s) poll ONLY while orbs remain, then stop --
-- no new orbs spawn out of combat, so spinning forever is pointless. A generation token
-- means a re-Load (or a fresh PLAYER_REGEN_DISABLED) retires any prior loop, so only one
-- ever runs. Restarted on combat start (see the Brewmaster Load subscription).
function ClassModule:_StartOrbPoll()
    local p = self:_p()
    p.orbPollGen = (p.orbPollGen or 0) + 1
    local gen = p.orbPollGen
    local function poll()
        local pp = self:_p()
        if pp.orbPollGen ~= gen then return end        -- superseded / unloaded
        -- The orb count is secret (can't be compared), so each poll assumes it MAY have changed
        -- and flags the geometry for a SetValue refresh. Health ticks don't set this, so they
        -- stay cheap (colour-only). This is the orb-count refresh cadence.
        if pp.orbTalented then pp.orbGeomDirty = true; self:_ScheduleUpdate() end
        if InCombatLockdown() then
            C_Timer.After(0.1, poll)                   -- combat: orbs change fast
            return
        end
        -- Out of combat: the count is readable in the open world; stop once it hits 0.
        -- In restricted content it stays secret (Number -> nil), so keep the slow poll.
        local n = ns.Secrets and ns.Secrets:Number(
            C_Spell and C_Spell.GetSpellCastCount and C_Spell.GetSpellCastCount(Spell.EXPEL_HARM))
        if n == 0 then return end                      -- no orbs left -> stop until next combat
        C_Timer.After(0.5, poll)
    end
    poll()
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
    p.orbTalented = IsPlayerSpell and (IsPlayerSpell(Spell.GIFT_OF_THE_OX) or IsPlayerSpell(Spell.SPIRIT_OF_THE_OX)) or false
    -- Strength of Spirit: a missing-health heal ramp (nil when not talented). Kept as a
    -- Scaling spec and applied per-draw, since the factor depends on the live health %.
    p.sosBonus = strengthOfSpiritBonus()
    p.sosSpec = p.sosBonus and { bonus = p.sosBonus, highPct = 100, lowPct = 0, direction = "missing" } or nil
    p.orbGeomDirty = true   -- heal/orb/SoS changed -> orb-bar geometry must rebuild next draw
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

-- The number of ladder bands for the current bonus: one per 1% of healing increase (round of
-- bonus*100), clamped to [1, ORB_LADDER_MAX_BANDS]. 0 when there's no Strength of Spirit (or no
-- colour-curve API) -> a single plain bar.
function ClassModule:_LadderBands(sos)
    if not sos then return 0 end
    local n = math.floor((self:_p().sosBonus or 0) * 100 + 0.5)
    if n < 1 then n = 1 end
    if n > ORB_LADDER_MAX_BANDS then n = ORB_LADDER_MAX_BANDS end
    return n
end

-- The orb-fill bars: stacked StatusBars (lazily created), all anchored at the current-health
-- edge. With Strength of Spirit each is revealed by its own colour curve so only the band
-- matching your live health is opaque; without it, only bar 0 is used as a plain translucent
-- fill. This is the single orb-display path. Grows the pool to cover `bands` (L.created tracks
-- the highest index built). See ClassModule:_LadderBands for the count.
function ClassModule:_EnsureOrbLadder(bands)
    local p = self:_p()
    local L = p.orbLadder
    if not L then L = { bars = {}, created = -1 }; p.orbLadder = L end
    for i = L.created + 1, bands do
        local sb = CreateFrame("StatusBar", nil, p.host)
        sb:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
        local tex = sb:GetStatusBarTexture()
        if tex and tex.SetDesaturated then tex:SetDesaturated(true) end
        sb:Hide()
        L.bars[i] = sb
    end
    if bands > L.created then L.created = bands end
    return L
end

function ClassModule:_HideOrbLadder()
    local L = self:_p().orbLadder
    if L then for i = 0, L.created do L.bars[i]:Hide() end end
end

-- One triangular alpha curve per band: opaque (ORB_BAND_ALPHA) at this band's health fraction,
-- fading to 0 at the neighbouring bands. UnitHealthPercent evaluates it against the SECRET
-- health %, returning a colour whose alpha we apply -- so the engine, untainted, decides which
-- band shows. Adjacent bands cross-fade, which smooths the heal edge between steps. Rebuilt
-- only when the ready/cooldown colour or the band count changes (RGB + N bake into the points).
function ClassModule:_BuildOrbLadderCurves(c, N)
    local curves = {}
    for i = 0, N do
        local curve = C_CurveUtil.CreateColorCurve()
        curve:SetType(Enum.LuaCurveType.Linear)
        if i > 0 then curve:AddPoint((i - 1) / N, CreateColor(c[1], c[2], c[3], 0)) end
        curve:AddPoint(i / N, CreateColor(c[1], c[2], c[3], ORB_BAND_ALPHA))
        if i < N then curve:AddPoint((i + 1) / N, CreateColor(c[1], c[2], c[3], 0)) end
        curves[i] = curve
    end
    return curves
end

-- THE orb display (one unified path -- no separate "single bar" any more). `bands` is the
-- number of health steps: ORB_LADDER_BANDS with Strength of Spirit (each step bakes its band's
-- multiplier), or 0 without it / when the colour-curve APIs are missing (a single bar, no
-- health scaling). The GEOMETRY (min/max, width, anchor, SetValue) is health-INDEPENDENT, so we
-- only rebuild it when an input that affects it changed -- the orb count (orbGeomDirty, set by
-- the poll since the count is secret and can't be compared), the heal/SoS (orbGeomDirty), or the
-- layout (maxHP/width/band-count, compared here). SetValue redraws the fill texture, so health
-- ticks must skip this and only re-colour (see _RefreshLadderColors). Always returns true.
function ClassModule:_DrawOrbLadder(fill, maxHP, width)
    local p = self:_p()
    local curveOK = C_CurveUtil and C_CurveUtil.CreateColorCurve and UnitHealthPercent
        and CreateColor and Enum and Enum.LuaCurveType
    local sos   = p.sosSpec and curveOK
    local bands = sos and ORB_LADDER_BANDS or 0
    local L = self:_EnsureOrbLadder()

    if p.orbGeomDirty or L.maxHP ~= maxHP or L.width ~= width or L.bands ~= bands then
        local count = C_Spell.GetSpellCastCount(Spell.EXPEL_HARM)   -- SECRET -> SetValue
        for i = 0, ORB_LADDER_BANDS do
            local sb = L.bars[i]
            if i <= bands then
                -- band health % -> SoS multiplier (a plain constant); 1 when no SoS
                local mult = sos and ns.Scaling:Multiplier(p.sosSpec, (i / bands) * 100) or 1
                local minV, maxV, span = MonkMath:OrbFill(p.baseHeal * mult, p.orbHeal * mult, ORB_MAX_COUNT, maxHP, width)
                sb:SetMinMaxValues(minV, maxV)
                sb:ClearAllPoints()
                sb:SetPoint("TOPLEFT",    fill, "TOPRIGHT",    0, 0)   -- start AT current health
                sb:SetPoint("BOTTOMLEFT", fill, "BOTTOMRIGHT", 0, 0)
                sb:SetWidth(span)
                sb:SetValue(count)
            else
                sb:Hide()   -- band not in use (no SoS) -> stays hidden
            end
        end
        L.maxHP, L.width, L.bands = maxHP, width, bands
        p.orbGeomDirty = false
    end

    self:_RefreshLadderColors(bands)
    return true
end

-- Cheap per-refresh pass: the colour/visibility only. With Strength of Spirit, each band's
-- per-band curve (evaluated by the engine against the SECRET health %) yields the alpha that
-- reveals just the matching band -- adjacent bands cross-fade, so the new bar appears as the
-- old fades (no flicker, no Show/Hide churn). Without SoS it's one static translucent bar.
-- Show() lives here (cheap, no redraw) so the ladder re-appears after a hide without a geometry
-- rebuild. No SetValue here -> health ticks never redraw a fill texture.
function ClassModule:_RefreshLadderColors(bands)
    local p = self:_p()
    local L = p.orbLadder
    if not L then return end
    local c = self:_ExpelColor()
    if bands == 0 then
        L.bars[0]:SetStatusBarColor(c[1], c[2], c[3], ORB_BAND_ALPHA)
        L.bars[0]:Show()
        return
    end
    if not L.curves or L.cr ~= c[1] or L.cg ~= c[2] or L.cb ~= c[3] then
        L.curves = self:_BuildOrbLadderCurves(c)
        L.cr, L.cg, L.cb = c[1], c[2], c[3]
    end
    for i = 0, bands do
        local sb = L.bars[i]
        local color = UnitHealthPercent("player", true, L.curves[i])   -- SECRET-driven alpha
        if color then sb:SetStatusBarColor(color:GetRGBA()) end
        sb:Show()
    end
end

-- The Strength-of-Spirit scale bar: a FULL-WIDTH, invisible StatusBar over the whole health
-- bar. We feed it the (secret) current health and bake the missing-health heal ramp into its
-- min/max, so its fill edge lands at the true heal-to point; the marker line hangs off that
-- edge. Only the line is visible (the bar's own texture is transparent).
function ClassModule:_EnsureScaleBar()
    local p = self:_p()
    if not p.scaleBar then
        local sb = CreateFrame("StatusBar", nil, p.host)
        sb:SetAllPoints(p.host)
        sb:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
        sb:SetStatusBarColor(1, 1, 1, 0)   -- invisible: only the marker line it carries shows
        p.scaleBar = sb
    end
    return p.scaleBar
end

function ClassModule:_HideScaleBar()
    local p = self:_p()
    if p.scaleBar then p.scaleBar:Hide() end
end

-- The orb heal fill: one unified path (the ladder), whether or not Strength of Spirit is
-- talented. The min/max bake the base heal into the secret-count fill so the StatusBar fraction
-- at value=count is exactly (baseHeal + count*orbHeal)/span (see MonkMath:OrbFill); SoS, when
-- present, scales each band's heal too. Only SetValue consumes the secret count; the engine
-- computes the fill untainted, live in AND out of combat. Returns false only when no sphere
-- talent / spell API (caller then draws the plain base-heal line instead).
function ClassModule:_DrawOrbFill(fill, maxHP, width)
    local p = self:_p()
    if not (p.orbTalented and p.orbHeal and p.orbHeal > 0
            and C_Spell and C_Spell.GetSpellCastCount) then
        return false
    end
    return self:_DrawOrbLadder(fill, maxHP, width)
end

function ClassModule:_HideOrbFill()
    self:_HideOrbLadder()
end

function ClassModule:_UpdateMarker()
    local p = self:_p()
    local bar = p.bar  -- the real bar captured from the hook
    if not bar then return end

    local function hideAll()
        if p.marker then p.marker:Hide() end
        self:_HideOrbFill()
        self:_HideScaleBar()
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
        self:_HideScaleBar()
        return
    end
    self:_HideOrbFill()

    -- Strength of Spirit (no sphere talent): the heal-to point depends on MISSING health, so
    -- the line can't sit at a fixed offset. Drive a full-width hidden StatusBar with the
    -- (secret-safe) current health and min/max that bake the missing-health ramp, then hang
    -- the marker on its fill edge. Correct in and out of restricted content.
    if p.sosSpec then
        local sb = self:_EnsureScaleBar()
        local minV, maxV = MonkMath:HealLineFill(p.baseHeal, p.sosBonus, maxHP)
        sb:SetMinMaxValues(minV, maxV)
        sb:SetValue(UnitHealth("player"))      -- SECRET value -> engine places the fill edge
        sb:Show()
        self:_DrawMarkerLine(sb:GetStatusBarTexture(), 0)
        return
    end
    self:_HideScaleBar()

    -- Otherwise: a single base-heal line at where Expel Harm alone heals you to. Anchor to
    -- the fill's right edge (current-health end) + the heal width, so it tracks the health
    -- bar automatically. We never read the secret current health — Blizzard moves the fill
    -- texture, the line follows.
    self:_DrawMarkerLine(fill, (p.baseHeal / maxHP) * width)
end

-- Show the marker line at `offset` pixels right of `anchor`'s right edge, in the current
-- ready/on-cooldown colour. Anchoring to a fill texture's right edge lets the line track a
-- live (even secret-driven) fill. Reset vertex colour to white (shown = texture x vertex).
function ClassModule:_DrawMarkerLine(anchor, offset)
    local m = self:_EnsureMarker()
    local c = self:_ExpelColor()
    m:SetColorTexture(c[1], c[2], c[3], 1)
    m:SetVertexColor(1, 1, 1, 1)
    m:ClearAllPoints()
    m:SetPoint("TOP", anchor, "TOPRIGHT", offset, 0)
    m:SetPoint("BOTTOM", anchor, "BOTTOMRIGHT", offset, 0)
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
    -- Re-find the spell buttons whenever the bars change. These events arrive in bursts
    -- (drag one spell -> several SLOT_CHANGED), and a rescan just re-reads the FULL bar
    -- state, so coalescing to at most once a second loses nothing (the trailing call still
    -- captures the final layout). Safe to throttle precisely because it's an idempotent
    -- full-state rescan, not a one-shot signal -- unlike game events in general.
    local scan = self:Throttled(1, function() self:_ScanAoEButtons() end, "spec")
    self:On("ACTIONBAR_SLOT_CHANGED", scan, "spec")
    self:On("ACTIONBAR_PAGE_CHANGED", scan, "spec")
    self:On("UPDATE_BONUS_ACTIONBAR", scan, "spec")
    self:On("PLAYER_ENTERING_WORLD",  scan, "spec")
    self:_ScanAoEButtons()

    -- breakpoint between Tiger Palm and Spinning Crane Kick, recomputed when gear /
    -- talents / level change the tooltip damage.
    self:_RefreshAoEThreshold()
    self:On("PLAYER_EQUIPMENT_CHANGED", function() self:_RefreshAoEThreshold() end, "spec")
    self:On("TRAIT_CONFIG_UPDATED",     function() self:_RefreshAoEThreshold() end, "spec")
    self:On("SPELLS_CHANGED",           function() self:_RefreshAoEThreshold() end, "spec")
    self:On("PLAYER_LEVEL_UP",          function() self:_RefreshAoEThreshold() end, "spec")

    -- Run the per-tick AoE check ONLY while it can do something: in combat AND with the
    -- helper enabled (default off). Start the 0.1s ticker on combat start, stop it on combat
    -- end / toggle-off / unload -- rather than spinning out of combat for a default-off
    -- feature. The REGEN subs live in the "spec" scope (auto-released on unload).
    self:On("PLAYER_REGEN_DISABLED", function() self:_StartAoETicker() end, "spec")
    self:On("PLAYER_REGEN_ENABLED",  function() self:_StopAoETicker() end, "spec")
    if InCombatLockdown() then self:_StartAoETicker() end   -- loaded mid-combat
end

-- The AoE ticker is gated on combat + the toggle: a manually-managed Scheduler ticker (NOT
-- the "spec" scope), so starting/stopping it every combat doesn't accumulate scope teardowns.
-- _Start/_Stop are idempotent -- safe to call repeatedly.
function ClassModule:_StartAoETicker()
    local p = self:_p()
    if p.aoeTicker then return end                                   -- already running
    if not (p.aoeActive and self:IsEnabled() and self:GetSetting("aoeHelper")) then return end
    p.aoeTicker = ns.Scheduler:Every(0.1, function() self:_UpdateAoE() end)
    self:_UpdateAoE()   -- apply immediately rather than waiting for the first tick
end

function ClassModule:_StopAoETicker()
    local p = self:_p()
    if p.aoeTicker then p.aoeTicker:Cancel(); p.aoeTicker = nil end
    self:_ClearAoEGrey()
end

-- React to the aoeHelper toggle: run the ticker iff in combat AND enabled, else stop+clear.
function ClassModule:_RefreshAoETicker()
    if InCombatLockdown() and self:IsEnabled() and self:GetSetting("aoeHelper") then
        self:_StartAoETicker()
    else
        self:_StopAoETicker()
    end
end

-- The target count at which Spinning Crane Kick is worth pressing over Tiger Palm.
-- SCK hits every enemy, so at N targets it deals sck*N; we require it to beat Tiger
-- Palm by SCK_BIAS (since Tiger Palm also reduces brew cooldowns), i.e. sck*N >
-- tp*SCK_BIAS -> smallest such N = floor(tp*SCK_BIAS / sck) + 1. Read live from the
-- tooltips; falls back to the conventional 3 if either can't be parsed.
function ClassModule:_RefreshAoEThreshold()
    local p = self:_p()
    local tp  = spellHitDamage(Spell.TIGER_PALM)
    local sck = spellHitDamage(Spell.SPINNING_CRANE_KICK)
    p.aoeThreshold = MonkMath:AoEThreshold(tp, sck, SCK_BIAS) or 3   -- 3 = conventional fallback
end

function ClassModule:_UnloadAoE()
    self:_StopAoETicker()   -- cancel the combat ticker (manual handle) + clear the greying
    self:_p().aoeActive = false
end

function ClassModule:_ScanAoEButtons()
    local p = self:_p()
    p.tpButtons  = ns.ActionBars:FindSpell(Spell.TIGER_PALM)
    p.sckButtons = ns.ActionBars:FindSpell(Spell.SPINNING_CRANE_KICK)
    p.aoeGreyState = nil   -- button set may have changed -> force re-apply next update
end

function ClassModule:_UpdateAoE()
    local p = self:_p()
    if not (p.aoeActive and self:IsEnabled() and self:GetSetting("aoeHelper") and InCombatLockdown()) then
        return self:_ClearAoEGrey()
    end
    -- enemies within SCK's 8 yd (Range uses the item check; TP ~5yd is the fallback);
    -- grey TP once that count reaches the live SCK-beats-TP breakpoint. We only test
    -- "count >= threshold", so CountEnemies early-exits at the threshold.
    local threshold = p.aoeThreshold or 3
    local greyTP = ns.Range:CountEnemies(SCK_RADIUS, Spell.TIGER_PALM, threshold) >= threshold
    if greyTP == p.aoeGreyState then return end   -- unchanged -> skip the per-button work
    p.aoeGreyState = greyTP
    for _, b in ipairs(p.tpButtons or {})  do ns.ActionBars:SetGrey(b, greyTP) end
    for _, b in ipairs(p.sckButtons or {}) do ns.ActionBars:SetGrey(b, not greyTP) end
end

function ClassModule:_ClearAoEGrey()
    local p = self:_p()
    if p.aoeGreyState == nil then return end   -- already clear -> no per-button work
    p.aoeGreyState = nil
    for _, b in ipairs(p.tpButtons or {})  do ns.ActionBars:SetGrey(b, false) end
    for _, b in ipairs(p.sckButtons or {}) do ns.ActionBars:SetGrey(b, false) end
end


-- ---- Tiger Palm energy marker (Brewmaster) --------------------------------
-- Combined energy cost of Tiger Palm + Keg Smash (non-secret spell data).
-- Combined energy cost is static for a talent build, so it's cached and only recomputed
-- after TRAIT_CONFIG_UPDATED (which clears p.tigerCost) -- not on every power tick.
function ClassModule:_TigerCost()
    local p = self:_p()
    if p.tigerCost ~= nil then return p.tigerCost end
    local energy = Enum and Enum.PowerType and Enum.PowerType.Energy
    local costsPerSpell = {}
    for _, id in ipairs(TIGER_COST_SPELLS) do
        costsPerSpell[#costsPerSpell + 1] =
            C_Spell and C_Spell.GetSpellPowerCost and C_Spell.GetSpellPowerCost(id)
    end
    local total = MonkMath:SumEnergyCosts(costsPerSpell, energy, issecretvalue)
    p.tigerCost = total
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
    local costX = MonkMath:CostPoint(cost, maxE, barW)  -- the cost point, from the bar's left edge
    m:ClearAllPoints()
    -- left edge tracks current energy (the fill's right edge); right edge is the cost point.
    -- once current >= cost the left passes the right -> zero/negative width -> invisible.
    m:SetPoint("TOPLEFT",     efill, "TOPRIGHT",    0, 0)
    m:SetPoint("BOTTOMLEFT",  efill, "BOTTOMRIGHT", 0, 0)
    m:SetPoint("TOPRIGHT",    bar,   "TOPLEFT", costX, 0)
    m:SetPoint("BOTTOMRIGHT", bar,   "BOTTOMLEFT", costX, 0)
    m:Show()
end
