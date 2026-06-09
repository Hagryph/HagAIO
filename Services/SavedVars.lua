local addonName, ns = ...
local Class = ns.Class

-- Services/SavedVars.lua
-- Singleton over the account (HagAIODB) + per-character (HagAIOCharDB) saved tables.
--
-- SETTINGS are a 3-LAYER CASCADE, so we only ever store what actually differs from the layer
-- beneath it (small saves, and a changed code default or profile value flows through to every
-- character that hasn't overridden it):
--     character override   (HagAIOCharDB.overrides[ns][key]) -- what THIS char changed
--       └ loaded profile   (HagAIODB.profiles[name][ns][key]) -- what the profile changed
--           └ code default (the schema's `default`, registered at bind)            -- the baseline
-- GetSetting walks override -> profile -> default; SetSetting writes an override ONLY if the new
-- value differs from (profile ?? default), and drops the override when it matches again. Each
-- character records which profile is loaded (char.loadedProfile -- the global profile is written
-- here verbatim when auto-applied), so the middle layer is resolved LIVE by name, never copied:
-- editing a profile updates every character using it.
--
-- DATA (flight routes, learned timed quests, the dashboard, the saved-profiles map) is NOT a
-- cascade -- it's stored directly via :Namespace(key, defaults, perChar) in the account or char
-- root, exactly as before.
--
-- SCHEMA MIGRATIONS: bump SCHEMA_VERSION and add a MIGRATIONS[version] = function(global, char)
-- to reshape stored data. Migrate() runs the pending ones once per DB on load, before binds.

local SavedVars = Class.new("SavedVars", ns.Service)

-- Bump by 1 whenever you add a MIGRATIONS entry.
local SCHEMA_VERSION = 2
-- [version] = function(global, char): transform the DB from version-1 up to version.
local MIGRATIONS = {
    -- v2: settings + enable state became a per-character override/diff layer (overrides[ns]) on
    -- top of the loaded profile and code defaults. The old flat enable maps are obsolete; drop
    -- them. Old per-character settings simply re-default under the override model (their data
    -- namespaces are untouched), and old full-snapshot profiles still load (they just carry keys
    -- equal to default until re-saved as diffs).
    [2] = function(global, char)
        global.modules = nil
        char.modules = nil
        char.profiles = nil   -- old per-char "loaded profile" marker -> char.loadedProfile
    end,
}

local function deepcopy(v) return ns.Helpers.DeepCopy(v) end
-- Structural equality (handles the small tables settings use, e.g. {r,g,b} colours).
local function deepEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do if not deepEqual(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

-- Recursively seed missing keys from `defaults` without clobbering saved data (DATA namespaces).
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

-- Bind the global tables. Call once SavedVariables are available (after ADDON_LOADED).
function SavedVars:Load()
    local p = self:_p()
    p.fresh = (HagAIODB == nil)   -- brand-new install (no DB to migrate)
    HagAIODB = HagAIODB or {}
    HagAIOCharDB = HagAIOCharDB or {}
    p.global = HagAIODB
    p.char = HagAIOCharDB
    p.global.profiles = p.global.profiles or {}   -- name -> { ns -> { key -> diff } }
    p.char.overrides = p.char.overrides or {}      -- ns -> { key -> this char's change }
    -- Session-only (rebuilt each load from the code, never saved):
    p.defaults = {}   -- ns -> code-default table (registered as each owner binds)
    p.views = {}      -- ns -> cached proxy view
    p.loaded = true
end

-- ---- migrations -----------------------------------------------------------
function SavedVars:_RunMigrations(g, char, migs, version)
    local from = g._schema or 1
    if from >= version then
        g._schema = version
        return true
    end
    for v = from + 1, version do
        local fn = migs[v]
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

function SavedVars:Migrate()
    local p = self:_p()
    assert(p.loaded, "SavedVars:Migrate called before Load()")
    local g = p.global
    if g._schema == nil then g._schema = p.fresh and SCHEMA_VERSION or 1 end
    self:_RunMigrations(g, p.char, MIGRATIONS, SCHEMA_VERSION)
end

-- Bring an arbitrary profile-shaped table (an imported profile) up to the current schema.
function SavedVars:MigrateTable(tbl)
    if type(tbl) ~= "table" then return tbl end
    if tbl._schema == nil then tbl._schema = 1 end
    self:_RunMigrations(tbl, tbl, MIGRATIONS, SCHEMA_VERSION)
    return tbl
end

-- ---- roots + DATA namespaces (non-cascade) --------------------------------
-- The account-wide saved table: persistent cross-character DATA + the saved-profiles map.
function SavedVars:Global() return self:_p().global end
-- The per-character saved table: this char's override layer + per-char DATA.
function SavedVars:Char() return self:_p().char end
function SavedVars:IsLoaded() return self:_p().loaded end

-- A DATA sub-table seeded with `defaults` (account-wide, or per-character with perChar=true).
-- This is NOT settings -- no cascade, no diffing; the stored table holds the live values.
function SavedVars:Namespace(key, defaults, perChar)
    local p = self:_p()
    assert(p.loaded, "SavedVars:Namespace called before Load()")
    local root = perChar and p.char or p.global
    root[key] = applyDefaults(root[key] or {}, defaults or {})
    return root[key]
end

-- ---- settings cascade -----------------------------------------------------
-- The profile data the current character has loaded (the middle layer), or nil.
function SavedVars:_ActiveProfile()
    local p = self:_p()
    local name = p.char.loadedProfile
    return name and p.global.profiles[name] or nil
end

-- What `key` would resolve to WITHOUT this character's override: profile ?? code default.
function SavedVars:_Baseline(nsKey, key)
    local prof = self:_ActiveProfile()
    local pd = prof and prof[nsKey]
    if pd ~= nil and pd[key] ~= nil then return pd[key] end
    local d = self:_p().defaults[nsKey]
    return d and d[key]
end

-- Resolve a setting: this char's override ?? loaded profile ?? code default.
function SavedVars:GetSetting(nsKey, key)
    local ov = self:_p().char.overrides[nsKey]
    if ov ~= nil and ov[key] ~= nil then return ov[key] end
    return self:_Baseline(nsKey, key)
end

-- Write a setting as a DIFF: store an override only when it differs from the baseline
-- (profile ?? default); if it matches the baseline, drop the override so the lower layer shows.
function SavedVars:SetSetting(nsKey, key, value)
    local p = self:_p()
    local ov = p.char.overrides[nsKey]
    if deepEqual(value, self:_Baseline(nsKey, key)) then
        if ov then
            ov[key] = nil
            if next(ov) == nil then p.char.overrides[nsKey] = nil end
        end
    else
        if not ov then ov = {}; p.char.overrides[nsKey] = ov end
        ov[key] = (type(value) == "table") and deepcopy(value) or value
    end
end

-- Register a settings namespace's code defaults (the baseline layer) and return a cached PROXY:
-- reads cascade, writes diff. Owners hold this proxy as their settings DB.
function SavedVars:SettingsView(nsKey, defaults)
    local p = self:_p()
    if defaults ~= nil then p.defaults[nsKey] = defaults end
    local view = p.views[nsKey]
    if not view then
        local sv = self
        view = setmetatable({}, {
            __index    = function(_, k)    return sv:GetSetting(nsKey, k) end,
            __newindex = function(_, k, v) sv:SetSetting(nsKey, k, v) end,
        })
        p.views[nsKey] = view
    end
    return view
end

-- ---- module enable state (the "modules" settings namespace) ----------------
-- Enable state cascades exactly like a setting: each module registers its `defaultEnabled`
-- as the baseline, so override ?? profile ?? defaultEnabled, and a change is diffed.
function SavedVars:RegisterModuleDefault(name, defaultEnabled)
    local p = self:_p()
    p.defaults.modules = p.defaults.modules or {}
    p.defaults.modules[name] = defaultEnabled and true or false
end
function SavedVars:GetModuleState(name) return self:GetSetting("modules", name) end
function SavedVars:SetModuleState(name, enabled) self:SetSetting("modules", name, enabled and true or false) end

-- ---- profile pointer + override management (for the Profiles service) ------
function SavedVars:LoadedProfile() return self:_p().char.loadedProfile end
function SavedVars:SetLoadedProfile(name) self:_p().char.loadedProfile = name end
-- Wipe THIS character's whole override layer (used by "load profile": everything then falls
-- through to the loaded profile and code defaults).
function SavedVars:ClearOverrides()
    local c = self:_p().char
    for k in pairs(c.overrides) do c.overrides[k] = nil end
end

-- Build a profile = the current effective config as DIFFS from code default, across every
-- registered settings namespace (modules/editmode/module_*/submodule_*). Stamped with the
-- schema version so it migrates cleanly when shared to another character.
function SavedVars:SnapshotDiffs()
    local p = self:_p()
    local prof = self:_ActiveProfile()
    local nsSet = {}
    for nsKey in pairs(p.defaults)       do nsSet[nsKey] = true end
    for nsKey in pairs(p.char.overrides) do nsSet[nsKey] = true end
    if prof then for nsKey in pairs(prof) do if nsKey ~= "_schema" then nsSet[nsKey] = true end end end

    local out = { _schema = p.global._schema }
    for nsKey in pairs(nsSet) do
        local d  = p.defaults[nsKey] or {}
        local ov = p.char.overrides[nsKey]
        local pd = prof and prof[nsKey]
        local keys = {}
        for k in pairs(d)  do keys[k] = true end
        if ov then for k in pairs(ov) do keys[k] = true end end
        if pd then for k in pairs(pd) do keys[k] = true end end
        local nsOut
        for k in pairs(keys) do
            local eff = self:GetSetting(nsKey, k)
            if not deepEqual(eff, d[k]) then
                nsOut = nsOut or {}
                nsOut[k] = (type(eff) == "table") and deepcopy(eff) or eff
            end
        end
        if nsOut then out[nsKey] = nsOut end
    end
    return out
end

ns.ServiceManager:Register(SavedVars:New("SavedVars"))
