local addonName, ns = ...

-- Modules/Class/Hunter/Hunter.lua
-- Hunter entry point and shared Steady Shot Focus prediction behaviour. The
-- prediction amount is read from the localized in-game tooltip; current Focus is
-- represented by Blizzard's status-bar fill edge, so addon code never reads or
-- performs arithmetic on that potentially-secret value.

local ClassModule = ns.ClassModule
local UnitPowerMax = UnitPowerMax
local POWER_FOCUS = Enum and Enum.PowerType and Enum.PowerType.Focus

local Spell = ns.Enum.new("HunterSpell", {
    STEADY_SHOT = 56641,
})

local STEADY_COLOR = ns.Color:New(1, 1, 1)
local STEADY_CAST_COLOR = ns.Color:New(1, 0.78, 0.18)

local function readSteadyFocusGain()
    local desc = C_Spell and C_Spell.GetSpellDescription
        and C_Spell.GetSpellDescription(Spell.STEADY_SHOT)
    return ns.SpellTooltipParser.ResourceGain(desc, "Focus")
end

local classMod = assert(ns.ModuleManager:GetModule("Class"),
    "Hunter submodule requires the Class module (load Modules/Class.lua first)")
local function isHunter() return (select(2, UnitClass("player"))) == "HUNTER" end

ns.SubmoduleManager:Register(ns.Submodule:New("Hunter", {
    parent = { module = "Class" },
    condition = isHunter,
}))

local Hunter = ns.Class.new("Hunter", nil, {
    statics = {
        steadyColor = STEADY_COLOR,
        steadyCastColor = STEADY_CAST_COLOR,
    },
})
local S = ns.Class.statics(Hunter)

function Hunter.SteadyColor() return S.steadyColor end
function Hunter.SteadyCastColor() return S.steadyCastColor end

