local addonName, ns = ...
local Class = ns.Class

-- Services/SavedVars.lua
-- Singleton over the account (HagAIODB) + per-character (HagAIOCharDB) saved tables.
--
-- SETTINGS are held MATERIALISED in memory for the session, then written back as DIFFS:
--   * On login each settings namespace is built into `current[ns]` by layering
--         code default  <-  loaded profile  <-  this char's stored override
--     so `current` is the live effective config. GetSetting/SetSetting read/write `current`
--     DIRECTLY -- no per-access resolution.
--   * On logout (Flush, fired from PLAYER_LOGOUT, which also covers /reload) we diff `current`
--     against the baseline (profile ?? default) and write only the differences into
--     HagAIOCharDB.overrides -- so the char saves just what it changed, and a changed code
--     default or profile value still flows through to anything it didn't override.
--   * On Save/overwrite profile (SnapshotDiffs) we diff `current` against the code default and
--     store that into HagAIODB.profiles[name] -- the profile records only its changes.
-- Each character records which profile is loaded (char.loadedProfile -- the global profile is
-- written here verbatim when auto-applied); the profile is the middle layer, resolved by name.
--
-- DATA (flight routes, learned timed quests, the dashboard, the saved-profiles map) is NOT a
-- cascade -- it's stored directly via :Namespace(key, defaults, perChar), as before.
--
-- SCHEMA MIGRATIONS: bump SCHEMA_VERSION and add MIGRATIONS[version] = function(global, char).

local SavedVars = Class.new("SavedVars", ns.Service)

