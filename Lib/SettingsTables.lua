local addonName, ns = ...
local Class = ns.Class

-- Lib/SettingsTables.lua
-- Expresses the addon's SETTINGS as ordinary Database tables and resolves the
--   this-character override  ->  loaded profile  ->  code default
-- cascade by querying them. It owns NO settings storage of its own: the rows live in the shared
-- Database; this just (1) derives a table pair from a settings schema, (2) reads/writes a value across
-- the layers, and (3) keeps a small registry of namespaces so the Profiles service can walk every
-- owner. The Database ENGINE knows nothing about settings -- these are plain tables like any other.
--
-- Per settings namespace <ns> (e.g. "module_Questing") there are two tables, names sanitised from <ns>:
--   o_<ns>  CHAR   -- this character's OVERRIDES: one row (id = 1); an absent/NULL column = "not overridden"
--   p_<ns>  GLOBAL -- each profile's values: one row per profile name (FK -> profile.name, cascade delete)
-- The code DEFAULT (from the schema) is the bottom layer and is never stored. A column is NULL exactly
-- when that layer leaves the key alone, so the lower layer shows through.
--
-- The DB forbids table cells (Core/DB/Types.lua), so a value maps to typed scalar COLUMNS:
--   toggle -> <key> boolean   select/input -> <key> text   number/slider/range -> <key> number
--   color  -> <key>_r, <key>_g, <key>_b number

local function isSet(v) return v ~= nil and not ns.DB.isNull(v) end

