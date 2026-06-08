local addonName, ns = ...
local Class = ns.Class

-- Modules/Class.lua
-- Generic class-helper module. Per-class files (Modules/Class/<Class>.lua) add their
-- methods to ns.ClassModule and register their specs as SUBMODULES under the class's
-- own submodule, each with a spec CONDITION + spec-change EVENTS. The Submodule
-- framework -- NOT this module -- decides which spec submodule is loaded: it loads the
-- one whose condition holds and swaps it on PLAYER_SPECIALIZATION_CHANGED. A spec
-- submodule's onLoad/onUnload run the spec's Load/Unload against this module instance
-- (the host) and set self:_p().activeSub, which drives the settings page.

local ClassModule = Class.new("Class", ns.Module)
ns.ClassModule = ClassModule       -- per-class files add their methods here

-- A per-spec behaviour unit. Each spec (e.g. Monk Brewmaster) is an ns.ClassSpec subclass
-- that configures its HOST -- the Class module instance -- when its spec becomes active:
-- Load wires the host's events/markers, Unload tears them down, OnSettingChanged reacts to a
-- settings change, GetSettings returns the spec's option schema (a `settings` class field).
-- The host is stored at construction, so a spec subclass extends a base spec with real
-- `.super` calls instead of hand-rolled `Base.Load(self)` dispatch on a plain table.
local ClassSpec = Class.new("ClassSpec", nil, { abstract = true })
function ClassSpec:Initialize(host) self:_p().host = host end
function ClassSpec:Host() return self:_p().host end
function ClassSpec:GetSettings() return self.settings or {} end
ClassSpec.Load = Class.abstract("Load")
ClassSpec.Unload = Class.abstract("Unload")
function ClassSpec:OnSettingChanged() end   -- optional; a spec overrides to react
ns.ClassSpec = ClassSpec

-- "none" when the player has no specialisation, else the spec index (1-4). A spec-less
-- character returns an out-of-range "initial" index, so gate on the in-range index only.
function ClassModule:CurrentSpecKey()
    local idx = GetSpecialization and GetSpecialization()
    if not idx then return "none" end
    local num = (GetNumSpecializations and GetNumSpecializations()) or 0
    if idx < 1 or idx > num then return "none" end
    return idx
end

-- ---- lifecycle ------------------------------------------------------------
function ClassModule:OnInitialize()
    local p = self:_p()
    local _, classToken = UnitClass("player")
    p.class = classToken
    p.description = "Helpers tailored to your class and specialisation."
    self:_BuildSettings()
end

-- (Re)build the settings schema from the active spec submodule and seed any missing
-- saved-var defaults. Called from a spec submodule's onLoad (load / spec change).
function ClassModule:_BuildSettings()
    local p = self:_p()
    local sub = p.activeSub
    p.settings = (sub and sub:GetSettings())
        or { { type = "note", text = "Nothing for your current specialisation yet." } }

    local db = self:_SettingsDB()
    if db then
        -- Fill any unset keys from the schema defaults (deep-copied via Component.SeedDefaults).
        for k, v in pairs(ns.Component.SeedDefaults(p.settings)) do
            if db[k] == nil then db[k] = v end
        end
    end
end

-- Class settings live in the module's PER-CHARACTER namespace, BUCKETED by class+spec so a
-- character's specs keep separate configs and never collide. (A character has one class, so
-- bucketing is really per-spec here; the class half just keeps the key unambiguous.) The
-- buckets ride along in this character's profile snapshot. The active bucket (the current
-- spec) is what GetSetting/SetSetting (ns.Component) read and write.
function ClassModule:_SettingsDB()
    local p = self:_p()
    local db = self:_SettingsRoot()  -- module_Class settings (per character)
    if not db then return nil end
    db.specs = db.specs or {}
    local key = (p.class or "?") .. ":" .. tostring(self:CurrentSpecKey())
    db.specs[key] = db.specs[key] or {}
    return db.specs[key]
end

-- Run the inherited declarative settingsWatch, then forward the change to the active spec
-- submodule (passing key/value, like Submodule:OnSettingChanged does).
function ClassModule:OnSettingChanged(key, value)
    ClassModule.super.OnSettingChanged(self, key, value)  -- inherited settingsWatch (Component)
    local sub = self:_p().activeSub
    if sub then sub:OnSettingChanged(key, value) end
end

-- Spec features subscribe via self:On(event, fn, "spec") and the whole "spec" scope
-- is released on spec swap / unload (self:ReleaseScope("spec")) -- both inherited from
-- ns.Component, so the old hand-rolled _Sub / _UnloadSubs are gone.

-- ---- registration ---------------------------------------------------------
ns.ModuleManager:Register(ClassModule:New("Class", {
    title = "Class",
    description = "Helpers for your current class.",
    defaultEnabled = false,
    -- Account-wide: settings are bucketed by class+spec (see _SettingsDB), so they're
    -- shared across same-class+spec alts and captured by profiles.
    color = ns.Theme.hex.purple,
    -- No service deps: event subscriptions go through self:On (ns.Component), and each
    -- spec submodule declares the services ITS features use.
    settings = {},   -- built per spec from the active spec submodule
}))
