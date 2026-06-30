local addonName, ns = ...
local Class = ns.Class

-- Core/DB/DatabaseManager.lua
-- Owns the ONE shared database. There is a single store with a single schema; every service or
-- module CONTRIBUTES the tables it needs (each table picks its own scope -- LOCAL in-memory /
-- GLOBAL account / CHAR per character), and common reference tables are predefined centrally in
-- ns.DB.CoreTables (faction, ...). One database means a fact like "faction" lives in exactly one
-- place that anything can join to -- no per-feature copies, no "which database owns it?".
--
-- Lifecycle: owners contribute during init (Contribute), then the database is BUILT once, after
-- all of them have registered (Init.lua calls Build on PLAYER_LOGIN, once saved variables exist).
-- Reach the live database via ns.DatabaseManager:Shared(), or self:DB() on a module/service, and
-- query its tables: self:DB():Select(...):From("faction"):Run().

ns.DB = ns.DB or {}
local DB = ns.DB

local DatabaseManager = Class.new("DatabaseManager", ns.Service)

local SCHEMA_VERSION = 1

function DatabaseManager:OnInitialize()
    local p = self:_p()
    p.contrib = {}        -- tableName -> table spec (the aggregated schema of the one database)
    p.shared = nil        -- the built Database
    p.built = false
    -- Predefined common/reference tables (defined centrally so any owner can join to them).
    for name, spec in pairs(DB.CoreTables or {}) do self:_Add(name, spec) end
end

function DatabaseManager:_Add(name, spec)
    local p = self:_p()
    if p.built then DB.fail("DatabaseManager:_Add", ("cannot add table '%s' after the database is built"):format(tostring(name))) end
    if p.contrib[name] then
        DB.fail("DatabaseManager:_Add", ("table '%s' is already defined (table names are shared across the one database)")
            :format(tostring(name)))
    end
    p.contrib[name] = spec
end

-- Contribute one or more table specs to the shared database. `tables` is a map name -> spec; each
-- spec is the usual table schema plus an optional `scope` (default GLOBAL) and `seed(db)`.
function DatabaseManager:Contribute(tables)
    for name, spec in pairs(tables or {}) do self:_Add(name, spec) end
end

-- Bind the saved-variable globals (the SavedVars slot library) so Build can carve its backing slots.
-- The Database engine is the sole user of ns.SavedVars; everyone else persists through the database.
-- Call on ADDON_LOADED, before Build. Idempotent.
function DatabaseManager:LoadSaved()
    ns.SavedVars:Load()
end

-- Build the single database from every contributed table. Idempotent (returns the existing one if
-- already built). Saved variables must be loaded.
function DatabaseManager:Build()
    local p = self:_p()
    if p.built then return p.shared end
    if not (ns.SavedVars and ns.SavedVars:IsLoaded()) then DB.fail("DatabaseManager:Build", "Build before SavedVars are loaded") end
    local schema = DB.Schema.new("HagAIO", { version = SCHEMA_VERSION, tables = p.contrib })
    p.shared = DB.Database:New("HagAIO", schema, {
        [DB.Scope.GLOBAL] = ns.SavedVars:DataSlot("db_global", false),
        [DB.Scope.CHAR]   = ns.SavedVars:DataSlot("db_char", true),
        -- LOCAL tables get a fresh in-memory backing automatically.
    })
    p.built = true
    DB.shared = p.shared
    return p.shared
end

function DatabaseManager:Shared()  return self:_p().shared end
function DatabaseManager:IsBuilt() return self:_p().built end
function DatabaseManager:HasTable(name) return self:_p().contrib[name] ~= nil end
function DatabaseManager:TableNames()
    local out = {}; for n in pairs(self:_p().contrib) do out[#out + 1] = n end; table.sort(out); return out
end

ns.ServiceManager:Register(DatabaseManager:New("DatabaseManager"))
