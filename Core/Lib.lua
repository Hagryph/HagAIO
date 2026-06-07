local addonName, ns = ...
local Class = ns.Class

-- Core/Lib.lua
-- Base for a LIB: a pure-logic helper (no WoW API, no state, no dependencies) published
-- into the namespace as a single instance, e.g. ns.Geometry. A Lib is deliberately NOT
-- a Service -- it has no Logger channel, no lifecycle (OnInitialize/OnShutdown) and no
-- node in the dependency-ordered StartAll. It is ready the instant its file loads, so
-- call sites use it directly (ns.Geometry:Dist(...)) and never declare it as a dep.
--
--   local Geometry = ns.Class.new("Geometry", ns.Lib)
--   function Geometry:Dist(...) ... end           -- pure methods; no instance state
--   ns.LibManager:Register(Geometry:New("Geometry"))
--
-- Keeping these out of the Service tier stops "service" meaning both "stateful, ordered
-- singleton" and "pure math library", and trims the boot-time dependency graph to the
-- things that actually have ordering constraints.

local Lib = Class.new("Lib")

function Lib:Initialize(name)
    self:_p().name = name
end

function Lib:GetName() return self:_p().name end

-- Publish into the namespace so call sites reach it as ns.<Name>. Called by the
-- LibManager at register time (file load) -- no StartAll pass needed.
function Lib:_Publish() ns[self:_p().name] = self end

ns.Lib = Lib
