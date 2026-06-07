local addonName, ns = ...
local Class = ns.Class

-- Core/Registry.lua
-- Shared base for the three lifecycle registries (Module / Service / Submodule
-- managers). It owns the boilerplate each used to reimplement: a name -> item map
-- kept in registration order, a duplicate-checked Register, stateless Iterate /
-- Count / Get, a one-shot start latch, and a lazily-built, cached-on-first-use
-- dependency graph. Subclasses supply only what differs -- the node-builder for
-- their graph (via _GetGraph) and, optionally, what to do when an item registers
-- after startup (_OnLateRegister). One place to fix iterator/graph bugs; every
-- future manager inherits the pattern for free.

local Registry = Class.new("Registry")

-- `kind` is the singular noun used in duplicate / validation error messages
-- ("module", "service", "submodule").
function Registry:Initialize(kind)
    local p = self:_p()
    p.kind = kind or "item"
    p.items = {}      -- name -> item
    p.order = {}      -- registration order (list of names)
    p.graph = nil     -- cached dependency graph; cleared on every Register
    p.started = false
end

-- Register an item (anything answering :GetName()). Duplicate names are fatal.
-- Appends to the ordered list, invalidates the cached graph, and -- if the registry
-- has already started -- hands the late arrival to _OnLateRegister so .toc / file
-- load order never matters.
function Registry:Register(item)
    local p = self:_p()
    local name = item:GetName()
    assert(not p.items[name], "duplicate " .. p.kind .. ": " .. tostring(name))
    p.items[name] = item
    p.order[#p.order + 1] = name
    p.graph = nil  -- structure changed; rebuild lazily on next query
    if p.started then self:_OnLateRegister(item) end
    return item
end

-- Hook for items registered AFTER StartAll. Default: nothing. Subclasses override
-- to start / re-evaluate the late arrival.
function Registry:_OnLateRegister(item) end

-- Look up a registered item by name (nil if absent).
function Registry:Get(name) return self:_p().items[name] end
function Registry:Has(name) return self:_p().items[name] ~= nil end
function Registry:Count() return #self:_p().order end

-- Stateless iterator over items in registration order: `for item in reg:Iterate()`.
function Registry:Iterate()
    local p = self:_p()
    local i = 0
    return function()
        i = i + 1
        local name = p.order[i]
        if name then return p.items[name] end
    end
end

-- Lazily build + cache this registry's dependency graph. `nodeBuilder(self, g)` adds
-- the nodes (the only part that differs per registry); `opts` is forwarded to
-- DependencyGraph:New. Validated once on build (a cycle or dangling dep is a fatal
-- misconfiguration) and cached until the next Register clears it.
function Registry:_GetGraph(nodeBuilder, opts)
    local p = self:_p()
    if p.graph then return p.graph end
    local g = ns.DependencyGraph:New(opts)
    nodeBuilder(self, g)
    g:AssertValid(p.kind .. " dependencies")
    p.graph = g
    return g
end

-- Startup latch. StartAll() calls _BeginStart() once (returns false if already
-- started, so the caller can early-out); later Registers route through
-- _OnLateRegister instead.
function Registry:IsStarted() return self:_p().started end
function Registry:_BeginStart()
    local p = self:_p()
    if p.started then return false end
    p.started = true
    return true
end

ns.Registry = Registry
