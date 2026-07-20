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
function ClassSpec:GetSettings() return self:_statics().settings or {} end
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
    p.class = p.class or classToken   -- keep the token _ContributeTables used, so namespaces match the tables
    p.description = "Helpers tailored to your class and specialisation."
    self:_BuildSettings()
end

-- Register a spec object under specKey so the module resolves the CURRENT spec's settings for display
-- even while it is disabled and its spec submodule isn't loaded. PUBLIC: the per-spec files register
-- through this from outside -- only the per-character class's specs register (the ns.Monk.RegisterSpec
-- static gates on class, then calls host:RegisterSpec -- a DIFFERENT thing: that is the Monk surface,
-- this is the host's registry), so a spec index never collides across classes.
function ClassModule:RegisterSpec(specKey, spec)
    local p = self:_p()
    p.specs = p.specs or {}
    p.specs[specKey] = spec
end

-- The spec driving the settings page: the loaded spec submodule if any (its behaviour is live),
-- else the registered spec for the current specialisation (so settings still show when disabled).
function ClassModule:_ActiveSpec()
    local p = self:_p()
    return p.activeSub or (p.specs and p.specs[self:CurrentSpecKey()])
end

-- Public setter for the currently-loaded spec submodule (use ClearActiveSpec to clear it). A spec's
-- onLoad/onUnload runs against this host but is NOT a ClassModule method, so it marks the active spec
-- through this surface instead of reaching into the host's private table (host:_p().activeSub) from outside.
function ClassModule:SetActiveSpec(spec)
    self:_p().activeSub = spec
end

-- Clear the loaded spec (the settings page then falls back to the registered spec for the current spec).
function ClassModule:ClearActiveSpec()
    self:SetActiveSpec(nil)
end

-- (Re)build the settings schema from the active spec. Defaults come from the per-spec settings
-- view (see _SettingsNamespace) via the cascade -- no manual seeding.
function ClassModule:_BuildSettings()
    local p = self:_p()
    local spec = self:_ActiveSpec()
    p.settings = (spec and spec:GetSettings())
        or { { type = "note", text = "Nothing for your current specialisation yet." } }
end

-- The settings page reads this; rebuild from the CURRENT spec each time so it reflects the spec
-- even when the module is disabled (the spec submodule -- and thus activeSub -- isn't loaded).
function ClassModule:GetSettings()
    self:_BuildSettings()
    return self:_p().settings
end

-- Class settings live in the module's PER-CHARACTER namespace, BUCKETED by class+spec so a
-- character's specs keep separate configs and never collide. (A character has one class, so
-- bucketing is really per-spec here; the class half just keeps the key unambiguous.) The
-- buckets ride along in this character's profile. The active bucket (the current spec) is what
-- GetSetting/SetSetting (ns.Component) read and write; the namespace's code defaults are the
-- active spec's own settings defaults, so the cascade resolves them without manual seeding.
function ClassModule:_SettingsNamespace()
    local p = self:_p()
    return "module_Class#" .. (p.class or "?") .. ":" .. tostring(self:CurrentSpecKey())
end

-- Override the ns.DatabaseOwner hook (NOT _ContributeTables): build a settings-table pair (override
-- + per-profile layers) for EVERY registered spec bucket, so the active spec's namespace always has
-- its tables. The base mixin owns the once-only latch + the Contribute call -- this just RETURNS the
-- collected tables, so renaming the latch can't silently break a hand-copied guard. Schemas are
-- known at file load (the spec classes' `settings`); only the current character's class specs
-- register, so a profile's per-spec columns never collide across classes. Runs in the ADDON_LOADED
-- build sweep, before OnInitialize, so the class token is fixed here rather than read from p.class.
function ClassModule:_CollectTables()
    local p = self:_p()
    p.class = p.class or (select(2, UnitClass("player")))   -- fix the class token now; OnInitialize reuses it
    local class = p.class or "?"
    local tables = {}
    for specKey, spec in pairs(p.specs or {}) do
        local nsKey = "module_Class#" .. class .. ":" .. tostring(specKey)
        ns.SettingsTables:Register(nsKey, spec:GetSettings())
        for tn, tspec in pairs(ns.SettingsTables:DeriveTables(nsKey, spec:GetSettings())) do tables[tn] = tspec end
    end
    return tables
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
    -- Per character: settings are bucketed by class+spec (see _SettingsNamespace) into their own
    -- cascade namespaces, so each spec keeps its own config and they're captured by profiles.
    color = ns.Theme.hex.purple,
    -- Per-spec settings tables live in the shared database. The actual Contribute happens via the
    -- inherited ns.DatabaseOwner mixin (the base _ContributeTables, fed by our _CollectTables), so
    -- there's no direct ns.DatabaseManager access here -- but the load-order dep is still required.
    -- hag-lint-disable depcheck: DatabaseManager
    deps = { "DatabaseManager" },
    -- Event subscriptions go through self:On (ns.Component); each spec submodule declares the
    -- services ITS features use.
    settings = {},   -- built per spec from the active spec submodule
}))
