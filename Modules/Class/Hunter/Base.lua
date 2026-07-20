local addonName, ns = ...
local Class = ns.Class
local Hunter = ns.Hunter

-- Specless Hunter behaviour (CurrentSpecKey "none"): it unloads as soon as the
-- player chooses a Hunter specialisation.
local HunterBase = Class.new("HunterBase", ns.ClassSpec, { statics = { settings = {
    { type = "header", text = "Steady Shot" },
    { type = "toggle", key = "steadyShot", label = "Show post-cast Focus", default = true,
      desc = "Show a prediction band from current Focus to the amount you will have after Steady Shot finishes." },
    { type = "color", key = "steadyColor", label = "Prediction colour",
      default = Hunter.SteadyColor(), dependsOn = "steadyShot" },
    { type = "toggle", key = "steadyCastFill", label = "Extend actual Focus while casting", default = true,
      desc = "While casting Steady Shot, extend Blizzard's actual Focus fill by the Focus the cast will generate." },
} } })

function HunterBase:OnSettingChanged()
    local host = self:Host()
    host:_UpdateSteadyBarRange()
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
                    host:_RestoreSteadyBarRange()
                    hp.steadyPowerBar = statusbar
                    host:_WatchBarSize(statusbar, function() host:_ScheduleSteady() end)
                    host:_ScheduleSteady()
                end
                -- Blizzard restores the ordinary [0, max] range during its own
                -- update; while Steady Shot is casting, reapply our predicted range.
                host:_UpdateSteadyBarRange()
            end
        end)
        p.steadyPowerHookInstalled = true
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
            host:_SnapshotSteadyMax(); host:_UpdateSteadyBarRange(); host:_ScheduleSteady()
        end
    end, "hunter")
    host:On("UNIT_DISPLAYPOWER", function(_, unit)
        if unit == "player" then
            host:_SnapshotSteadyMax(); host:_UpdateSteadyBarRange(); host:_ScheduleSteady()
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
    host:_RestoreSteadyBarRange()
    p.steadyScheduled = false
    p.steadyActive = false
    p.steadyCasting = false
    p.steadyCastGUID = nil
    if p.steadyMarker then p.steadyMarker:Hide() end
end

Hunter.RegisterBase("Hunter-Base", HunterBase, { "EventBus", "Secrets" })
