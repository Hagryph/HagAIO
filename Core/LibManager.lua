local addonName, ns = ...
local Class = ns.Class

-- Core/LibManager.lua
-- Registry for the LIB tier (pure-logic helpers; see Core/Lib.lua). It reuses
-- ns.Registry only for the name map / duplicate check / ordered Iterate -- there is NO
-- dependency graph and NO StartAll: a lib has no deps and no lifecycle, so it is
-- PUBLISHED the moment it registers (at file load) and is ready immediately. This is the
-- discovery anchor for tooling (depcheck / nscheck scan LibManager:Register) without
-- pulling libs into the dependency-ordered service boot.

local LibManager = Class.new("LibManager", ns.Registry, { singleton = true })

function LibManager:Initialize()
    ns.Registry.Initialize(self, "lib")
end

-- Register + publish immediately (libs are ready at load -- no ordered start pass).
function LibManager:Register(lib)
    ns.Registry.Register(self, lib)  -- duplicate-checked, kept in registration order
    lib:_Publish()
    return lib
end

-- hag-lint-disable deadcode: RegisterValue  (every caller lives in Lib/, which the deadcode scan skips)
-- Register + publish a VALUE lib: a plain static table (ns.Format, ns.Helpers) or a value
-- type (ns.Vector2D) that is published as-is rather than instantiated. Same discovery
-- anchor as Register, so the tooling (depcheck / NamespaceSlots) finds every lib here
-- instead of special-casing bare `ns.X = X` assignments. The one exception is Lib/Color.lua,
-- which is pinned BEFORE this manager in the load order (ns.Theme needs it) and therefore
-- still publishes by direct assignment.
function LibManager:RegisterValue(name, value)
    assert(type(name) == "string" and name ~= "", "LibManager:RegisterValue needs a name")
    assert(type(value) == "table", "LibManager:RegisterValue needs the lib's value table")
    local p = self:_p()
    p.values = p.values or {}                 -- name -> value (duplicate check + Iterate-free registry)
    assert(not p.values[name], ("LibManager:RegisterValue: duplicate value lib '%s'"):format(name))
    p.values[name] = value
    ns[name] = value
    return value
end

-- Self-instantiate so lib files can register into it as they load (after the Core layer).
ns.LibManager = LibManager:New()
