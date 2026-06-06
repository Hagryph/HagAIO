local addonName, ns = ...
local Class = ns.Class

-- Modules/Class.lua
-- Class-specific helpers, organised as submodules: one per specialisation, plus
-- a "no specialisation" submodule, per class. The active submodule is chosen by
-- the player's CURRENT spec and swapped on spec change (the old one is fully
-- unloaded first). We never fall back to the no-spec submodule while a spec is
-- active — no-spec is only for characters with no specialisation.
--
-- Implemented so far: Monk, no specialisation -> Expel Harm heal-threshold
-- marker (a line on the health bar at maxHP - heal).

local ClassModule = Class.new("Class", ns.Module)

local EXPEL_HARM = 322101
local GRACE_OF_CRANE = 388811   -- passive talent: increases healing taken

-- Extra healing-taken multiplier from talents the spell tooltip doesn't fold in.
-- Grace of the Crane raises all healing taken by a flat % -- read that % from its
-- own description so it tracks tuning (defaults to 4%). 1.0 when not talented.
local function healingTakenMultiplier()
    if not (IsPlayerSpell and IsPlayerSpell(GRACE_OF_CRANE)) then return 1 end
    local desc = C_Spell and C_Spell.GetSpellDescription and C_Spell.GetSpellDescription(GRACE_OF_CRANE)
    local pct = tonumber(desc and desc:match("by%s*(%d+)%%")) or 4
    return 1 + pct / 100
end

-- Parse "healing for N" out of the spell description (enUS), then apply any
-- healing-taken talent bonus the tooltip leaves out. Returns a number.
local function readExpelHarmHeal()
    local desc = C_Spell and C_Spell.GetSpellDescription and C_Spell.GetSpellDescription(EXPEL_HARM)
    if not desc or desc == "" then return nil end
    local n = desc:match("healing for%s*([%d,]+)")
    if not n then return nil end
    local heal = tonumber((n:gsub(",", "")))
    if not heal then return nil end
    return math.floor(heal * healingTakenMultiplier() + 0.5)
end

-- Base cooldown in seconds (static spell data, not the secret live remaining).
local function expelCooldownSeconds()
    if not GetSpellBaseCooldown then return nil end
    local ms = GetSpellBaseCooldown(EXPEL_HARM)
    if not ms or (issecretvalue and issecretvalue(ms)) or ms <= 0 then return nil end
    return ms / 1000
end

-- the bar-learning hooks are global; install once per session
local hookInstalled = false        -- health bar
local powerHookInstalled = false   -- power (energy) bar

-- Brewmaster energy spells for the Tiger Palm marker
local TIGER_PALM = 100780
local KEG_SMASH  = 121253

-- ===========================================================================
-- Submodule registry: SUBMODULES[classToken][specKey] where specKey is "none"
-- (no specialisation) or a spec index (1-4). A submodule is:
--   { settings, Load(self), Unload(self) }   (self = ClassModule)
-- Submodules register events via self:_Sub(event, fn) (removed by _UnloadSubs),
-- so one submodule can layer several features.
-- ===========================================================================
local SUBMODULES = { MONK = {} }

-- Base: the no-specialisation submodule, providing the Expel Harm marker that
-- every Monk has. Other specs extend it.
local Base = {
    settings = {
        { type = "header", text = "Expel Harm" },
        { type = "toggle", key = "expelHarm", label = "Show heal-threshold marker", default = true,
          desc = "A line on your health bar marking where Expel Harm would heal you to full." },
        { type = "color", key = "expelColor", label = "Marker colour", default = { 1, 1, 1 } },
    },
    Load = function(self)
        local p = self:_p()
        -- heal scales with spell power, so re-read it on anything that changes it
        self:_Sub("UNIT_MAXHEALTH",             function(_, u) if u == "player" then self:_ScheduleUpdate() end end)
        self:_Sub("PLAYER_EQUIPMENT_CHANGED",   function() self:_RefreshHeal() end)
        self:_Sub("PLAYER_LEVEL_UP",            function() self:_RefreshHeal() end)
        self:_Sub("SPELLS_CHANGED",             function() self:_RefreshHeal() end)
        self:_Sub("TRAIT_CONFIG_UPDATED",       function() self:_RefreshHeal() end)
        self:_Sub("ACTIVE_COMBAT_CONFIG_CHANGED", function() self:_RefreshHeal() end)
        self:_Sub("UNIT_AURA",                  function(_, u) if u == "player" then self:_RefreshHeal() end end)
        -- hide the marker while Expel Harm is on cooldown (cast + non-secret booleans)
        self:_Sub("UNIT_SPELLCAST_SUCCEEDED",   function(_, u, _, spellID) if u == "player" and spellID == EXPEL_HARM then self:_OnExpelCast() end end)
        self:_Sub("SPELL_UPDATE_COOLDOWN",      function() self:_SyncCooldown() end)
        p.onCooldown = false
        p.expelActive = true
        self:_RefreshHeal()
        -- start hidden if we (re)loaded while the real cooldown is running
        local cd = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(EXPEL_HARM)
        if cd and cd.isActive and not cd.isOnGCD then p.onCooldown = true; self:_ScheduleUpdate() end
    end,
    Unload = function(self)
        local p = self:_p()
        self:_UnloadSubs()
        p.expelActive = false
        p.onCooldown = false
        if p.cdTimer then p.cdTimer:Cancel(); p.cdTimer = nil end
        if p.marker then p.marker:Hide() end
    end,
}

