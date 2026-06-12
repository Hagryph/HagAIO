local addonName, ns = ...

-- Lib/Helpers.lua
-- Small pure-logic helpers shared across the addon -- no WoW API, no state. A single
-- value table (not instantiated), like ns.Format; the home for one-off utilities that
-- several files would otherwise re-implement. Add new helpers here rather than as
-- file-locals so they're shared and unit-testable.

local Helpers = {}

-- Recursive copy of a value: tables are cloned (every key + value, no metatable),
-- everything else is returned as-is. Use wherever a default/template table must not be
-- shared by reference (e.g. seeding per-character saved-var defaults from a schema).
function Helpers.DeepCopy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, val in pairs(v) do t[k] = Helpers.DeepCopy(val) end
    return t
end

ns.LibManager:RegisterValue("Helpers", Helpers)
