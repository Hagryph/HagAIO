local addonName, ns = ...
local Class = ns.Class

-- Core/Lib.lua
-- Base for a LIB: a pure-logic helper (no WoW API, no state, no dependencies) published
-- into the namespace as a single instance, e.g. ns.CVarHelper. A Lib is deliberately NOT
-- a Service -- it has no Logger channel, no lifecycle (OnInitialize/OnShutdown) and no
-- node in the dependency-ordered StartAll. It is ready the instant its file loads, so
-- call sites use it directly (ns.CVarHelper:InferType(...)) and never declare it as a dep.
--
--   local CVarHelper = ns.Class.new("CVarHelper", ns.Lib)
--   function CVarHelper:InferType(...) ... end    -- pure methods; no instance state
--   ns.LibManager:Register(CVarHelper:New("CVarHelper"))
--
-- Keeping these out of the Service tier stops "service" meaning both "stateful, ordered
-- singleton" and "pure math library", and trims the boot-time dependency graph to the
-- things that actually have ordering constraints.

-- ns.Publishable supplies _Publish (publish ns.<Name>), called by the LibManager at register time.
local Lib = Class.new("Lib", nil, { mixins = { ns.Publishable } })

function Lib:Initialize(name)
    local p = self:_p()
    p.name = name
    p.publishAs = name      -- a lib always publishes under its name (ns.<name>); no StartAll pass needed
end

function Lib:GetName() return self:_p().name end

ns.Lib = Lib
