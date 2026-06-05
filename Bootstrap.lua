local addonName, ns = ...
local Class = ns.Class

-- Bootstrap.lua
-- Startup orchestrator. Kept as a singleton class so no orchestration logic
-- lives as loose procedural code; the only top-level statement in the entire
-- addon is the single :Run() call at the end of this file.
--
-- Startup sequence:
--   ADDON_LOADED(HagAIO) -> load saved vars, activate slash cmds, build config
--   PLAYER_LOGIN         -> start all registered feature modules

local Bootstrap = Class.new("Bootstrap")
local instance

function Bootstrap:Initialize()
    self:_p().started = false
end

function Bootstrap:Run()
    local p = self:_p()
    if p.started then return end
    p.started = true

    local bus = ns.EventBus.Get()

    bus:On("ADDON_LOADED", function(_, loaded)
        if loaded ~= addonName then return end
        ns.SavedVars.Get():Load()
        ns.Logger.Get():LoadSettings()
        ns.SlashCommand.Get():Activate()
        ns.Logger.Get():Core():Info(
            ("loaded v%s — type /hag to open."):format(tostring(ns.version)))
    end)

    bus:On("PLAYER_LOGIN", function()
        ns.ModuleManager.Get():StartAll()
    end)
end

function Bootstrap.Get()
    if not instance then instance = Bootstrap:New() end
    return instance
end

ns.Bootstrap = Bootstrap

-- Single entry point — the only top-level call in the addon.
Bootstrap.Get():Run()
