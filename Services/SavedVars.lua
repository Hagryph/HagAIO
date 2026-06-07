local addonName, ns = ...
local Class = ns.Class

-- Services/SavedVars.lua
-- Singleton wrapper around the global + per-character saved-variable tables
-- declared in the .toc. Hands modules a namespaced, default-merged sub-table
-- so persistence is uniform and collision-free.
--
-- SCHEMA MIGRATIONS: applyDefaults can only ADD new keys; it can't rename, remove,
-- or reshape existing saved data. When a setting changes shape across versions,
-- bump SCHEMA_VERSION and add a MIGRATIONS[version] = function(global, char) that
-- transforms the stored tables in place. Migrate() runs the pending ones ONCE per
-- DB (sequentially, lowest-first) on load, before any module binds its namespace,
-- so modules always see current-shape data and stale keys never linger.
--
--   local MIGRATIONS = {
--       [2] = function(global, char)
--           local q = global.module_Questing
--           if q and q.autoAcceptAll ~= nil then        -- renamed autoAcceptAll -> autoAccept
--               q.autoAccept = q.autoAccept or q.autoAcceptAll
--               q.autoAcceptAll = nil
--           end
--       end,
--   }

local SavedVars = Class.new("SavedVars", ns.Service)

-- Current saved-vars schema version. Bump by 1 whenever you add a MIGRATIONS entry.
local SCHEMA_VERSION = 1
-- [version] = function(global, char): transform the DB from version-1 up to version.
local MIGRATIONS = {}

-- Recursively seed missing keys from `defaults` without clobbering saved data.
local function applyDefaults(target, defaults)
    if type(defaults) ~= "table" then return target end
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            target[k] = applyDefaults(target[k] or {}, v)
        elseif target[k] == nil then
            target[k] = v
        end
    end
    return target
end

function SavedVars:OnInitialize()
    self:_p().loaded = false
end

-- Bind the global tables. Call once SavedVariables are available
-- (i.e. after our ADDON_LOADED fires).
function SavedVars:Load()
    local p = self:_p()
    p.fresh = (HagAIODB == nil)   -- brand-new install (no DB to migrate)
    HagAIODB = HagAIODB or {}
    HagAIOCharDB = HagAIOCharDB or {}
    p.global = HagAIODB
    p.char = HagAIOCharDB
    p.global.modules = p.global.modules or {}  -- name -> bool enable state
    p.char.modules = p.char.modules or {}      -- per-character enable state
    p.loaded = true
end

-- Shared migration core: run pending MIGRATIONS over a global-shaped table `g`
-- (with `char` as its per-character half). Caller seeds g._schema first. A failing
-- migration is logged and stops the run, leaving _schema at the last good version.
local function runMigrations(g, char)
    local from = g._schema or 1
    if from >= SCHEMA_VERSION then
        g._schema = SCHEMA_VERSION
        return true
    end
    for v = from + 1, SCHEMA_VERSION do
        local fn = MIGRATIONS[v]
        if fn then
            local ok, err = pcall(fn, g, char)
            if not ok then
                ns.Logger:Core():Error(("saved-vars migration to v%d failed: %s"):format(v, tostring(err)))
                return false  -- leave _schema at the last good version; retry next time
            end
            ns.Logger:Core():Info(("saved-vars migrated to v%d"):format(v))
        end
        g._schema = v
    end
    return true
end

-- Apply any pending schema migrations to the LIVE DB. Call ONCE right after Load(),
-- before modules bind. A fresh install jumps straight to the current version (nothing
-- to migrate); an existing pre-versioning DB is treated as v1 and upgraded.
function SavedVars:Migrate()
    local p = self:_p()
    assert(p.loaded, "SavedVars:Migrate called before Load()")
    local g = p.global
    if g._schema == nil then g._schema = p.fresh and SCHEMA_VERSION or 1 end
    runMigrations(g, p.char)
end

-- Bring an arbitrary global-shaped table (e.g. an imported profile snapshot) up to
-- the current schema using the same MIGRATIONS, so an older shared profile upgrades
-- cleanly on import. A table with no _schema is treated as v1.
function SavedVars:MigrateTable(tbl)
    if type(tbl) ~= "table" then return tbl end
    if tbl._schema == nil then tbl._schema = 1 end
    runMigrations(tbl, tbl)   -- a profile has no separate per-character half
    return tbl
end

-- The account-wide saved table (used by the Profiles service to snapshot config).
function SavedVars:Global() return self:_p().global end

function SavedVars:IsLoaded()
    return self:_p().loaded
end

-- Pick the global or per-character root table.
function SavedVars:_Root(perChar)
    local p = self:_p()
    return perChar and p.char or p.global
end

-- Per-module sub-table, seeded with `defaults`. Pass perChar=true to store it
-- per character instead of account-wide.
function SavedVars:Namespace(key, defaults, perChar)
    local p = self:_p()
    assert(p.loaded, "SavedVars:Namespace called before Load()")
    local root = self:_Root(perChar)
    root[key] = applyDefaults(root[key] or {}, defaults or {})
    return root[key]
end

function SavedVars:GetModuleState(name, perChar)
    return self:_Root(perChar).modules[name]
end

function SavedVars:SetModuleState(name, enabled, perChar)
    self:_Root(perChar).modules[name] = enabled and true or false
end

ns.ServiceManager:Register(SavedVars:New("SavedVars"))
