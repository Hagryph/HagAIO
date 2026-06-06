local addonName, ns = ...
local Class = ns.Class

-- Modules/Class.lua
-- Generic class-helper module. The real, class-specific logic lives in per-class
-- files (Modules/Class/<Class>.lua) that add methods to ns.ClassModule and
-- register their spec submodules into ns.ClassSubmodules[CLASS_TOKEN][specKey],
-- where specKey is "none" (no specialisation) or a spec index 1-4.
--
-- The active submodule follows the player's CURRENT spec and is swapped on spec
-- change (the old one fully unloaded first); we never fall back to the no-spec
-- submodule while a spec is active. A submodule is:
--   { settings, Load(self), Unload(self), OnSettingChanged(self)? }
-- with self = the ClassModule instance (state via self:_p(), events via self:_Sub).

local ClassModule = Class.new("Class", ns.Module)
ns.ClassModule = ClassModule       -- per-class files add their methods here
ns.ClassSubmodules = {}            -- [CLASS_TOKEN] = { ["none"] = sub, [1] = sub, ... }

-- "none" when the player has no specialisation, else the spec index (1-4).
-- A spec-less character returns an out-of-range "initial" index (e.g. 5 for a
-- pre-level-10 Monk, > GetNumSpecializations). NOTE: GetSpecializationInfo returns
-- name=nil even for real specs on 12.0, so gate on the in-range index only.
local function currentSpecKey()
    local idx = GetSpecialization and GetSpecialization()
    if not idx then return "none" end
    local num = (GetNumSpecializations and GetNumSpecializations()) or 0
    if idx < 1 or idx > num then return "none" end
    return idx
end

function ClassModule:_Submodule()
    local reg = ns.ClassSubmodules[self:_p().class]
    return reg and reg[currentSpecKey()] or nil
end

-- ---- lifecycle ------------------------------------------------------------
function ClassModule:OnInitialize()
    local p = self:_p()
    p.tokens = {}
    p.subTokens = {}
    local _, classToken = UnitClass("player")
    p.class = classToken

    -- Settings reflect the submodule for the player's CURRENT spec (at login).
    local sub = self:_Submodule()
    p.description = "Helpers tailored to your class and specialisation."
    p.settings = (sub and sub.settings)
        or { { type = "note", text = "Nothing for your current specialisation yet." } }

    -- Seed saved-var defaults for the current submodule's settings.
    local db = self:GetDB()
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

function ClassModule:OnEnable()
    local p = self:_p()
    if not ns.ClassSubmodules[p.class] then return end  -- no helpers for this class yet

    -- Watch for spec changes to swap submodules.
    local bus = ns.EventBus
    p.tokens["PLAYER_SPECIALIZATION_CHANGED"] = bus:On("PLAYER_SPECIALIZATION_CHANGED", function() self:_Sync() end)
    p.tokens["PLAYER_ENTERING_WORLD"]         = bus:On("PLAYER_ENTERING_WORLD",         function() self:_Sync() end)
    self:_Sync()
end

function ClassModule:OnDisable()
    local p = self:_p()
    local bus = ns.EventBus
    for event, token in pairs(p.tokens) do bus:Off(event, token) end
    wipe(p.tokens)
    if p.activeSub and p.activeSub.Unload then p.activeSub.Unload(self) end
    p.activeSub = nil
end

-- Forward to the active submodule (the class file decides what to refresh).
function ClassModule:OnSettingChanged()
    local sub = self:_p().activeSub
    if sub and sub.OnSettingChanged then sub.OnSettingChanged(self) end
end

-- Submodule event subscriptions (a list, so several features can share events).
function ClassModule:_Sub(event, fn)
    local p = self:_p()
    p.subTokens = p.subTokens or {}
    local token = ns.EventBus:On(event, fn)
    if token then p.subTokens[#p.subTokens + 1] = { event, token } end
end

function ClassModule:_UnloadSubs()
    local p = self:_p()
    if not p.subTokens then return end
    local bus = ns.EventBus
    for _, e in ipairs(p.subTokens) do bus:Off(e[1], e[2]) end
    wipe(p.subTokens)
end

-- Load the submodule matching the current spec, unloading the previous one.
function ClassModule:_Sync()
    local p = self:_p()
    if not self:IsEnabled() then return end
    local sub = self:_Submodule()
    if sub == p.activeSub then return end
    if p.activeSub and p.activeSub.Unload then p.activeSub.Unload(self) end
    p.activeSub = sub
    if sub and sub.Load then sub.Load(self) end
end

-- ---- registration ---------------------------------------------------------
ns.ModuleManager:Register(ClassModule:New("Class", {
    title = "Class",
    description = "Helpers for your current class.",
    defaultEnabled = false,
    perChar = true,  -- class/spec differ per character, so store state per char
    settings = {},   -- built per class/spec in OnInitialize
}))
