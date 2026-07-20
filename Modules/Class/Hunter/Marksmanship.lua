local addonName, ns = ...
local Class = ns.Class
local Hunter = ns.Hunter

-- Marksmanship is Hunter specialisation index 2. Steady Shot generates Focus
-- for this spec, so its prediction is deliberately scoped here.
local HunterMarksmanship = Class.new("HunterMarksmanship", ns.ClassSpec, { statics = { settings = {
    { type = "header", text = "Steady Shot" },
    { type = "toggle", key = "steadyShot", label = "Show post-cast Focus", default = true,
      desc = "A bar showing how much Focus you will have after Steady Shot finishes." },
    { type = "color", key = "steadyColor", label = "Prediction colour",
      default = Hunter.SteadyColor(), dependsOn = "steadyShot" },
} } })

function HunterMarksmanship:OnSettingChanged()
    self:Host():_ScheduleSteady()
end

function HunterMarksmanship:Load()
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
            end
        end)
        p.steadyPowerHookInstalled = true
    end

    p.steadyActive = true
    host:On("UNIT_MAXPOWER", function(_, unit)
        if unit == "player" then host:_SnapshotSteadyMax(); host:_ScheduleSteady() end
    end, "spec")
    host:On("UNIT_DISPLAYPOWER", function(_, unit)
        if unit == "player" then host:_SnapshotSteadyMax(); host:_ScheduleSteady() end
    end, "spec")
    host:On("TRAIT_CONFIG_UPDATED",       function() host:_RefreshSteadyGain() end, "spec")
    host:On("ACTIVE_COMBAT_CONFIG_CHANGED", function() host:_RefreshSteadyGain() end, "spec")
    host:On("SPELLS_CHANGED",             function() host:_RefreshSteadyGain() end, "spec")
    host:On("PLAYER_LEVEL_UP",            function() host:_RefreshSteadyGain() end, "spec")
    host:On("PLAYER_ENTERING_WORLD",      function() host:_RefreshSteadyGain() end, "spec")
    host:_RefreshSteadyGain()
end

function HunterMarksmanship:Unload()
    local host = self:Host()
    local p = host:_p()
    host:ReleaseScope("spec")
    p.steadyScheduled = false
    p.steadyActive = false
    if p.steadyMarker then p.steadyMarker:Hide() end
end

Hunter.RegisterSpec("Hunter-Marksmanship", HunterMarksmanship, 2, { "EventBus", "Secrets" })
