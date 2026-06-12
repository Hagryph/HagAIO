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
--   ADDON_LOADED(HagAIO) -> bind saved vars + build the database, apply the global
--                           profile, load logger prefs, activate slash commands
--   PLAYER_LOGIN         -> start all registered modules + submodules
--                           (services that need login, e.g. Compartment/MinimapIcon,
--                            subscribe it themselves)
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

    -- Fail fast on a broken load order. The bootstrapper drives the registries and
    -- logs through these self-instantiating Core singletons; if any is missing, its
    -- Core file didn't load before Init.lua. Surface it loudly rather than dying
    -- later with a cryptic nil index.
    for _, name in ipairs({ "Logger", "ServiceManager", "ModuleManager", "SubmoduleManager" }) do
        if not ns[name] then
            error(("HagAIO: ns.%s is missing -- its Core file must load before Core/Init.lua (check the pinned order in tools/load-order.json)"):format(name), 0)
        end
    end

    -- One call boots the whole service layer: the ServiceManager orders every
    -- registered service by its declared dependencies and runs OnInitialize so
    -- each one starts only after the services it depends on are loaded.
    ns.ServiceManager:StartAll()

    local bus = ns.EventBus

    -- On a whitelisted dev character, surface DEBUG output in chat automatically
    -- (session-only). Deferred until the character identity is KNOWN -- at file-load /
    -- boot time the player unit may not exist yet (see ns.WhenDevCharKnown).
    ns.WhenDevCharKnown(function(isDev) if isDev then ns.Logger:SetDebug(true) end end)

    bus:On("ADDON_LOADED", function(_, loaded)
        if loaded ~= addonName then return end
        -- Soft dev-identity flush FIRST: a dev surface whose registration was deferred at
        -- file load (identity not ready) registers now, BEFORE the table-contribution
        -- sweep + Build below -- so its tables still make the schema.
        ns.ResolveDevChar()
        -- Bind the saved-variable globals (the SavedVars slot library), then build the ONE shared
        -- database, before anything reads it (Logger prefs just below; Compartment/MinimapIcon on their
        -- own PLAYER_LOGIN handlers). Every owner contributes its tables first -- services already did at
        -- StartAll, modules/submodules contribute here -- so the build sees the full schema.
        -- _ContributeTables is idempotent (the later _Init is a no-op).
        if ns.DatabaseManager then
            ns.DatabaseManager:LoadSaved()   -- bind the saved-variable globals (via the SavedVars library)
            -- Sweep EVERY registry (Registry.All -- the managers append themselves at
            -- construction), duck-typed on _ContributeTables, so a future owner-bearing
            -- registry contributes its tables without this list being edited.
            for _, reg in ipairs(ns.Registry.All()) do
                for it in reg:Iterate() do if it._ContributeTables then it:_ContributeTables() end end
            end
            ns.DatabaseManager:Build()
        end
        -- Settings, enable-state and profiles are ordinary database tables now (see Lib/SettingsTables.lua):
        -- each module's `defaultEnabled` and its schema `default`s are the cascade's bottom layer -- no
        -- seeding needed here. A character that has never loaded a profile picks up the account's global
        -- profile here -- before modules bind, so no /reload is needed.
        if ns.Profiles then ns.Profiles:ApplyGlobalForFreshChar() end
        ns.Logger:LoadSettings()
        ns.SlashCommand:Activate()
        ns.Logger:Core():EchoInfo(
            ("loaded v%s - type /hag to open."):format(tostring(ns.version)))
    end)

    bus:On("PLAYER_LOGIN", function()
        -- Forced dev-identity flush: the player unit is guaranteed now, so any deferred
        -- dev registration that ADDON_LOADED couldn't resolve lands here -- BEFORE
        -- StartAll, so it starts with everything else (late registration also works).
        ns.ResolveDevChar(true)
        ns.ModuleManager:StartAll()
        ns.SubmoduleManager:StartAll()   -- after modules: load condition-gated submodules
        -- (the shared database was already built on ADDON_LOADED, before any owner reads it)
        -- The Compartment / MinimapIcon services apply their own saved state on
        -- PLAYER_LOGIN (they subscribe it themselves) -- Init doesn't manage them.
    end)

    -- PLAYER_LOGOUT fires on /reload and full exit. Settings now persist immediately to the database
    -- as they change, so there's nothing to flush -- just shut modules down (they depend on services)
    -- then the service layer in reverse dependency order.
    bus:On("PLAYER_LOGOUT", function()
        ns.ModuleManager:Shutdown()
        ns.ServiceManager:ShutdownAll()
    end)
end

ns.Initializer = Initializer

-- Single entry point — the only top-level call in the addon.
Initializer:New():Run()
