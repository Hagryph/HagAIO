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

-- "none" when the player has no specialisation, else the spec index (1-4). A spec-less
-- character returns an out-of-range "initial" index, so gate on the in-range index only.
local function currentSpecKey()
    local idx = GetSpecialization and GetSpecialization()
    if not idx then return "none" end
    local num = (GetNumSpecializations and GetNumSpecializations()) or 0
    if idx < 1 or idx > num then return "none" end
    return idx
end
function ClassModule:CurrentSpecKey() return currentSpecKey() end

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
    p.settings = (sub and sub.settings)
        or { { type = "note", text = "Nothing for your current specialisation yet." } }

    local db = self:_SettingsDB()
    if db then
        for _, s in ipairs(p.settings) do
            if s.key ~= nil and s.default ~= nil and db[s.key] == nil then
                if type(s.default) == "table" then
                    local c = {}
                    for i, v in ipairs(s.default) do c[i] = v end
                    db[s.key] = c
                else
                    db[s.key] = s.default
                end
            end
        end
    end
end

-- Class settings are stored ACCOUNT-WIDE but BUCKETED by class+spec, so all your
-- characters of the same class+spec share one config, while different specs/classes
-- never collide -- and the buckets ride along in account-wide profiles. The active
-- bucket (chosen by the current character's class + spec) is what GetSetting/
-- SetSetting (ns.Component) read and write.
function ClassModule:_SettingsDB()
    local p = self:_p()
    local db = self:GetDB()          -- module_Class (account-wide)
    if not db then return nil end
    db.specs = db.specs or {}
    local key = (p.class or "?") .. ":" .. tostring(self:CurrentSpecKey())
    db.specs[key] = db.specs[key] or {}
    return db.specs[key]
end

-- Forward a settings change to the active spec submodule.
function ClassModule:OnSettingChanged()
    local sub = self:_p().activeSub
    if sub and sub.OnSettingChanged then sub.OnSettingChanged(self) end
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
