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

-- Structural equality for plain Lua values. Tables are compared recursively in both directions,
-- so missing keys and nested settings values (notably colour triples) are handled consistently.
function Helpers.DeepEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not Helpers.DeepEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

-- Clamp a number to the closed unit interval.
function Helpers.Clamp01(v)
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

-- Capture all return values + their count in one table (handles embedded/trailing nils):
-- { n = <count>, ... }. Unpack with `unpack(t, 1, t.n)`.
function Helpers.Pack(...) return { n = select("#", ...), ... } end

ns.LibManager:RegisterValue("Helpers", Helpers)
