local addonName, ns = ...
local Class = ns.Class

-- Core/DB/QueryBuilder.lua
-- The fluent SELECT builder, one instance per Database:Select(...) call. Each clause method mutates
-- private state and returns self for chaining; :Run() freezes a QueryPlan and hands it to the
-- QueryExecutor. The builder holds NO execution logic.
--
-- Every join kind has its OWN method (there is no generic :Join): :InnerJoin, :LeftJoin,
-- :RightJoin, :FullJoin, :CrossJoin, and :SelfJoin (a table joined to itself; its `as` alias is
-- mandatory so both sides resolve unambiguously). Join opts: { as = alias, on = { leftRef, rightRef } }.
--
--   db:Select("faction", DB.Fn.Count("*"):As("n"))
--     :From("routes")
--     :LeftJoin("hops", { as = "h", on = { "routes.id", "h.route_id" } })
--     :Where("t", "<", 60)
--     :GroupBy("faction")
--     :Having(DB.Fn.Count("*"), ">", 1)
--     :OrderBy("n", "desc"):Limit(10):Run()

ns.DB = ns.DB or {}
local DB = ns.DB

local QueryBuilder = Class.new("DBQueryBuilder")

function QueryBuilder:Initialize(db, projectionArgs)
    local p = self:_p()
    p.db = db
    p.projection = {}
    p.distinct = false
    p.from = nil
    p.joins = {}
    p.where = nil
    p.groupBy = {}
    p.having = {}
    p.orderBy = {}
    p.limit = nil
    p.offset = nil
    self:_AddProjection(projectionArgs)
end

local function bareName(ref) return tostring(ref):match("([%w_]+)$") or ref end

function QueryBuilder:_AddProjection(args)
    local p = self:_p()
    for _, a in ipairs(args or {}) do
        if DB.isAggregate(a) then
            p.projection[#p.projection + 1] = { kind = "agg", agg = a }
        elseif a == "*" or tostring(a):match("%.%*$") then
            p.projection[#p.projection + 1] = { kind = "star", ref = a }
        else
            p.projection[#p.projection + 1] = { kind = "col", ref = a, out = bareName(a) }
        end
    end
end

-- Allow extra projection entries after construction (rare; mostly Select(...) is enough).
function QueryBuilder:Columns(...) self:_AddProjection({ ... }); return self end
function QueryBuilder:Distinct()   self:_p().distinct = true; return self end

function QueryBuilder:From(table, alias)
    self:_p().from = { table = table, alias = alias or table }
    return self
end

-- ---- joins (one method per kind) ------------------------------------------
function QueryBuilder:_Join(kind, table, opts)
    opts = opts or {}
    local join = { kind = kind, table = table, alias = opts.as or table, on = opts.on }
    if kind == DB.JoinKind.CROSS then
        join.on = nil
    elseif kind == DB.JoinKind.SELF then
        if not opts.as then error("DB: :SelfJoin requires an `as` alias", 0) end
        if not opts.on then error("DB: :SelfJoin requires an `on` condition", 0) end
    elseif not opts.on then
        error(("DB: %s join of '%s' requires an `on` condition"):format(kind, tostring(table)), 0)
    end
    self:_p().joins[#self:_p().joins + 1] = join
    return self
end

function QueryBuilder:InnerJoin(table, opts) return self:_Join(DB.JoinKind.INNER, table, opts) end
function QueryBuilder:LeftJoin(table, opts)  return self:_Join(DB.JoinKind.LEFT,  table, opts) end
function QueryBuilder:LeftOuterJoin(table, opts)  return self:LeftJoin(table, opts) end
function QueryBuilder:RightJoin(table, opts) return self:_Join(DB.JoinKind.RIGHT, table, opts) end
function QueryBuilder:RightOuterJoin(table, opts) return self:RightJoin(table, opts) end
function QueryBuilder:FullJoin(table, opts)  return self:_Join(DB.JoinKind.FULL,  table, opts) end
function QueryBuilder:FullOuterJoin(table, opts)  return self:FullJoin(table, opts) end
function QueryBuilder:CrossJoin(table, opts) return self:_Join(DB.JoinKind.CROSS, table, opts) end
-- A table joined to itself; `opts.as` (alias) is mandatory.
function QueryBuilder:SelfJoin(table, opts)  return self:_Join(DB.JoinKind.SELF,  table, opts) end

-- ---- where / group / having / order ---------------------------------------
function QueryBuilder:_Where()
    local p = self:_p()
    if not p.where then p.where = DB.WhereClause:New() end
    return p.where
end

function QueryBuilder:Where(col, op, value)    self:_Where():Where(col, op, value);   return self end
function QueryBuilder:AndWhere(col, op, value) self:_Where():AndWhere(col, op, value); return self end
function QueryBuilder:OrWhere(col, op, value)  self:_Where():OrWhere(col, op, value);  return self end
function QueryBuilder:WhereGroup(fn)           self:_Where():Group(fn);                return self end

function QueryBuilder:GroupBy(...)
    local p = self:_p()
    for _, ref in ipairs({ ... }) do p.groupBy[#p.groupBy + 1] = ref end
    return self
end

function QueryBuilder:Having(left, op, value)
    self:_p().having[#self:_p().having + 1] = { left = left, op = tostring(op):lower(), value = value }
    return self
end

function QueryBuilder:OrderBy(ref, dir)
    dir = (tostring(dir or "asc")):lower()
    assert(dir == "asc" or dir == "desc", "DB: OrderBy direction must be asc or desc")
    self:_p().orderBy[#self:_p().orderBy + 1] = { ref = ref, dir = dir }
    return self
end

function QueryBuilder:Limit(n)  self:_p().limit = n;  return self end
function QueryBuilder:Offset(n)  self:_p().offset = n; return self end

-- Freeze the plan and execute it. Returns an array of result rows (maps of name -> value, with
-- DB.NULL for SQL NULLs).
function QueryBuilder:Plan()
    local p = self:_p()
    assert(p.from, "DB: a query needs :From(table)")
    return DB.QueryPlan.new({
        projection = p.projection, distinct = p.distinct, from = p.from, joins = p.joins,
        where = p.where, groupBy = p.groupBy, having = p.having, orderBy = p.orderBy,
        limit = p.limit, offset = p.offset,
    })
end

function QueryBuilder:Run()
    local p = self:_p()
    return DB.QueryExecutor:Run(p.db, self:Plan())
end

DB.QueryBuilder = QueryBuilder
