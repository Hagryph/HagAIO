local addonName, ns = ...
local Class = ns.Class

-- Core/DB/Aggregate.lua
-- Immutable aggregate-function specs used in a SELECT projection and in HAVING. Authored through
-- the ns.DB.Fn helpers so the fluent query stays string-free and type-checked:
--   ns.DB.Fn.Count("*")            ns.DB.Fn.Count("id"):Distinct()
--   ns.DB.Fn.Sum("t"):As("total")  ns.DB.Fn.Avg("t")   ns.DB.Fn.Min("t")  ns.DB.Fn.Max("t")
--   ns.DB.Fn.Total("t")            ns.DB.Fn.GroupConcat("name", ", ")
-- The QueryExecutor computes them per group (or once over the whole set when there is no GROUP BY).
-- Empty / all-NULL results follow SQL: COUNT and TOTAL -> 0; SUM/AVG/MIN/MAX/GROUP_CONCAT -> NULL.

ns.DB = ns.DB or {}
local DB = ns.DB

local Aggregate = Class.new("DBAggregate")
Aggregate.__isDBAggregate = true   -- marker reachable on instances via __index (see DB.isAggregate)

-- fn is one of: count|sum|avg|min|max|total|group_concat ; arg is a column ref or "*" (count only)
function Aggregate:Initialize(fn, arg, sep)
    local p = self:_p()
    p.fn = fn
    p.arg = arg
    p.distinct = false
    p.alias = nil
    p.sep = sep
end

function Aggregate:Distinct() self:_p().distinct = true; return self end
function Aggregate:As(name)   self:_p().alias = name;    return self end

function Aggregate:Fn()         return self:_p().fn end
function Aggregate:Arg()        return self:_p().arg end
function Aggregate:IsDistinct() return self:_p().distinct end
function Aggregate:Sep()        return self:_p().sep or "," end

-- The result column name: an explicit :As(), else "<fn>" for count(*) or "<fn>_<arg>".
function Aggregate:OutputName()
    local p = self:_p()
    if p.alias then return p.alias end
    if p.arg == "*" then return p.fn end
    return p.fn .. "_" .. tostring(p.arg):gsub("%.", "_")
end

DB.Aggregate = Aggregate
function DB.isAggregate(x)
    return type(x) == "table" and x.__isDBAggregate == true
end

DB.Fn = {
    Count       = function(arg)      return Aggregate:New("count", arg or "*") end,
    Sum         = function(arg)      return Aggregate:New("sum", arg) end,
    Avg         = function(arg)      return Aggregate:New("avg", arg) end,
    Min         = function(arg)      return Aggregate:New("min", arg) end,
    Max         = function(arg)      return Aggregate:New("max", arg) end,
    Total       = function(arg)      return Aggregate:New("total", arg) end,
    GroupConcat = function(arg, sep) return Aggregate:New("group_concat", arg, sep) end,
}
