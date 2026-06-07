local addonName, ns = ...
local Class = ns.Class

-- Core/LibManager.lua
-- Registry for the LIB tier (pure-logic helpers; see Core/Lib.lua). It reuses
-- ns.Registry only for the name map / duplicate check / ordered Iterate -- there is NO
-- dependency graph and NO StartAll: a lib has no deps and no lifecycle, so it is
-- PUBLISHED the moment it registers (at file load) and is ready immediately. This is the
-- discovery anchor for tooling (depcheck / nscheck scan LibManager:Register) without
-- pulling libs into the dependency-ordered service boot.

local LibManager = Class.new("LibManager", ns.Registry)

function LibManager:Initialize()
    ns.Registry.Initialize(self, "lib")
end

-- Register + publish immediately (libs are ready at load -- no ordered start pass).
function LibManager:Register(lib)
    ns.Registry.Register(self, lib)  -- duplicate-checked, kept in registration order
    lib:_Publish()
    return lib
end

-- Self-instantiate so lib files can register into it as they load (after the Core layer).
ns.LibManager = LibManager:New()
