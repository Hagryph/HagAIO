local addonName, ns = ...
local Class = ns.Class

-- Core/Component.lua
-- Shared base for the two things that have an on/off lifecycle plus a settings page:
-- a Module (enable/disable) and a Submodule (load/unload). It owns the three pieces
-- they used to duplicate:
--   * an auto-released RESOURCE REGISTRY (events, messages, hooks, timers) with
--     NAMED SCOPES -- so a sub-lifecycle (e.g. a class spec swap) can be torn down on
--     its own (ReleaseScope) without disturbing everything else;
--   * the SETTINGS accessors + the HagAIO_SettingChanged broadcast; and
--   * the ENABLED-STATE + owner-gating contract (IsEnabled + the HagAIO_OwnerState
--     broadcast the Worker binds to) -- so neither subclass can diverge or forget it.
-- Subclasses say their settings namespace via _SettingsNamespace(), may override
-- _SettingsOwnerId() (broadcast id) and OnSettingChanged(), and implement the abstract
-- Enable()/Disable() lifecycle (routing every state change through self:_SetEnabled).
--
--   self:On(event, fn[, scope])           self:Subscribe(msg, fn[, scope])
--   self:Every(iv, fn[, iters][, scope])  self:After(delay, fn[, scope])
--   self:Throttled(iv, fn[, scope])       self:Debounced(delay, fn[, scope])
--   self:Hook(obj, "method", fn)          self:OnTeardown(fn[, scope])
--   self:ReleaseScope("name")             -- undo one scope; _ReleaseAll() undoes all
-- A nil scope means the DEFAULT scope: the lifetime of one enable / load.

