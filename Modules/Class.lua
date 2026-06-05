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

-- Parse "healing for N" out of the spell description (enUS). Returns a number.
local function readExpelHarmHeal()
    local desc = C_Spell and C_Spell.GetSpellDescription and C_Spell.GetSpellDescription(EXPEL_HARM)
    if not desc or desc == "" then return nil end
    local n = desc:match("healing for%s*([%d,]+)")
    if not n then return nil end
    return tonumber((n:gsub(",", "")))
end

-- the bar-learning hook is global; install once per session
local hookInstalled = false

-- ===========================================================================
-- Submodule registry: SUBMODULES[classToken][specKey] where specKey is "none"
-- (no specialisation) or a spec index (1-4). A submodule is:
--   { description, settings, Load(self), Unload(self) }   (self = ClassModule)
-- ===========================================================================
local SUBMODULES = { MONK = {} }

-- Expel Harm is a baseline Monk ability, so the same submodule serves the
-- no-spec state and the specs that have it (Brewmaster for now).
local ExpelHarm = {
    description = "Expel Harm heal-threshold marker on your health bar.",
    settings = {
        { type = "header", text = "Expel Harm" },
        { type = "toggle", key = "expelHarm", label = "Show heal-threshold marker", default = true,
          desc = "A line on your health bar marking where Expel Harm would heal you to full." },
        { type = "color", key = "expelColor", label = "Marker colour", default = { 1, 1, 1 } },
    },
    Load = function(self)
        local p = self:_p()
        local bus = ns.EventBus.Get()
        p.subTokens = {}
        -- heal scales with spell power, so re-read it on anything that changes
        -- it: gear, level, talents, and player auras (buffs); max-HP just needs
        -- a reposition.
        p.subTokens["UNIT_MAXHEALTH"]            = bus:On("UNIT_MAXHEALTH",            function(_, u) if u == "player" then self:_ScheduleUpdate() end end)
        p.subTokens["PLAYER_EQUIPMENT_CHANGED"]  = bus:On("PLAYER_EQUIPMENT_CHANGED",  function() self:_RefreshHeal() end)
        p.subTokens["PLAYER_LEVEL_UP"]           = bus:On("PLAYER_LEVEL_UP",           function() self:_RefreshHeal() end)
        p.subTokens["SPELLS_CHANGED"]            = bus:On("SPELLS_CHANGED",            function() self:_RefreshHeal() end)
        p.subTokens["TRAIT_CONFIG_UPDATED"]      = bus:On("TRAIT_CONFIG_UPDATED",      function() self:_RefreshHeal() end)
        p.subTokens["ACTIVE_COMBAT_CONFIG_CHANGED"] = bus:On("ACTIVE_COMBAT_CONFIG_CHANGED", function() self:_RefreshHeal() end)
        p.subTokens["UNIT_AURA"]                 = bus:On("UNIT_AURA",                 function(_, u) if u == "player" then self:_RefreshHeal() end end)
        -- hide the marker while Expel Harm is on cooldown, driven by the cast +
        -- a Cooldown widget so we never read the (possibly secret) cooldown time
        p.subTokens["UNIT_SPELLCAST_SUCCEEDED"]  = bus:On("UNIT_SPELLCAST_SUCCEEDED",  function(_, u, _, spellID) if u == "player" and spellID == EXPEL_HARM then self:_OnExpelCast() end end)
        p.subTokens["SPELL_UPDATE_COOLDOWN"]     = bus:On("SPELL_UPDATE_COOLDOWN",     function() self:_SyncCooldown() end)
        p.onCooldown = false
        p.expelActive = true
        self:_RefreshHeal()
        -- start hidden if we (re)loaded while the real cooldown is running (no
        -- GCD is active during a loading screen, so isActive here = real CD)
        local cd = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(EXPEL_HARM)
        if cd and cd.isActive and not cd.isOnGCD then p.onCooldown = true; self:_ScheduleUpdate() end
    end,
    Unload = function(self)
        local p = self:_p()
        local bus = ns.EventBus.Get()
        if p.subTokens then
            for event, token in pairs(p.subTokens) do bus:Off(event, token) end
            wipe(p.subTokens)
        end
        p.expelActive = false
        p.onCooldown = false
        if p.marker then p.marker:Hide() end
    end,
}

SUBMODULES.MONK["none"] = ExpelHarm
SUBMODULES.MONK[1]      = ExpelHarm  -- Brewmaster

-- "none" when the player has no specialisation, else the spec index (1-4).
-- A spec-less character returns an out-of-range "initial" index (e.g. 5 for a
-- pre-level-10 Monk) whose GetSpecializationInfo has no name.
local function currentSpecKey()
    local idx = GetSpecialization and GetSpecialization()
    if not idx then return "none" end
    local num = (GetNumSpecializations and GetNumSpecializations()) or 0
    if idx < 1 or idx > num then return "none" end
    local _, name = (GetSpecializationInfo and GetSpecializationInfo(idx))
    if not name or name == "" then return "none" end
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
    p.activeSub = nil
    p.expelActive = false
    p.updateScheduled = false
    local className, classToken = UnitClass("player")
    p.class = classToken

    -- Settings reflect the submodule for the player's CURRENT spec (at login).
    local sub = self:_Submodule()
    if sub then
        p.description = sub.description or ((className or "Class") .. " helpers.")
        p.settings = sub.settings or {}
    else
        p.description = ("No helpers for your %s specialisation yet."):format(className or "class")
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
end

function ClassModule:OnEnable()
    local p = self:_p()
    if not SUBMODULES[p.class] then return end  -- no helpers for this class yet

    -- Module-level: watch for spec changes to swap submodules.
    local bus = ns.EventBus.Get()
    p.tokens["PLAYER_SPECIALIZATION_CHANGED"] = bus:On("PLAYER_SPECIALIZATION_CHANGED", function() self:_Sync() end)
    p.tokens["PLAYER_ENTERING_WORLD"]         = bus:On("PLAYER_ENTERING_WORLD",         function() self:_Sync() end)

    self:_Sync()
end

function ClassModule:OnDisable()
    local p = self:_p()
    local bus = ns.EventBus.Get()
    for event, token in pairs(p.tokens) do bus:Off(event, token) end
    wipe(p.tokens)
    if p.activeSub and p.activeSub.Unload then p.activeSub.Unload(self) end
    p.activeSub = nil
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

-- Hide the marker ONLY when you cast Expel Harm. A plain global cooldown or a
-- stun must never hide it — those aren't its real cooldown.
function ClassModule:_OnExpelCast()
    local p = self:_p()
    p.onCooldown = true
    self:_ScheduleUpdate()
end

-- Polling only ever RE-SHOWS (never hides), so a GCD/stun can't false-hide the
-- marker. Re-show once the spell's cooldown is fully done. isActive is a plain
-- boolean (the times are the secret bits).
function ClassModule:_SyncCooldown()
    local p = self:_p()
    if not p.onCooldown then return end
    local info = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(EXPEL_HARM)
    if info and info.isActive then return end  -- still on cooldown
    p.onCooldown = false
    self:_ScheduleUpdate()
end

function ClassModule:OnSettingChanged()
    self:_ScheduleUpdate()
end

-- ---- registration ---------------------------------------------------------
ns.ModuleManager.Get():Register(ClassModule:New("Class", {
    title = "Class",
    description = "Helpers for your current class.",
    defaultEnabled = false,
    perChar = true,  -- class/spec differ per character, so store state per char
    settings = {},   -- built per class/spec in OnInitialize
}))
