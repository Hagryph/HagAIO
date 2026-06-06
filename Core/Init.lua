local addonName, ns = ...
local Class = ns.Class

-- Core/Init.lua
-- The single Core initializer. It constructs every service singleton in
-- dependency order (replacing the old lazy `.Get()` accessors) and wires the
-- runtime startup sequence. Loaded after the UI layer but BEFORE the feature
-- modules, so the ModuleManager instance already exists when each module
-- registers itself at load time.
--
-- After this runs, each `ns.<Service>` IS the live instance (not the class), so
-- call sites use `ns.EventBus`, `ns.Logger`, ... directly — never `.Get()`.
--
-- Startup sequence (registered here, fired later by the game):
--   ADDON_LOADED(HagAIO) -> load saved vars, apply one-time defaults,
--                           load logger prefs, activate slash commands
--   PLAYER_LOGIN         -> start all registered modules, add compartment button
--   PLAYER_LOGOUT        -> shut down services + modules (cleanup before reload)
--
-- The single :Run() call at the end is the only top-level statement in the addon.

local Initializer = Class.new("Initializer")

function Initializer:Initialize()
    self:_p().started = false
end

-- Construct the service singletons in dependency order, replacing each class on
-- `ns` with its sole instance.
function Initializer:_BuildServices()
    ns.SavedVars         = ns.SavedVars:New()        -- no deps (binds globals later)
    ns.EventBus          = ns.EventBus:New()         -- no deps
    ns.Logger            = ns.Logger:New()           -- uses SavedVars/EventBus at runtime
    ns.ModuleManager     = ns.ModuleManager:New()    -- modules register into this at load
    ns.SlashCommand      = ns.SlashCommand:New()
    ns.Hooks             = ns.Hooks:New()           -- removable secure-hook service
    ns.ActionBars        = ns.ActionBars:New()      -- find/annotate action buttons
    ns.Range             = ns.Range:New()           -- enemies-in-range by yardage
    ns.Cooldowns         = ns.Cooldowns:New()       -- secret-safe cooldown watcher
    ns.EditMode          = ns.EditMode:New()
    ns.Compartment       = ns.Compartment:New()
    ns.MinimapIcon       = ns.MinimapIcon:New()
    ns.UI.SettingsWindow = ns.UI.SettingsWindow:New()

    -- Build-order list, walked in REVERSE on shutdown.
    self:_p().services = {
        ns.SavedVars, ns.EventBus, ns.Logger, ns.ModuleManager,
        ns.SlashCommand, ns.Hooks, ns.ActionBars, ns.Range, ns.Cooldowns,
        ns.EditMode, ns.Compartment, ns.MinimapIcon,
        ns.UI.SettingsWindow,
    }
end

-- PLAYER_LOGOUT fires on both /reload and a full logout/exit. Run each service's
-- optional :Shutdown() (and, via ModuleManager:Shutdown, each module's
-- OnShutdown) in reverse build order so cleanup happens before the services they
-- depend on. Guarded — a service/module without the hook is simply skipped.
function Initializer:_Shutdown()
    local services = self:_p().services or {}
    for i = #services, 1, -1 do
        local s = services[i]
        if s and s.Shutdown then pcall(function() s:Shutdown() end) end
    end
end

function Initializer:Run()
    local p = self:_p()
    if p.started then return end
    p.started = true

    self:_BuildServices()

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
        ns.Compartment:Register()
        ns.MinimapIcon:Refresh()
    end)

    bus:On("PLAYER_LOGOUT", function() self:_Shutdown() end)
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
