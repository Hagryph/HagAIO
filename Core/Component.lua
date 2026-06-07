local addonName, ns = ...
local Class = ns.Class

-- Core/Component.lua
-- Shared base for the two things that have an on/off lifecycle plus a settings page:
-- a Module (enable/disable) and a Submodule (load/unload). It owns the two pieces
-- they used to duplicate:
--   * an auto-released RESOURCE REGISTRY (events, messages, hooks, timers) with
--     NAMED SCOPES -- so a sub-lifecycle (e.g. a class spec swap) can be torn down on
--     its own (ReleaseScope) without disturbing everything else; and
--   * the SETTINGS accessors + the HagAIO_SettingChanged broadcast.
-- Subclasses say where the values live via _SettingsDB(), and may override
-- _SettingsOwnerId() (broadcast id) and OnSettingChanged().
--
--   self:On(event, fn[, scope])           self:Subscribe(msg, fn[, scope])
--   self:Every(iv, fn[, iters][, scope])  self:After(delay, fn[, scope])
--   self:Throttled(iv, fn[, scope])       self:Debounced(delay, fn[, scope])
--   self:Hook(obj, "method", fn)          self:OnTeardown(fn[, scope])
--   self:ReleaseScope("name")             -- undo one scope; _ReleaseAll() undoes all
-- A nil scope means the DEFAULT scope: the lifetime of one enable / load.

local Component = Class.new("Component")

local DEFAULT = "_default"

function Component:_DisplayName() return self:_p().name or "?" end

local function scopes(self)
    local p = self:_p()
    p._scopes = p._scopes or {}   -- scope name -> { teardown thunks }
    return p._scopes
end

-- ---- auto-released resources ----------------------------------------------
-- Queue a cleanup callback in `scope`. Run (LIFO) by ReleaseScope / _ReleaseAll.
function Component:OnTeardown(fn, scope)
    local s = scopes(self)
    scope = scope or DEFAULT
    local list = s[scope]
    if not list then list = {}; s[scope] = list end
    list[#list + 1] = fn
end

-- Subscribe to a game event; auto-Off on scope release. Returns the token (nil if
-- the event is unknown on this client).
function Component:On(event, fn, scope)
    local token = ns.EventBus:On(event, fn)
    if token ~= nil then
        self:OnTeardown(function() ns.EventBus:Off(event, token) end, scope)
    end
    return token
end

-- Subscribe to a custom in-addon message; auto-Unsubscribe on scope release.
function Component:Subscribe(message, fn, scope)
    local token = ns.EventBus:Subscribe(message, fn)
    self:OnTeardown(function() ns.EventBus:Unsubscribe(message, token) end, scope)
    return token
end

-- Removable secure hook owned by this component (dropped by _ReleaseAll's
-- UnhookAll). Two forms: (obj, "method", fn) or ("GlobalName", fn).
function Component:Hook(object, method, handler)
    if type(object) == "string" then
        return ns.Hooks:Secure(object, method, self)
    end
    return ns.Hooks:Secure(object, method, handler, self)
end

-- Timers via the Scheduler; auto-cancelled on scope release.
function Component:Every(interval, fn, iterations, scope)
    local h = ns.Scheduler:Every(interval, fn, iterations)
    self:OnTeardown(function() if not h:IsCancelled() then h:Cancel() end end, scope)
    return h
end

function Component:After(delay, fn, scope)
    local h = ns.Scheduler:After(delay, fn)
    self:OnTeardown(function() if not h:IsCancelled() then h:Cancel() end end, scope)
    return h
end

function Component:Throttled(interval, fn, scope)
    local wrapped, control = ns.Scheduler:Throttled(interval, fn)
    self:OnTeardown(control.Cancel, scope)
    return wrapped
end

function Component:Debounced(delay, fn, scope)
    local wrapped, control = ns.Scheduler:Debounced(delay, fn)
    self:OnTeardown(control.Cancel, scope)
    return wrapped
end

-- Run + clear one scope's teardown thunks (LIFO). No-op on an unknown/empty scope.
function Component:ReleaseScope(scope)
    local p = self:_p()
    local s = p._scopes
    local list = s and s[scope or DEFAULT]
    if not list then return end
    for i = #list, 1, -1 do
        local fn = list[i]; list[i] = nil
        local ok, err = pcall(fn)
        if not ok then
            ns.Logger:Core():Warn(("%s teardown error: %s"):format(self:_DisplayName(), tostring(err)))
        end
    end
    s[scope or DEFAULT] = nil
end

-- Release every scope (full teardown) and drop any owner-tracked hooks.
function Component:_ReleaseAll()
    local p = self:_p()
    if p._scopes then
        local names = {}
        for scope in pairs(p._scopes) do names[#names + 1] = scope end
        for _, scope in ipairs(names) do self:ReleaseScope(scope) end
    end
    if ns.Hooks then ns.Hooks:UnhookAll(self) end
end

-- ---- settings -------------------------------------------------------------
-- ABSTRACT: every Component subclass must say WHERE its settings live (Module -> its
-- bound db; Submodule -> its own namespace). A subclass that uses settings but forgot
-- to override this hits a clear error rather than silently storing nothing.
Component._SettingsDB = ns.Class.abstract("_SettingsDB")
-- These have sensible defaults and are optional overrides (NOT abstract).
function Component:_SettingsOwnerId() return self:_p().name end
function Component:OnSettingChanged(key, value) end

function Component:GetSetting(key)
    local db = self:_SettingsDB()
    return db and db[key]
end

function Component:SetSetting(key, value)
    local db = self:_SettingsDB()
    if db then db[key] = value end
    self:OnSettingChanged(key, value)
    -- Broadcast so anything else (other components, the UI) can react without the
    -- changer needing to know about them.
    if ns.EventBus then ns.EventBus:Emit("HagAIO_SettingChanged", self:_SettingsOwnerId(), key, value) end
end

ns.Component = Component