-- Logging (GetLog / _AttachLogger / Log*) is inherited from ns.Loggable, the shared
-- mixin both Component and Service pull in (see Core/Loggable.lua). ns.DatabaseOwner adds the
-- declarative `databases` surface (self:DB(name) + private DAOs) here on the shared base, so both
-- Module and Submodule inherit it; Service mixes it in separately (it doesn't descend Component).
local Component = Class.new("Component", ns.Loggable, { mixins = { ns.DatabaseOwner } })

local DEFAULT = "_default"

-- name is a base invariant (set by ns.Loggable:Initialize, which every subclass calls up
-- to), so no "?" fallback is needed.
function Component:_DisplayName() return self:_p().name end

local function scopes(self)
    local p = self:_p()
    p._scopes = p._scopes or {}   -- scope name -> { head = node }: a LIFO doubly-linked list of teardown nodes
    return p._scopes
end

-- ---- auto-released resources ----------------------------------------------
-- Queue a cleanup callback in `scope`. Run (LIFO) by ReleaseScope / _ReleaseAll. Returns a REMOVER
-- that unlinks this thunk in O(1) -- a fired self:After uses it, so a frequently-scheduled defer never
-- piles up spent thunks. The scope is a doubly-linked list (head = most-recent), so both removal and
-- release are O(1) per node and the scope never grows with dead entries.
function Component:OnTeardown(fn, scope)
    local s = scopes(self)
    scope = scope or DEFAULT
    local sc = s[scope]
    if not sc then sc = {}; s[scope] = sc end
    local node = { fn = fn, next = sc.head }
    if sc.head then sc.head.prev = node end
    sc.head = node
    return function()
        if node.removed then return end
        node.removed = true
        if node.prev then node.prev.next = node.next else sc.head = node.next end
        if node.next then node.next.prev = node.prev end
    end
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

-- Subscribe to a game event for SPECIFIC units only (RegisterUnitEvent) so the handler
-- never fires for irrelevant units; auto-released on scope release. `units` is a list,
-- e.g. self:OnUnit("UNIT_HEALTH", { "player", "target" }, fn).
function Component:OnUnit(event, units, fn, scope)
    local token = ns.EventBus:OnUnit(event, fn, unpack(units))
    if token ~= nil then
        self:OnTeardown(function() ns.EventBus:OffUnit(token) end, scope)
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
    local remove
    local h = ns.Scheduler:After(delay, function() if remove then remove() end; fn() end)   -- drop the spent thunk on fire
    remove = self:OnTeardown(function() if not h:IsCancelled() then h:Cancel() end end, scope)
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

-- ---- enabled state + owner-gating contract --------------------------------
-- A Component is an OWNER the Worker gates work on: a job bound to it (self:Queue / WorkOn /
-- WorkEvery) only runs while the owner is enabled, and the Worker tracks that through IsEnabled()
-- plus the HagAIO_OwnerState broadcast (see Services/Worker.lua). Both live HERE, once -- so a
-- subclass can neither define a divergent IsEnabled nor forget the broadcast (the bug that once
-- left a Submodule's Worker jobs believing it was permanently enabled).
function Component:IsEnabled() return self:_p().enabled == true end

-- The ONLY place the enabled flag moves. Coerces to bool, no-ops (returns false) when already in
-- that state, else flips it and broadcasts HagAIO_OwnerState so the Worker's owner binding always
-- tracks it. Subclasses transition state THROUGH here -- never by touching p.enabled or emitting
-- the message themselves. Returns true iff the state actually changed.
function Component:_SetEnabled(on)
    on = on and true or false
    local p = self:_p()
    if p.enabled == on then return false end
    p.enabled = on
    if ns.EventBus and ns.EventBus.Emit then
        ns.EventBus:Emit("HagAIO_OwnerState", self, on)   -- (owner, enabled) -- Worker owner binding
    end
    return true
end

-- The enable/disable WORK is per-subclass and ABSTRACT: a Module toggles on the user's choice, a
-- Submodule loads when its condition holds. Each override does its own setup/teardown and routes
-- the state change through self:_SetEnabled(...). Declared abstract so a new Component kind can't
-- silently lack a lifecycle, and so neither subclass re-implements the shared contract above.
Component.Enable  = ns.Class.abstract("Enable")
Component.Disable = ns.Class.abstract("Disable")

-- Owner-stamp Worker opts with this component so the Worker gates the work on this owner's
-- enabled state (and auto-listens to its enable/disable). Copies so the caller's table is untouched.
function Component:_WorkerOpts(opts)
    local o = {}
    if opts then for k, v in pairs(opts) do o[k] = v end end
    o.owner = self
    return o
end

-- Queue ONE-TIME deferrable work through the frame-budgeted Worker (see Services/Worker.lua), BOUND
-- to this component (only runs while enabled); cancelled on scope release if it hasn't run yet. For
-- long jobs, call ns.Worker:Yield() (or the `yield` passed to fn) at chunk points. Returns the job
-- HANDLE (handle:Cancel(); nil when this component is disabled).
function Component:Queue(fn, opts, scope)
    local handle = ns.Worker:Queue(fn, self:_WorkerOpts(opts))
    if handle then self:OnTeardown(function() handle:Cancel() end, scope) end
    return handle
end

-- Run `fn` through the Worker whenever `event` fires (a game event, or a custom message with
-- opts.message=true), BOUND to this component; auto-unregistered on scope release. Fires are coalesced
-- and only run while this component is enabled (see Worker:Register).
function Component:WorkOn(event, fn, opts, scope)
    local handle = ns.Worker:Register(event, fn, self:_WorkerOpts(opts))
    self:OnTeardown(handle.Unregister, scope)
    return handle
end

-- Run `fn` through the Worker every `interval` seconds via a timer reminder (no polling), BOUND to
-- this component (paused while disabled); auto-unregistered on scope release.
function Component:WorkEvery(interval, fn, opts, scope)
    local handle = ns.Worker:Every(interval, fn, self:_WorkerOpts(opts))
    self:OnTeardown(handle.Unregister, scope)
    return handle
end

-- Run + clear one scope's teardown thunks (LIFO: head = most-recent). No-op on an unknown/empty scope.
-- Detach the scope FIRST so a teardown that registers a NEW thunk here lands in a fresh list (drained
-- by _ReleaseAll's loop), not the one being traversed.
function Component:ReleaseScope(scope)
    local p = self:_p()
    local s = p._scopes
    local sc = s and s[scope or DEFAULT]
    if not sc then return end
    s[scope or DEFAULT] = nil
    local node = sc.head
    while node do
        local nxt = node.next
        node.removed = true   -- a stale remover (e.g. its self:After firing later) becomes a no-op
        local ok, err = pcall(node.fn)
        if not ok then
            ns.Logger:Core():Warn(("%s teardown error: %s"):format(self:_DisplayName(), tostring(err)))
        end
        node = nxt
    end
end

-- Release every scope (full teardown) and drop any owner-tracked hooks. Drains the
-- scope map with next() -- ReleaseScope removes each key as it runs -- so no temp
-- snapshot array is allocated, and scopes a teardown thunk happens to add are drained
-- too.
function Component:_ReleaseAll()
    local p = self:_p()
    local s = p._scopes
    if s then
        local scope = next(s)
        while scope do
            self:ReleaseScope(scope)  -- clears s[scope]
            scope = next(s)
        end
    end
    if ns.Hooks then ns.Hooks:UnhookAll(self) end
end

-- ---- settings -------------------------------------------------------------
-- Settings live in the shared Database, as the override -> loaded-profile -> code-default cascade
-- over a pair of auto-derived tables per namespace (see Lib/SettingsTables.lua). A Component just has
-- to say its NAMESPACE; the schema is its GetSettings().
--
-- ABSTRACT: every Component subclass names its settings namespace (Module -> "module_<name>",
-- Submodule -> "submodule_<name>", the Class module -> a per-spec bucket). A subclass that uses
-- settings but forgot to override this hits a clear error rather than silently storing nothing.
Component._SettingsNamespace = ns.Class.abstract("_SettingsNamespace")
-- ABSTRACT too: GetSetting/SetSetting below call self:GetSettings() (the option schema). A subclass
-- that uses settings but forgot to define it hits the framework's named abstract error instead of a
-- cryptic "attempt to call a nil value". Module/Submodule/ClassModule all define it.
Component.GetSettings = ns.Class.abstract("GetSettings")
-- These have sensible defaults and are optional overrides (NOT abstract).
function Component:_SettingsOwnerId() return self:_p().name end

-- Derive + register + declare the two settings-backed tables for this component's namespace (the
-- per-character override + per-profile layers; see Lib/SettingsTables.lua), merged with any `extra`
-- tables the subclass owns (a Module's `tables` opt). The single home for the derive/register/
-- declare/AddDep dance Module and Submodule used to copy -- and the namespace prefix lives ONLY in
-- _SettingsNamespace (no second copy). Reads the raw schema (p.settings, set before this runs), not
-- GetSettings(), so a dynamic override (ClassModule) isn't triggered at construction. Returns this
-- component's service-dep list (p.serviceDeps) with "DatabaseManager" appended when any table was
-- declared, so the constructor assigns it back in one line.
function Component:_DeclareSettingsBackedTables(extra)
    local p = self:_p()
    local schema = p.settings or {}
    local tables = {}
    for tn, spec in pairs(extra or {}) do tables[tn] = spec end
    -- Only touch the namespace when there's actually a schema to derive from. An empty schema
    -- derives nothing and registers nothing, so we must NOT evaluate _SettingsNamespace() -- a
    -- dynamic subclass (the Class module) computes it from live spec state that doesn't exist at
    -- construction, and the Class module's real per-spec tables come from its own _CollectTables.
    if next(schema) then
        local nsKey = self:_SettingsNamespace()
        for tn, spec in pairs(ns.SettingsTables:DeriveTables(nsKey, schema)) do tables[tn] = spec end
        ns.SettingsTables:Register(nsKey, schema)
    end
    self:_DeclareTables(tables)
    if next(tables) then return ns.AddDep(p.serviceDeps, "DatabaseManager") end
    return p.serviceDeps
end

-- Default settings reaction: dispatch the declarative `settingsWatch` map a subclass
-- passed in its opts. Each entry maps a setting key to a handler (a method NAME or a
-- function), invoked as handler(self, key, value) when that key changes. The special
-- key "*" runs on EVERY change (after any key-specific handler) -- the "rebuild on
-- these keys, then always re-apply" pattern. A subclass needing bespoke logic can
-- still override OnSettingChanged outright.
--   settingsWatch = { startColor = "_RebuildCurve", ["*"] = "_ApplyColors" }
function Component:OnSettingChanged(key, value)
    local watch = self:_p().settingsWatch
    if not watch then return end
    local function run(spec)
        if type(spec) == "string" then return self[spec](self, key, value) end
        if type(spec) == "function" then return spec(self, key, value) end
    end
    local keyed = watch[key]
    if keyed ~= nil then run(keyed) end
    local star = watch["*"]
    if star ~= nil and star ~= keyed then run(star) end
end

-- Effective value: this char's override ?? loaded profile ?? schema default, resolved live against
-- the database (Lib/SettingsTables.lua). Before the database is built, fall back to the code default.
function Component:GetSetting(key)
    local schema = self:GetSettings()
    local db = self:DB()
    if not db then return ns.SettingsTables.SchemaDefault(schema, key) end
    return ns.SettingsTables:Get(db, self:_SettingsNamespace(), schema, key)
end

function Component:SetSetting(key, value)
    local db = self:DB()
    if db then ns.SettingsTables:Set(db, self:_SettingsNamespace(), self:GetSettings(), key, value) end
    self:OnSettingChanged(key, value)
    -- Broadcast so anything else (other components, the UI) can react without the
    -- changer needing to know about them.
    if ns.EventBus then ns.EventBus:Emit("HagAIO_SettingChanged", self:_SettingsOwnerId(), key, value) end
end

-- ---- declarative contributions (slash commands + General-page toggles) -----
-- Two cross-cutting integrations a feature can DECLARE instead of wiring by hand,
-- exactly like the events / messages / settings tables. The base wires them in (a
-- Module on enable, auto-removed on disable; a Service once at init) so no feature
-- repeats the imperative ns.SlashCommand:Register / RegisterGeneralToggle plumbing.
--   commands = { xp = { handler = "_PrintSession", help = "session XP / hour" } }
--   generalToggles = { { section = "Icons", label = "...", desc = "...",
--                        get = "IsShown", set = "SetShown", reload = bool,
--                        reloadMsg = "..." } }
-- handler / get / set are each a METHOD NAME (string) or a function; both are called bound
-- to the owner -- handler(rest), get() -> bool, set(on) -> bool|nil. The pure builders live
-- in ns.Contributions so ns.Service (which doesn't inherit Component) shares them too.

-- Wire this component's declarative commands / general toggles, queuing a teardown
-- for each so they're removed when the default scope is released (module disable /
-- submodule unload). Called by Module:Enable via _WireDeclared.
function Component:_WireContributions()
    local p = self:_p()
    -- Component's registrations are torn down on disable, so each undo is queued via OnTeardown
    -- (a Service passes no teardown -- see Core/Contributions.lua's Wire).
    ns.Contributions.Wire(self, p.commands, p.generalToggles, function(fn) self:OnTeardown(fn) end)
end

ns.Component = Component
