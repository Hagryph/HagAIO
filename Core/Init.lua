local addonName, ns = ...
local Class = ns.Class

-- Core/Init.lua
-- The single Core initializer. Services register themselves with the
-- ServiceManager as their files load; Run() then calls ServiceManager:StartAll(),
-- which orders them by their declared dependencies and runs each OnInitialize so
-- a service starts only after the services it depends on. After that each
-- `ns.<Service>` (and `ns.UI.<Window>`) IS the live instance, so call sites use
-- `ns.EventBus`, `ns.Logger`, ... directly.
--
-- Startup sequence (registered here, fired later by the game):
--   <load>               -> ServiceManager:StartAll() boots every service
--   ADDON_LOADED(HagAIO) -> load saved vars, apply one-time defaults,
--                           load logger prefs, activate slash commands
--   PLAYER_LOGIN         -> start all registered modules, add compartment button
--   PLAYER_LOGOUT        -> shut down modules then services (cleanup before reload)
--
-- The single :Run() call at the end is the only top-level statement in the addon.

local Initializer = Class.new("Initializer")

function Initializer:Initialize()
    self:_p().started = false
end

function Initializer:Run()
    local p = self:_p()
    if p.started then return end
    p.started = true

    -- One call boots the whole service layer: the ServiceManager orders every
    -- registered service by its declared dependencies and runs OnInitialize so
    -- each one starts only after the services it depends on are loaded.
    ns.ServiceManager:StartAll()

    local bus = ns.EventBus

    bus:On("ADDON_LOADED", function(_, loaded)
        if loaded ~= addonName then return end
        local sv = ns.SavedVars
        sv:Load()
        self:_ApplyDefaults(sv)
        ns.Logger:LoadSettings()
        ns.SlashCommand:Activate()
        ns.Logger:Core():Info(
            ("loaded v%s - type /hag to open."):format(tostring(ns.version)))
    end)

    bus:On("PLAYER_LOGIN", function()
        ns.ModuleManager:StartAll()
        ns.SubmoduleManager:StartAll()   -- after modules: load condition-gated submodules
        ns.Compartment:Register()
        ns.MinimapIcon:Refresh()
    end)

    -- PLAYER_LOGOUT fires on /reload and full exit. Shut modules down first (they
    -- depend on services), then the service layer in reverse dependency order.
    bus:On("PLAYER_LOGOUT", function()
        ns.ModuleManager:Shutdown()
        ns.ServiceManager:ShutdownAll()
    end)
end

-- One-time: start with everything off except the XP-bar tooltip. Runs once
-- (flagged), so any later changes the player makes are kept.
function Initializer:_ApplyDefaults(sv)
    local meta = sv:Namespace("_meta", { defaultsV1 = false })
    if meta.defaultsV1 then return end
    meta.defaultsV1 = true

    sv:SetModuleState("Questing", true)     -- keep on (hosts the XP tooltip)
    sv:SetModuleState("UnitFrames", false)
    sv:SetModuleState("Class", false)

    local q = sv:Namespace("module_Questing", {})
    q.autoAccept = false
    q.autoTurnIn = false
end

ns.Initializer = Initializer

-- Single entry point — the only top-level call in the addon.
Initializer:New():Run()