-- Structural equality (handles the small tables settings use, e.g. {r,g,b} colours).
local function deepEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do if not deepEqual(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

-- Map a settings-schema entry to its persisted COLUMNS + how to read it from / write it to a row.
local function fieldFor(e)
    local key, t = e.key, e.type
    if t == "toggle" then
        return { cols = { { name = key, type = "boolean" } },
                 read  = function(row) local v = row[key]; if isSet(v) then return v end end,
                 write = function(v)   return { [key] = v and true or false } end }
    elseif t == "select" or t == "input" then
        return { cols = { { name = key, type = "text" } },
                 read  = function(row) local v = row[key]; if isSet(v) then return v end end,
                 write = function(v)   return { [key] = v } end }
    elseif t == "number" or t == "slider" or t == "range" then
        return { cols = { { name = key, type = "number" } },
                 read  = function(row) local v = row[key]; if isSet(v) then return v end end,
                 write = function(v)   return { [key] = v } end }
    elseif t == "color" then
        local r, g, b = key .. "_r", key .. "_g", key .. "_b"
        return { cols = { { name = r, type = "number" }, { name = g, type = "number" }, { name = b, type = "number" } },
                 read  = function(row) if isSet(row[r]) then return { row[r], row[g], row[b] } end end,
                 write = function(v)   return { [r] = v[1], [g] = v[2], [b] = v[3] } end }
    end
end

-- Ordered field list for a schema (cached by schema identity), plus a key -> field index.
local fieldsCache = setmetatable({}, { __mode = "k" })
local function schemaFields(schema)
    local fs = fieldsCache[schema]
    if not fs then
        fs = { byKey = {} }
        for _, e in ipairs(schema or {}) do
            if e.key ~= nil then
                local f = fieldFor(e)
                if f then f.key = e.key; f.default = e.default; fs[#fs + 1] = f; fs.byKey[e.key] = f end
            end
        end
        fieldsCache[schema] = fs
    end
    return fs
end

local function sanitize(nsKey) return (nsKey:gsub("[^%w_]", "_")) end
local function oName(nsKey) return "o_" .. sanitize(nsKey) end
local function pName(nsKey) return "p_" .. sanitize(nsKey) end

-- The char-override row (id = 1), or the profile-<name> row, for <ns>; nil if absent.
local function charRow(db, nsKey)
    return db:Select("*"):From(oName(nsKey)):Where("id", "=", 1):Limit(1):Run()[1]
end
local function profRow(db, nsKey, name)
    return db:Select("*"):From(pName(nsKey)):Where("profile", "=", name):Limit(1):Run()[1]
end

local SettingsTables = Class.new("SettingsTables", ns.Lib)

function SettingsTables:Initialize(name)
    ns.Lib.Initialize(self, name)
    local p = self:_p()
    p.namespaces = {}   -- list of { ns = <key>, schema = <schema> }
    p.seen = {}         -- ns -> true (registration is idempotent)
end

-- ---- namespace registry ---------------------------------------------------
-- Record a settings namespace so Profiles can walk every owner without enumerating them by hand.
-- Idempotent; a namespace that persists nothing (header/note only) is ignored.
function SettingsTables:Register(nsKey, schema)
    local p = self:_p()
    if p.seen[nsKey] or #schemaFields(schema) == 0 then return end
    p.seen[nsKey] = true
    p.namespaces[#p.namespaces + 1] = { ns = nsKey, schema = schema }
end

function SettingsTables:Namespaces()       return self:_p().namespaces end
function SettingsTables:CharTable(nsKey)    return oName(nsKey) end
function SettingsTables:ProfileTable(nsKey) return pName(nsKey) end

-- The code default for `key` (used before the database is built, and as the cascade's bottom layer).
function SettingsTables.SchemaDefault(schema, key)
    local f = schemaFields(schema).byKey[key]
    return f and f.default
end

-- ---- table derivation -----------------------------------------------------
-- The two tables backing namespace <ns>: o_<ns> (CHAR override, one row id=1) and p_<ns> (GLOBAL,
-- one row per profile, FK -> profile.name cascade). Empty when the schema persists nothing.
function SettingsTables:DeriveTables(nsKey, schema)
    local fs = schemaFields(schema)
    if #fs == 0 then return {} end
    local oCols = { { name = "id", type = "integer", primaryKey = true } }
    local pCols = { { name = "profile", type = "text", primaryKey = true,
                      references = { table = "profile", column = "name", onDelete = "cascade" } } }
    for _, f in ipairs(fs) do
        for _, c in ipairs(f.cols) do
            oCols[#oCols + 1] = { name = c.name, type = c.type }   -- nullable by default
            pCols[#pCols + 1] = { name = c.name, type = c.type }
        end
    end
    local out = {}
    out[oName(nsKey)] = { scope = "char",   columns = oCols }
    out[pName(nsKey)] = { scope = "global", columns = pCols }
    return out
end

-- ---- the loaded-profile pointer (the central `config` row) ----------------
function SettingsTables:LoadedProfile(db)
    local r = db:Select("loaded_profile"):From("config"):Where("id", "=", 1):Limit(1):Run()[1]
    local v = r and r.loaded_profile
    if isSet(v) then return v end
end

function SettingsTables:SetLoadedProfile(db, name)
    local v = (name == nil) and ns.DB.NULL or name
    if db:Select("id"):From("config"):Where("id", "=", 1):Limit(1):Run()[1] then
        db:Update("config", { loaded_profile = v }, function(r) return r.id == 1 end)
    elseif name ~= nil then
        db:Insert("config", { id = 1, loaded_profile = name })
    end
end

-- ---- settings read / write (the cascade) ----------------------------------
-- Effective value: char override ?? loaded profile ?? code default.
function SettingsTables:Get(db, nsKey, schema, key)
    local f = schemaFields(schema).byKey[key]
    if not f then return nil end
    local orow = charRow(db, nsKey)
    if orow then local v = f.read(orow); if v ~= nil then return v end end
    local loaded = self:LoadedProfile(db)
    if loaded then
        local prow = profRow(db, nsKey, loaded)
        if prow then local v = f.read(prow); if v ~= nil then return v end end
    end
    return f.default
end

-- What `key` resolves to WITHOUT this char's override: loaded profile ?? code default.
function SettingsTables:Baseline(db, nsKey, schema, key)
    local f = schemaFields(schema).byKey[key]
    if not f then return nil end
    local loaded = self:LoadedProfile(db)
    if loaded then
        local prow = profRow(db, nsKey, loaded)
        if prow then local v = f.read(prow); if v ~= nil then return v end end
    end
    return f.default
end

-- Write `value` to this char's override layer, DIFFING against the baseline: store it only when it
-- differs (so a later default/profile change still flows through), else clear the override columns.
function SettingsTables:Set(db, nsKey, schema, key, value)
    local f = schemaFields(schema).byKey[key]
    if not f then return end
    local t = oName(nsKey)
    local exists = charRow(db, nsKey) ~= nil
    if deepEqual(value, self:Baseline(db, nsKey, schema, key)) then
        if not exists then return end
        local clear = {}; for _, c in ipairs(f.cols) do clear[c.name] = ns.DB.NULL end
        db:Update(t, clear, function(r) return r.id == 1 end)
    else
        local cols = f.write(value)
        if exists then db:Update(t, cols, function(r) return r.id == 1 end)
        else cols.id = 1; db:Insert(t, cols) end
    end
end

-- Wipe this character's override row for <ns> (used by "load profile" so the cascade falls through).
function SettingsTables:ClearChar(db, nsKey)
    db:Truncate(oName(nsKey))
end

-- ---- profile snapshot / read / write (for the Profiles service) -----------
-- Snapshot this char's EFFECTIVE config for <ns> as diffs-from-default into profile `name`'s row.
function SettingsTables:SnapshotInto(db, nsKey, schema, name)
    local fs = schemaFields(schema)
    local cols, any = {}, false
    for _, f in ipairs(fs) do
        local v = self:Get(db, nsKey, schema, f.key)
        if v ~= nil and not deepEqual(v, f.default) then
            for k, val in pairs(f.write(v)) do cols[k] = val end; any = true
        else
            for _, c in ipairs(f.cols) do cols[c.name] = ns.DB.NULL end
        end
    end
    local t, exists = pName(nsKey), profRow(db, nsKey, name) ~= nil
    if any then
        if exists then db:Update(t, cols, function(r) return r.profile == name end)
        else cols.profile = name; db:Insert(t, cols) end
    elseif exists then
        db:Delete(t, function(r) return r.profile == name end)   -- profile leaves <ns> entirely at defaults
    end
end

-- This char's EFFECTIVE config for <ns> as { key = value }, only where it differs from the default
-- (nil if it's all default) -- used to export the current config without saving a profile first.
function SettingsTables:EffectiveDiffs(db, nsKey, schema)
    local out
    for _, f in ipairs(schemaFields(schema)) do
        local v = self:Get(db, nsKey, schema, f.key)
        if v ~= nil and not deepEqual(v, f.default) then out = out or {}; out[f.key] = v end
    end
    return out
end

-- A profile's stored values for <ns> as { key = value } (nil if it touches none) -- for export.
function SettingsTables:ReadProfile(db, nsKey, schema, name)
    local prow = profRow(db, nsKey, name)
    if not prow then return nil end
    local out = {}
    for _, f in ipairs(schemaFields(schema)) do
        local v = f.read(prow)
        if v ~= nil then out[f.key] = v end
    end
    if next(out) then return out end
end

-- Write a { key = value } map into profile `name`'s row for <ns> (used by import).
function SettingsTables:WriteProfileValues(db, nsKey, schema, name, values)
    local cols = {}
    for _, f in ipairs(schemaFields(schema)) do
        local v = values and values[f.key]
        if v ~= nil then for k, val in pairs(f.write(v)) do cols[k] = val end end
    end
    if not next(cols) then return end
    if profRow(db, nsKey, name) then db:Update(pName(nsKey), cols, function(r) return r.profile == name end)
    else cols.profile = name; db:Insert(pName(nsKey), cols) end
end

-- ---- module enable-state (the central module_enable / profile_module_enable tables) ------------
function SettingsTables:_EnableBaseline(db, name, default)
    local loaded = self:LoadedProfile(db)
    if loaded then
        local pr = db:Select("enabled"):From("profile_module_enable")
            :Where("profile", "=", loaded):AndWhere("name", "=", name):Limit(1):Run()[1]
        if pr and isSet(pr.enabled) then return pr.enabled end
    end
    return default and true or false
end

-- Effective enabled: char override ?? loaded profile ?? registered default.
function SettingsTables:GetModuleEnabled(db, name, default)
    local r = db:Select("enabled"):From("module_enable"):Where("name", "=", name):Limit(1):Run()[1]
    if r and isSet(r.enabled) then return r.enabled end
    return self:_EnableBaseline(db, name, default)
end

-- Diff-on-write the enable override against the baseline (loaded profile ?? default).
function SettingsTables:SetModuleEnabled(db, name, enabled, default)
    enabled = enabled and true or false
    local exists = db:Select("name"):From("module_enable"):Where("name", "=", name):Limit(1):Run()[1] ~= nil
    if enabled == self:_EnableBaseline(db, name, default) then
        if exists then db:Delete("module_enable", function(r) return r.name == name end) end
    elseif exists then
        db:Update("module_enable", { enabled = enabled }, function(r) return r.name == name end)
    else
        db:Insert("module_enable", { name = name, enabled = enabled })
    end
end

ns.LibManager:Register(SettingsTables:New("SettingsTables"))