-- Register one shared Hunter behaviour for each requested specialization key.
-- This lets features that apply to both specless Hunter and a specialization
-- share one implementation and lifecycle.
function Hunter.RegisterSpecs(name, SpecClass, specKeys, serviceDeps)
    local spec = SpecClass:New(classMod)
    local enabledSpecs = {}
    for _, specKey in ipairs(specKeys) do
        enabledSpecs[specKey] = true
        if isHunter() then classMod:RegisterSpec(specKey, spec) end
    end
    local deps = { "SettingsWindow" }
    for _, d in ipairs(serviceDeps) do deps[#deps + 1] = d end
    ns.SubmoduleManager:Register(ns.Submodule:New(name, {
        parent = { submodule = "Hunter" },
        host = classMod,
        deps = deps,
        condition = function()
            return enabledSpecs[classMod:CurrentSpecKey()] == true
        end,
        conditionEvents = { "PLAYER_SPECIALIZATION_CHANGED", "PLAYER_ENTERING_WORLD" },
        onLoad = function(host)
            host:SetActiveSpec(spec)
            host:_BuildSettings()
            spec:Load()
            if ns.UI and ns.UI.SettingsWindow then
                ns.UI.SettingsWindow:InvalidateModule(host:GetName())
            end
        end,
        onUnload = function(host)
            spec:Unload()
            host:ClearActiveSpec()
        end,
    }))
end

ns.Hunter = Hunter

-- hag-lint-disable depcheck: Secrets -- the Hunter base submodule declares it;
-- these host methods use it only while that submodule is loaded.

function ClassModule:_SnapshotSteadyMax()
    local maxFocus = UnitPowerMax("player", POWER_FOCUS)
    if maxFocus and not ns.Secrets:Is(maxFocus) and maxFocus > 0 then
        self:_p().steadyMaxSnap = maxFocus
    end
end

function ClassModule:_RefreshSteadyGainNow()
    local p = self:_p()
    local gain = readSteadyFocusGain()
    p.steadyGain = gain and gain > 0 and gain or nil
    self:_SnapshotSteadyMax()
    if not p.steadyGain then
        -- Spell descriptions can be unavailable during the first login frame.
        self:After(1, function()
            if p.steadyActive and not p.steadyGain then
                local retry = readSteadyFocusGain()
                p.steadyGain = retry and retry > 0 and retry or nil
                self:_UpdateSteadyCastFill()
                self:_ScheduleSteady()
            end
        end, "hunter")
    end
end

function ClassModule:_RefreshSteadyGain()
    self:_RefreshSteadyGainNow()
    self:_UpdateSteadyCastFill()
    self:_ScheduleSteady()
end

function ClassModule:_ScheduleSteady()
    local p = self:_p()
    if p.steadyScheduled then return end
    p.steadyScheduled = true
    self:After(0, function()
        p.steadyScheduled = false
        self:_UpdateSteady()
    end, "hunter")
end

function ClassModule:_StartSteadyCast(castGUID, spellID)
    local p = self:_p()
    p.steadyCasting = spellID == Spell.STEADY_SHOT
    p.steadyCastGUID = p.steadyCasting and castGUID or nil
    self:_UpdateSteadyCastFill()
    self:_ScheduleSteady()
end

function ClassModule:_StopSteadyCast(castGUID, spellID)
    local p = self:_p()
    if not p.steadyCasting then return end
    -- Match the cast token when supplied; the spell-ID fallback covers clients or
    -- terminal cast events that omit the token.
    if (castGUID and castGUID == p.steadyCastGUID) or spellID == Spell.STEADY_SHOT then
        p.steadyCasting = false
        p.steadyCastGUID = nil
        self:_UpdateSteadyCastFill()
        self:_ScheduleSteady()
    end
end

function ClassModule:_SteadyBarVisuals()
    local p = self:_p()
    local bar = p.steadyPowerBar
    if not bar then return nil end
    local fill = bar.GetStatusBarTexture and bar:GetStatusBarTexture()
    if not fill then return nil end

    if p.steadyHostBar ~= bar then
        if p.steadyHost then p.steadyHost:Hide() end
        local host = ns.UI.Widgets.Container:New(bar)
        host:SetAllPoints(bar)
        host:SetClipsChildren(true)
        p.steadyHost = host
        p.steadyHostBar = bar
        p.steadyMarker = nil
    end
    return bar, fill
end

function ClassModule:_SteadyGainWidth(bar, gain, maxFocus)
    local p = self:_p()
    local liveWidth = bar:GetWidth()
    if liveWidth and not ns.Secrets:Is(liveWidth) and liveWidth > 0 then
        p.steadyWidthSnap = liveWidth
    end
    local barWidth = p.steadyWidthSnap
    if not barWidth or barWidth <= 0 then return nil end
    return (gain / maxFocus) * barWidth
end

-- Use Blizzard's own masked ManaCostPredictionBar segment to continue the native
-- fill. Do NOT call its UpdateFillPosition method: that reads the bar's secret max
-- and divides in addon-tainted execution. We already have plain max/width snapshots,
-- so only position its native FillMask with non-secret pixel geometry.
function ClassModule:_UpdateSteadyCastFill()
    local p = self:_p()
    local prior = p.steadyNativePrediction
    if not (self:IsEnabled() and p.steadyActive and p.steadyCasting
            and self:GetSetting("steadyCastFill")) then
        if prior then prior:Hide() end
        p.steadyNativePredictionShown = false
        return
    end

    local bar = p.steadyPowerBar
    local fill = bar and bar.GetStatusBarTexture and bar:GetStatusBarTexture()
    local prediction = bar and bar.ManaCostPredictionBar
    if not (bar and fill and prediction and prediction.Fill and prediction.FillMask) then
        if prior then prior:Hide() end
        p.steadyNativePredictionShown = false
        return
    end

    local gain = p.steadyGain
    local maxFocus = UnitPowerMax("player", POWER_FOCUS)
    if maxFocus and not ns.Secrets:Is(maxFocus) and maxFocus > 0 then
        p.steadyMaxSnap = maxFocus
    else
        maxFocus = p.steadyMaxSnap
    end
    if not gain or gain <= 0 or not maxFocus or maxFocus <= 0 then
        if prior then prior:Hide() end
        p.steadyNativePredictionShown = false
        return
    end

    local width = self:_SteadyGainWidth(bar, gain, maxFocus)
    if not width then
        if prior then prior:Hide() end
        p.steadyNativePredictionShown = false
        return
    end
    if prior and prior ~= prediction then prior:Hide() end
    local color = self:GetSetting("steadyCastColor") or STEADY_CAST_COLOR
    prediction.Fill:SetVertexColor(color:R(), color:G(), color:B(), 1)
    prediction.FillMask:ClearAllPoints()
    prediction.FillMask:SetPoint("TOPLEFT", fill, "TOPRIGHT", 0, 0)
    prediction.FillMask:SetPoint("BOTTOMLEFT", fill, "BOTTOMRIGHT", 0, 0)
    prediction.FillMask:SetWidth(width)
    prediction:Show()
    p.steadyNativePrediction = prediction
    p.steadyNativePredictionShown = true
end

-- Draw a translucent extension from Blizzard's current Focus fill edge. The
-- clipped host caps the extension at the bar's maximum, producing the post-cast
-- Focus result without ever asking addon code for the current (possibly secret)
-- Focus number.
function ClassModule:_UpdateSteady()
    local p = self:_p()
    local bar = p.steadyPowerBar
    if not bar then return end

    if not (self:IsEnabled() and p.steadyActive and self:GetSetting("steadyShot")) then
        if p.steadyMarker then p.steadyMarker:Hide() end
        return
    end

    local gain = p.steadyGain
    local maxFocus = UnitPowerMax("player", POWER_FOCUS)
    if maxFocus and not ns.Secrets:Is(maxFocus) and maxFocus > 0 then
        p.steadyMaxSnap = maxFocus
    else
        maxFocus = p.steadyMaxSnap
    end
    if not gain or gain <= 0 or not maxFocus or maxFocus <= 0 then
        if p.steadyMarker then p.steadyMarker:Hide() end
        return
    end

    local visualBar, fill = self:_SteadyBarVisuals()
    if not visualBar then
        if p.steadyMarker then p.steadyMarker:Hide() end
        return
    end
    if not p.steadyMarker then
        p.steadyMarker = ns.UI.Widgets.Fill:New(p.steadyHost, { layer = "OVERLAY", sublevel = 7 })
    end

    local width = self:_SteadyGainWidth(bar, gain, maxFocus)
    if not width then
        p.steadyMarker:Hide()
        return
    end

    local marker = p.steadyMarker
    local color = self:GetSetting("steadyColor") or STEADY_COLOR
    marker:SetColorTexture(color:R(), color:G(), color:B(), 0.55)
    marker:ClearAllPoints()
    -- While the native cast prediction is visible, chain this SECOND segment
    -- after its FillMask rather than overlapping it. Outside that cast state it
    -- retains the original behaviour and starts at the live Focus fill edge.
    local anchor = fill
    if p.steadyNativePredictionShown and p.steadyNativePrediction then
        anchor = p.steadyNativePrediction.FillMask
    end
    marker:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 0, 0)
    marker:SetPoint("BOTTOMLEFT", anchor, "BOTTOMRIGHT", 0, 0)
    marker:SetWidth(width)
    marker:Show()
    p.steadyHost:Show()
end
