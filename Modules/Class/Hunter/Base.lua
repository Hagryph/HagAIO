local addonName, ns = ...
local Class = ns.Class
local Hunter = ns.Hunter

-- Specless Hunter behaviour (CurrentSpecKey "none"): it unloads as soon as the
-- player chooses a Hunter specialisation.
local HunterBase = Class.new("HunterBase", ns.ClassSpec, { statics = { settings = {
    { type = "header", text = "Steady Shot" },
    { type = "toggle", key = "steadyCastFill", label = "Steady Shot Focus Gain", default = true,
      desc = "While casting Steady Shot, show the Focus it will generate." },
    { type = "color", key = "steadyCastColor", label = "Focus Gain colour",
      default = Hunter.SteadyCastColor(), dependsOn = "steadyCastFill" },
    { type = "toggle", key = "steadyShot", label = "Post-Cast Focus", default = true,
      desc = "Show your predicted Focus after Steady Shot finishes." },
    { type = "color", key = "steadyColor", label = "Post-Cast Focus colour",
      default = Hunter.SteadyColor(), dependsOn = "steadyShot" },
} } })

function HunterBase:OnSettingChanged()
    local host = self:Host()
    host:_UpdateSteadyCastFill()
    host:_ScheduleSteady()
end

function HunterBase:Load()
    local host = self:Host()
    local p = host:_p()

    -- Learn Blizzard's player Focus bar once it updates. The fill itself tracks
    -- current Focus, so ordinary power ticks require no addon repaint.
    if not p.steadyPowerHookInstalled and type(UnitFrameManaBar_Update) == "function" then
        hooksecurefunc("UnitFrameManaBar_Update", function(statusbar, unit)
            if unit == "player" and statusbar.unitFrame == PlayerFrame then
                local hp = host:_p()
                if hp.steadyPowerBar ~= statusbar then
                    hp.steadyPowerBar = statusbar
                    host:_WatchBarSize(statusbar, function() host:_ScheduleSteady() end)
                    host:_ScheduleSteady()
                end
                host:_UpdateSteadyCastFill()
            end
        end)
        p.steadyPowerHookInstalled = true
    end

    -- Blizzard updates (and normally hides) ManaCostPredictionBar for every cast.
    -- Reapply our positive Steady Shot continuation after that native update, using
    -- the same native segment rather than competing with it from a separate texture.
    if not p.steadyPredictionHookInstalled and type(UnitFrameManaCostPredictionBars_Update) == "function" then
        hooksecurefunc("UnitFrameManaCostPredictionBars_Update", function(frame)
            if frame == PlayerFrame then
                local hp = host:_p()
                if not hp.steadyPowerBar and frame.manabar then
                    hp.steadyPowerBar = frame.manabar
                    host:_WatchBarSize(frame.manabar, function() host:_ScheduleSteady() end)
                end
                host:_UpdateSteadyCastFill()
            end
        end)
        p.steadyPredictionHookInstalled = true
    end

    p.steadyActive = true
    p.steadyCasting = false
    p.steadyCastGUID = nil

    host:OnUnit("UNIT_SPELLCAST_START", { "player" }, function(_, _, castGUID, spellID)
        host:_StartSteadyCast(castGUID, spellID)
    end, "hunter")
    local function stopCast(_, _, castGUID, spellID)
        host:_StopSteadyCast(castGUID, spellID)
    end
    host:OnUnit("UNIT_SPELLCAST_STOP",        { "player" }, stopCast, "hunter")
    host:OnUnit("UNIT_SPELLCAST_FAILED",      { "player" }, stopCast, "hunter")
    host:OnUnit("UNIT_SPELLCAST_FAILED_QUIET", { "player" }, stopCast, "hunter")
    host:OnUnit("UNIT_SPELLCAST_INTERRUPTED", { "player" }, stopCast, "hunter")
    host:OnUnit("UNIT_SPELLCAST_SUCCEEDED",   { "player" }, stopCast, "hunter")

    host:On("UNIT_MAXPOWER", function(_, unit)
        if unit == "player" then
            host:_SnapshotSteadyMax(); host:_UpdateSteadyCastFill(); host:_ScheduleSteady()
        end
    end, "hunter")
    host:On("UNIT_DISPLAYPOWER", function(_, unit)
        if unit == "player" then
            host:_SnapshotSteadyMax(); host:_UpdateSteadyCastFill(); host:_ScheduleSteady()
        end
    end, "hunter")
    host:On("TRAIT_CONFIG_UPDATED",         function() host:_RefreshSteadyGain() end, "hunter")
    host:On("ACTIVE_COMBAT_CONFIG_CHANGED", function() host:_RefreshSteadyGain() end, "hunter")
    host:On("SPELLS_CHANGED",               function() host:_RefreshSteadyGain() end, "hunter")
    host:On("PLAYER_LEVEL_UP",              function() host:_RefreshSteadyGain() end, "hunter")
    host:On("PLAYER_ENTERING_WORLD",        function() host:_RefreshSteadyGain() end, "hunter")
    host:_RefreshSteadyGain()
end

function HunterBase:Unload()
    local host = self:Host()
    local p = host:_p()
    host:ReleaseScope("hunter")
    p.steadyScheduled = false
    p.steadyActive = false
    p.steadyCasting = false
    p.steadyCastGUID = nil
    if p.steadyMarker then p.steadyMarker:Hide() end
    if p.steadyNativePrediction then p.steadyNativePrediction:Hide() end
    p.steadyNativePredictionShown = false
end

Hunter.RegisterBase("Hunter-Base", HunterBase, { "EventBus", "Secrets" })
