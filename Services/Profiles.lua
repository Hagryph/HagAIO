local addonName, ns = ...
local Class = ns.Class

-- Services/Profiles.lua
-- Named config profiles + copy-paste sharing, built ON THE DATABASE. A profile is a row in the
-- `profile` table; its values live in the per-namespace `p_*` tables plus `profile_module_enable`
-- and `profile_editmode` -- each FK'd to profile.name with cascade delete, so a profile and all its
-- values are one unit. A profile is NEVER copied onto a character: each character records which
-- profile it has LOADED (the `config` row), and that profile is resolved LIVE as the middle layer of
-- the cascade (override -> profile -> default; see Lib/SettingsTables.lua). So editing a profile
-- updates every character using it, and a value a profile didn't set falls through to the code default.
--
--   Save(name)    snapshot this character's current effective config (as diffs) into a profile.
--   LoadProfile   wipe this character's override rows and point it at the profile -> everything then
--                 resolves to the profile (and code defaults). Finalised with a /reload.
--   global profile  one profile may be flagged global (profile.is_global, exclusive); a character that
--                   has loaded none gets it pointed-to automatically on login.
-- Export serialises a profile's rows through ns.Serializer into a share string; Import decodes one
-- back into the profile tables. The UI (Settings -> Profiles) drives all of this.

local Profiles = Class.new("Profiles", ns.Service)