local SCHEMA_VERSION = 2
local MIGRATIONS = {
    -- v2: settings + enable state became a per-character override/diff layer (overrides[ns]) over
    -- the loaded profile and code defaults. Drop the obsolete flat enable maps + loaded marker.
    [2] = function(global, char)
        global.modules = nil
        char.modules = nil
        char.profiles = nil
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
local function copyVal(v) return (type(v) == "table") and deepcopy(v) or v end

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
    p.char.overrides = p.char.overrides or {}      -- ns -> { key -> this char's stored change }
    -- Session-only (rebuilt each load; never saved):
    p.defaults = {}   -- ns -> code-default table (registered as each owner binds)
    p.current  = {}   -- ns -> the live effective config for this session
    p.views    = {}   -- ns -> cached proxy view
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
                return false
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
function SavedVars:Global() return self:_p().global end
function SavedVars:Char() return self:_p().char end
function SavedVars:IsLoaded() return self:_p().loaded end

-- A DATA sub-table seeded with `defaults` (account-wide, or per-character with perChar=true).
function SavedVars:Namespace(key, defaults, perChar)
    local p = self:_p()
    assert(p.loaded, "SavedVars:Namespace called before Load()")
    local root = perChar and p.char or p.global
    root[key] = applyDefaults(root[key] or {}, defaults or {})
    return root[key]
end

-- ---- settings (materialised) ----------------------------------------------
-- The profile data the current character has loaded (the middle layer), or nil.
function SavedVars:_ActiveProfile()
    local p = self:_p()
    local name = p.char.loadedProfile
    return name and p.global.profiles[name] or nil
end

-- What `key` would be WITHOUT this char's override: loaded profile ?? code default.
function SavedVars:_Baseline(nsKey, key)
    local prof = self:_ActiveProfile()
    local pd = prof and prof[nsKey]
    if pd ~= nil and pd[key] ~= nil then return pd[key] end
    local d = self:_p().defaults[nsKey]
    return d and d[key]
end

-- (Re)build current[ns] by layering default <- profile <- stored override.
function SavedVars:_Materialize(nsKey)
    local p = self:_p()
    local cur = {}
    local d  = p.defaults[nsKey]
    local prof = self:_ActiveProfile()
    local pd = prof and prof[nsKey]
    local ov = p.char.overrides[nsKey]
    if d  then for k, v in pairs(d)  do cur[k] = copyVal(v) end end
    if pd then for k, v in pairs(pd) do cur[k] = copyVal(v) end end
    if ov then for k, v in pairs(ov) do cur[k] = copyVal(v) end end
    p.current[nsKey] = cur
end

-- Rebuild every materialised namespace from the current profile pointer + stored overrides
-- (after a profile load / override wipe). Frames re-read on the /reload that follows.
function SavedVars:Rematerialize()
    local p = self:_p()
    for nsKey in pairs(p.defaults) do self:_Materialize(nsKey) end
end

-- Read straight from the live config.
function SavedVars:GetSetting(nsKey, key)
    local c = self:_p().current[nsKey]
    return c and c[key]
end

-- Write straight into the live config (no diffing here -- the diff happens in Flush/SnapshotDiffs).
function SavedVars:SetSetting(nsKey, key, value)
    local p = self:_p()
    local c = p.current[nsKey]
    if not c then c = {}; p.current[nsKey] = c end
    c[key] = copyVal(value)
end

-- Register a settings namespace's code defaults, materialise it once, and return a cached PROXY
-- (reads/writes the live config). Owners hold this proxy as their settings DB.
function SavedVars:SettingsView(nsKey, defaults)
    local p = self:_p()
    local view = p.views[nsKey]
    if not view then
        p.defaults[nsKey] = defaults or {}
        self:_Materialize(nsKey)
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
-- Each module registers its defaultEnabled (the baseline). Materialise just that entry so it
-- doesn't disturb modules already enabled/disabled earlier in the start sequence.
function SavedVars:RegisterModuleDefault(name, defaultEnabled)
    local p = self:_p()
    p.defaults.modules = p.defaults.modules or {}
    p.defaults.modules[name] = defaultEnabled and true or false
    p.current.modules = p.current.modules or {}
    if p.current.modules[name] == nil then
        local v = p.defaults.modules[name]
        local prof = self:_ActiveProfile()
        if prof and prof.modules and prof.modules[name] ~= nil then v = prof.modules[name] end
        local ov = p.char.overrides.modules
        if ov and ov[name] ~= nil then v = ov[name] end
        p.current.modules[name] = v
    end
end
function SavedVars:GetModuleState(name) return self:GetSetting("modules", name) end
function SavedVars:SetModuleState(name, enabled) self:SetSetting("modules", name, enabled and true or false) end

-- ---- profile pointer + persistence (for the Profiles service + logout) -----
function SavedVars:LoadedProfile() return self:_p().char.loadedProfile end
function SavedVars:SetLoadedProfile(name) self:_p().char.loadedProfile = name end

-- Wipe THIS character's whole stored override layer (used by "load profile"). The caller
-- re-materialises so the live config falls through to the loaded profile + code defaults.
function SavedVars:ClearOverrides()
    local c = self:_p().char.overrides
    for k in pairs(c) do c[k] = nil end
end

-- Write the session's live config back to this character's override layer as diffs from the
-- baseline (profile ?? default). Only materialised keys are rewritten, so override entries for
-- namespaces/modules not loaded this session are preserved untouched.
function SavedVars:Flush()
    local p = self:_p()
    if not p.loaded then return end
    for nsKey, c in pairs(p.current) do
        local ov = p.char.overrides[nsKey]
        for key, val in pairs(c) do
            if deepEqual(val, self:_Baseline(nsKey, key)) then
                if ov then ov[key] = nil end
            else
                if not ov then ov = {}; p.char.overrides[nsKey] = ov end
                ov[key] = copyVal(val)
            end
        end
        if ov and next(ov) == nil then p.char.overrides[nsKey] = nil end
    end
end

-- Build a profile = the live config as DIFFS from code default, across every materialised
-- namespace. Stamped with the schema version so it migrates cleanly when shared.
function SavedVars:SnapshotDiffs()
    local p = self:_p()
    local out = { _schema = p.global._schema }
    for nsKey, c in pairs(p.current) do
        local d = p.defaults[nsKey] or {}
        local nsOut
        for key, val in pairs(c) do
            if not deepEqual(val, d[key]) then
                nsOut = nsOut or {}
                nsOut[key] = copyVal(val)
            end
        end
        if nsOut then out[nsKey] = nsOut end
    end
    return out
end

ns.ServiceManager:Register(SavedVars:New("SavedVars"))