-- Brewmaster: extends Base with a Tiger Palm/Keg Smash energy-cost marker.
local Brewmaster = {
    settings = {
        { type = "header", text = "Expel Harm" },
        { type = "toggle", key = "expelHarm", label = "Show heal-threshold marker", default = true,
          desc = "A line on your health bar marking where Expel Harm would heal you to full." },
        { type = "color", key = "expelColor", label = "Marker colour", default = { 1, 1, 1 } },
        { type = "header", text = "Tiger Palm" },
        { type = "toggle", key = "tiger", label = "Show energy marker", default = true,
          desc = "A line on the energy bar at the energy needed for Tiger Palm + Keg Smash." },
        { type = "color", key = "tigerColor", label = "Marker colour", default = { 1, 1, 1 } },
    },
    Load = function(self)
        Base.Load(self)
        local p = self:_p()
        p.tigerActive = true
        self:_Sub("UNIT_MAXPOWER",        function(_, u) if u == "player" then self:_ScheduleTiger() end end)
        self:_Sub("UNIT_DISPLAYPOWER",    function(_, u) if u == "player" then self:_ScheduleTiger() end end)
        self:_Sub("TRAIT_CONFIG_UPDATED", function() self:_ScheduleTiger() end)
        self:_Sub("PLAYER_LEVEL_UP",      function() self:_ScheduleTiger() end)
        self:_ScheduleTiger()
    end,
    Unload = function(self)
        Base.Unload(self)  -- _UnloadSubs() removes every sub, incl. tiger's
        local p = self:_p()
        p.tigerActive = false
        if p.tigerMarker then p.tigerMarker:Hide() end
    end,
}

SUBMODULES.MONK["none"] = Base        -- no specialisation
SUBMODULES.MONK[1]      = Brewmaster  -- + Tiger Palm energy marker

-- "none" when the player has no specialisation, else the spec index (1-4).
-- A spec-less character returns an out-of-range "initial" index (e.g. 5 for a
-- pre-level-10 Monk, which is > GetNumSpecializations). Note: GetSpecialization-
-- Info returns name=nil even for real specs on 12.0, so we must NOT gate on the
-- name — the in-range index is what's reliable.
local function currentSpecKey()
    local idx = GetSpecialization and GetSpecialization()
    if not idx then return "none" end
    local num = (GetNumSpecializations and GetNumSpecializations()) or 0
    if idx < 1 or idx > num then return "none" end
    return idx
end

-- ---- lifecycle ------------------------------------------------------------
function ClassModule:_Submodule()
    local reg = SUBMODULES[self:_p().class]
    return reg and reg[currentSpecKey()] or nil
end

function ClassModule:OnInitialize()
    local p = self:_p()
    p.tokens = {}
    p.subTokens = {}
    p.heal = nil
    p.marker = nil
    p.host = nil
    p.onCooldown = false
    p.cdTimer = nil
    p.activeSub = nil
    p.expelActive = false
    p.updateScheduled = false
    p.powerBar = nil
    p.tigerMarker = nil
    p.tigerHost = nil
    p.tigerActive = false
    p.tigerScheduled = false
    local className, classToken = UnitClass("player")
    p.class = classToken

    -- Settings reflect the submodule for the player's CURRENT spec (at login).
    local sub = self:_Submodule()
    p.description = "Helpers tailored to your class and specialisation."
    if sub then
        p.settings = sub.settings or {}
    else
        p.settings = { { type = "note", text = "Nothing for your current specialisation yet." } }
    end

    -- migrate the old cyan marker default to the new white default
    local db = self:GetDB()
    if db and type(db.expelColor) == "table" and db.expelColor[1] == 0.29 then
        db.expelColor = nil
    end
    if db then
        for _, s in ipairs(p.settings) do
            if s.key ~= nil and s.default ~= nil and db[s.key] == nil then
                if type(s.default) == "table" then
                    local c = {}
                    for i, v in ipairs(s.default) do c[i] = v end
                    db[s.key] = c
                else
                    db[s.key] = s.default
                end
            end
        end
    end

    -- Install the bar-learning hook now (even while disabled) so a submodule's
    -- marker can appear immediately on enable, without a reload.
    if classToken == "MONK" and not hookInstalled and type(UnitFrameHealthBar_Update) == "function" then
        local module = self
        hooksecurefunc("UnitFrameHealthBar_Update", function(statusbar, unit)
            -- Only the real PlayerFrame bar. Other frames (pet / target-of-target)
            -- transiently carry unit "player" during vehicle/art swaps; touching
            -- them here can flush a pending resize that compares secret health.
            if unit == "player" and statusbar.unitFrame == PlayerFrame then
                module:_p().bar = statusbar
                module:_ScheduleUpdate()
            end
        end)
        hookInstalled = true
    end

    -- power (energy) bar, for the Brewmaster Tiger Palm marker
    if classToken == "MONK" and not powerHookInstalled and type(UnitFrameManaBar_Update) == "function" then
        local module = self
        hooksecurefunc("UnitFrameManaBar_Update", function(statusbar, unit)
            if unit == "player" and statusbar.unitFrame == PlayerFrame then
                module:_p().powerBar = statusbar
                if not module:_p().tigerMarker then module:_ScheduleTiger() end
            end
        end)
        powerHookInstalled = true
    end