-- ---- registry (the `profile` table) ---------------------------------------
function Profiles:List()
    local out = {}
    for _, r in ipairs(self:DB():Select("name"):From("profile"):OrderBy("name"):Run()) do out[#out + 1] = r.name end
    return out
end

function Profiles:Has(name)
    return self:DB():Select("name"):From("profile"):Where("name", "=", name):Limit(1):Run()[1] ~= nil
end

function Profiles:_EnsureRow(name)
    if not self:Has(name) then self:DB():Insert("profile", { name = name }) end
end

-- A stored profile reconstructed as { <ns> = {key=value}, modules = {name=enabled}, editmode = {key={point,x,y}} },
-- or nil if it doesn't exist. Used by Export.
function Profiles:Get(name)
    local db = self:DB()
    if not self:Has(name) then return nil end
    local out = {}
    for _, e in ipairs(ns.SettingsTables:Namespaces()) do
        local vals = ns.SettingsTables:ReadProfile(db, e.ns, e.schema, name)
        if vals then out[e.ns] = vals end
    end
    local mods
    for _, r in ipairs(db:Select("name", "enabled"):From("profile_module_enable"):Where("profile", "=", name):Run()) do
        mods = mods or {}; mods[r.name] = r.enabled and true or false
    end
    if mods then out.modules = mods end
    local em
    for _, r in ipairs(db:Select("key", "point", "x", "y"):From("profile_editmode"):Where("profile", "=", name):Run()) do
        em = em or {}; em[r.key] = { point = r.point, x = r.x, y = r.y }
    end
    if em then out.editmode = em end
    return out
end

-- This character's CURRENT effective config as the same diff structure (for Export without saving).
function Profiles:_CurrentSnapshot()
    local db = self:DB()
    local out = {}
    for _, e in ipairs(ns.SettingsTables:Namespaces()) do
        local vals = ns.SettingsTables:EffectiveDiffs(db, e.ns, e.schema)
        if vals then out[e.ns] = vals end
    end
    local mods
    for m in ns.ModuleManager:Iterate() do
        if not m:IsAlwaysOn() then
            local enabled = ns.SettingsTables:GetModuleEnabled(db, m:GetName(), m:IsDefaultEnabled())
            if enabled ~= m:IsDefaultEnabled() then mods = mods or {}; mods[m:GetName()] = enabled end
        end
    end
    if mods then out.modules = mods end
    local em
    for _, r in ipairs(db:Select("key", "point", "x", "y"):From("editmode"):Run()) do
        em = em or {}; em[r.key] = { point = r.point, x = r.x, y = r.y }
    end
    if em then out.editmode = em end
    return out
end

-- ---- save / load / delete -------------------------------------------------
function Profiles:Save(name)
    if type(name) ~= "string" or name == "" then return false, "a profile name is required" end
    local db = self:DB()
    self:_EnsureRow(name)
    for _, e in ipairs(ns.SettingsTables:Namespaces()) do
        ns.SettingsTables:SnapshotInto(db, e.ns, e.schema, name)
    end
    db:Delete("profile_module_enable", function(r) return r.profile == name end)
    for m in ns.ModuleManager:Iterate() do
        if not m:IsAlwaysOn() then
            local enabled = ns.SettingsTables:GetModuleEnabled(db, m:GetName(), m:IsDefaultEnabled())
            if enabled ~= m:IsDefaultEnabled() then
                db:Insert("profile_module_enable", { profile = name, name = m:GetName(), enabled = enabled })
            end
        end
    end
    db:Delete("profile_editmode", function(r) return r.profile == name end)
    for _, r in ipairs(db:Select("key", "point", "x", "y"):From("editmode"):Run()) do
        db:Insert("profile_editmode", { profile = name, key = r.key, point = r.point, x = r.x, y = r.y })
    end
    return true
end

-- Load a profile into THIS character: point it at the profile and wipe its override rows, so the live
-- config resolves to the profile (+ defaults). Persists immediately; a /reload re-applies it to frames.
function Profiles:LoadProfile(name)
    local db = self:DB()
    if not self:Has(name) then return false, "no profile named '" .. tostring(name) .. "'" end
    ns.SettingsTables:SetLoadedProfile(db, name)
    for _, e in ipairs(ns.SettingsTables:Namespaces()) do ns.SettingsTables:ClearChar(db, e.ns) end
    db:Truncate("module_enable")
    db:Truncate("editmode")
    return true
end

function Profiles:Delete(name)
    local db = self:DB()
    if not self:Has(name) then return false, "no profile named '" .. tostring(name) .. "'" end
    db:Delete("profile", function(r) return r.name == name end)   -- FK cascade removes all its values + global flag
    if ns.SettingsTables:LoadedProfile(db) == name then ns.SettingsTables:SetLoadedProfile(db, nil) end
    return true
end

-- ---- global profile (exclusive flag on the registry) ----------------------
function Profiles:GetGlobal()
    local r = self:DB():Select("name"):From("profile"):Where("is_global", "=", true):Limit(1):Run()[1]
    return r and r.name
end

function Profiles:IsGlobal(name) return name ~= nil and self:GetGlobal() == name end

function Profiles:SetGlobal(name)
    local db = self:DB()
    db:Update("profile", { is_global = false }, function(r) return r.is_global == true end)   -- exclusive: clear any current
    if name == nil then return true end
    if not self:Has(name) then return false, "no profile named '" .. tostring(name) .. "'" end
    db:Update("profile", { is_global = true }, function(r) return r.name == name end)
    return true
end

function Profiles:GetLoaded() return ns.SettingsTables:LoadedProfile(self:DB()) end

-- On login, if this character has loaded no profile, point it at the account's global profile (if any).
function Profiles:ApplyGlobalForFreshChar()
    local db = self:DB()
    if ns.SettingsTables:LoadedProfile(db) then return nil end
    local name = self:GetGlobal()
    if not name then return nil end
    ns.SettingsTables:SetLoadedProfile(db, name)
    return name
end

-- ---- export / import ------------------------------------------------------
-- A profile is a map of (namespace | "modules" | "editmode") -> table. Require at least one
-- string-keyed table entry so a decoded blob of garbage is rejected before it can be stored.
local function looksLikeProfile(t)
    if type(t) ~= "table" then return false end
    for k, v in pairs(t) do
        if type(k) == "string" and type(v) == "table" then return true end
    end
    return false
end

-- name (or nil = this character's current config) -> share string.
function Profiles:Export(name)
    if name and not self:Has(name) then return nil, "no profile named '" .. tostring(name) .. "'" end
    local data = name and self:Get(name) or self:_CurrentSnapshot()
    return ns.Serializer:Encode(data or {})
end

-- share string -> saved under `name` (decoded). Does NOT load it. Returns (true, name) or (false, reason).
-- Only namespaces known THIS session are imported (typed columns need the schema); unknown ones are skipped.
function Profiles:Import(str, name)
    local value, err = ns.Serializer:Decode(str)
    if not value then return false, err end
    if not looksLikeProfile(value) then return false, "that string isn't a profile" end
    if not name or name == "" then name = "Imported" end
    local db = self:DB()
    self:_EnsureRow(name)
    local byNs = {}
    for _, e in ipairs(ns.SettingsTables:Namespaces()) do byNs[e.ns] = e.schema end
    for nsKey, vals in pairs(value) do
        if nsKey ~= "modules" and nsKey ~= "editmode" and byNs[nsKey] then
            ns.SettingsTables:WriteProfileValues(db, nsKey, byNs[nsKey], name, vals)
        end
    end
    if type(value.modules) == "table" then
        db:Delete("profile_module_enable", function(r) return r.profile == name end)
        for mod, enabled in pairs(value.modules) do
            db:Insert("profile_module_enable", { profile = name, name = mod, enabled = enabled and true or false })
        end
    end
    if type(value.editmode) == "table" then
        db:Delete("profile_editmode", function(r) return r.profile == name end)
        for k, pos in pairs(value.editmode) do
            db:Insert("profile_editmode", { profile = name, key = k, point = pos.point, x = pos.x, y = pos.y })
        end
    end
    return true, name
end

ns.ServiceManager:Register(Profiles:New("Profiles", { deps = { "Serializer" } }))
