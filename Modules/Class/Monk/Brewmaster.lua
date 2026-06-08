local addonName, ns = ...
local Class = ns.Class
local Monk = ns.Monk   -- shared Monk surface (constants + registerSpec + Base), set in Monk.lua

-- Modules/Class/Monk/Brewmaster.lua
-- The Brewmaster Monk spec (CurrentSpecKey 1): extends MonkBase (Base.lua) with a Tiger
-- Palm/Keg Smash missing-energy bar and the AoE helper. A real subclass, so it reaches the
-- base behaviour via MonkBrewmaster.super, not by name. Loads after Base.lua, which set
-- ns.Monk.Base.

local MonkBrewmaster = Class.new("MonkBrewmaster", ns.Monk.Base)
MonkBrewmaster.settings = {
    { type = "header", text = "Expel Harm" },
    { type = "toggle", key = "expelHarm", label = "Show heal bar", default = true,
      desc = "A bar that fills from your current health to where Expel Harm would heal you, including Gift of the Ox orbs." },
    { type = "color", key = "expelColor", label = "Ready colour", default = Monk.EXPEL_READY_COLOR, dependsOn = "expelHarm" },
    { type = "color", key = "expelInactiveColor", label = "On-cooldown colour", default = Monk.EXPEL_COOLDOWN_COLOR, dependsOn = "expelHarm" },
    { type = "header", text = "Tiger Palm" },
    { type = "toggle", key = "tiger", label = "Show missing-energy bar", default = true,
      desc = "A bar showing how much energy you still need to cast Tiger Palm and Keg Smash. It shrinks as you regenerate and disappears once you can afford both." },
    { type = "color", key = "tigerColor", label = "Bar colour", default = { 1, 1, 1 }, dependsOn = "tiger" },
    { type = "header", text = "AoE helper" },
    { type = "toggle", key = "aoeHelper", label = "Grey Tiger Palm / Spinning Crane Kick by target count", default = false,
      desc = "In combat: greys Tiger Palm once Spinning Crane Kick does more damage for the enemies in range (use SCK), or greys Spinning Crane Kick below that (use Tiger Palm). The breakpoint is read from their tooltips and adjusts with your gear." },
}

function MonkBrewmaster:OnSettingChanged()
    local host = self:Host()
    host:_ScheduleUpdate()
    host:_ScheduleTiger()
    host:_RefreshAoETicker()  -- start/stop the combat AoE ticker for the new aoeHelper state
end

function MonkBrewmaster:Load()
    MonkBrewmaster.super.Load(self)   -- MonkBase:Load -- the shared Expel Harm marker
    local host = self:Host()
    local p = host:_p()

    -- install the player power(energy) bar learning hook once per session (global, can't
    -- be removed; the latch lives on the host singleton's private state)
    if not p.powerHookInstalled and type(UnitFrameManaBar_Update) == "function" then
        hooksecurefunc("UnitFrameManaBar_Update", function(statusbar, unit)
            if unit == "player" and statusbar.unitFrame == PlayerFrame then
                host:_p().powerBar = statusbar
                if not host:_p().tigerMarker then host:_ScheduleTiger() end
            end
        end)
        p.powerHookInstalled = true
    end

    p.tigerActive = true
    host:On("UNIT_MAXPOWER",        function(_, u) if u == "player" then host:_ScheduleTiger() end end, "spec")
    host:On("UNIT_DISPLAYPOWER",    function(_, u) if u == "player" then host:_ScheduleTiger() end end, "spec")
    host:On("TRAIT_CONFIG_UPDATED", function() host:_p().tigerCost = nil; host:_ScheduleTiger() end, "spec")
    host:On("PLAYER_LEVEL_UP",      function() host:_ScheduleTiger() end, "spec")
    host:_ScheduleTiger()
    host:_LoadAoE()

    -- The sphere count changes with no event of its own (orbs spawn/get absorbed as
    -- you move), so poll to keep the orb-count colour live. The poll STOPS when it's
    -- pointless -- out of combat with zero orbs left (new ones only spawn in combat) --
    -- and is kicked off again when combat starts, rather than spinning forever.
    host:On("PLAYER_REGEN_DISABLED", function() host:_StartOrbPoll() end, "spec")
    host:_StartOrbPoll()
end

function MonkBrewmaster:Unload()
    local host = self:Host()
    host:_UnloadAoE()
    local p = host:_p()
    p.orbPollGen = (p.orbPollGen or 0) + 1   -- retire the poll loop
    MonkBrewmaster.super.Unload(self)  -- MonkBase:Unload -- releases the "spec" scope (incl. tiger's)
    p.tigerActive = false
    if p.tigerMarker then p.tigerMarker:Hide() end
end

-- All of Base + the AoE helper (Range counts, ActionBars greying, Scheduler ticker).
ns.Monk.registerSpec("Monk-Brewmaster", MonkBrewmaster, 1, { "EventBus", "Cooldowns", "Secrets", "Range", "ActionBars", "Scheduler" })