end

function ClassModule:OnEnable()
    local p = self:_p()
    if not SUBMODULES[p.class] then return end  -- no helpers for this class yet

    -- Module-level: watch for spec changes to swap submodules.
    local bus = ns.EventBus
    p.tokens["PLAYER_SPECIALIZATION_CHANGED"] = bus:On("PLAYER_SPECIALIZATION_CHANGED", function() self:_Sync() end)
    p.tokens["PLAYER_ENTERING_WORLD"]         = bus:On("PLAYER_ENTERING_WORLD",         function() self:_Sync() end)

    self:_Sync()
end

function ClassModule:OnDisable()
    local p = self:_p()
    local bus = ns.EventBus
    for event, token in pairs(p.tokens) do bus:Off(event, token) end
    wipe(p.tokens)
    if p.activeSub and p.activeSub.Unload then p.activeSub.Unload(self) end
    p.activeSub = nil
end

-- Submodule event subscriptions (a list, so several features can share events).
function ClassModule:_Sub(event, fn)
    local p = self:_p()
    p.subTokens = p.subTokens or {}
    local token = ns.EventBus:On(event, fn)
    if token then p.subTokens[#p.subTokens + 1] = { event, token } end
end

function ClassModule:_UnloadSubs()
    local p = self:_p()
    if not p.subTokens then return end
    local bus = ns.EventBus
    for _, e in ipairs(p.subTokens) do bus:Off(e[1], e[2]) end
    wipe(p.subTokens)
end

-- Load the submodule matching the current spec, unloading the previous one.
function ClassModule:_Sync()
    local p = self:_p()
    if not self:IsEnabled() then return end
    local sub = self:_Submodule()
    if sub == p.activeSub then return end
    if p.activeSub and p.activeSub.Unload then p.activeSub.Unload(self) end
    p.activeSub = sub
    if sub and sub.Load then sub.Load(self) end
end

-- ---- Expel Harm marker (used by the Monk no-spec submodule) ----------------
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

    if p.onCooldown or not (self:IsEnabled() and p.expelActive and self:GetSetting("expelHarm")) then
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

    local c = self:GetSetting("expelColor") or { 1, 1, 1 }
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

-- Hide the marker ONLY when you cast Expel Harm, and drive an internal timer
-- (base cooldown) to re-show at the exact moment it ends — immune to GCD/stun,
-- which never hide it.
function ClassModule:_OnExpelCast()
    local p = self:_p()
    p.onCooldown = true
    self:_ScheduleUpdate()

    if p.cdTimer then p.cdTimer:Cancel() end
    local dur = expelCooldownSeconds()
    if dur then
        p.cdTimer = C_Timer.NewTimer(dur, function()
            p.cdTimer = nil
            p.onCooldown = false
            self:_ScheduleUpdate()
        end)
    end
end

-- Backup re-show: if the cooldown ends early (reset / CDR) before the timer, or
-- if we had no timer (reload mid-cooldown). Only ever shows, never hides — a GCD
-- reports isActive=true too, so we must not hide from polling. isActive is a
-- plain boolean (the times are the secret bits).
function ClassModule:_SyncCooldown()
    local p = self:_p()
    if not p.onCooldown then return end
    local info = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(EXPEL_HARM)
    if info and info.isActive then return end  -- still on cooldown
    if p.cdTimer then p.cdTimer:Cancel(); p.cdTimer = nil end
    p.onCooldown = false
    self:_ScheduleUpdate()
end

function ClassModule:OnSettingChanged()
    self:_ScheduleUpdate()
    self:_ScheduleTiger()
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
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    local x = frac * bar:GetWidth()
    m:ClearAllPoints()
    m:SetPoint("TOP", bar, "TOPLEFT", x, 0)
    m:SetPoint("BOTTOM", bar, "BOTTOMLEFT", x, 0)
    m:Show()
end

-- ---- registration ---------------------------------------------------------
ns.ModuleManager:Register(ClassModule:New("Class", {
    title = "Class",
    description = "Helpers for your current class.",
    defaultEnabled = false,
    perChar = true,  -- class/spec differ per character, so store state per char
    settings = {},   -- built per class/spec in OnInitialize
}))
