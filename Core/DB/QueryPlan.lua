local addonName, ns = ...

-- Core/DB/QueryPlan.lua
-- A frozen description of one SELECT, produced by QueryBuilder:Run() and consumed by
-- QueryExecutor. Separating the plan from the builder means the executor can be tested with a
-- hand-built plan (no fluent chain) and the builder can be tested for the plan it emits -- two
-- independent surfaces. The plan is a plain record (read-only by convention); its shape:
--
--   projection : list of { kind = "col",  ref, out }          -- a column (out = result name)
--                          { kind = "star", ref }              -- "*" or "alias.*"
--                          { kind = "agg",  agg }              -- a DB.Aggregate
--   distinct   : boolean
--   from       : { table, alias }
--   joins      : list of { kind, table, alias, on = { leftRef, rightRef } | nil }
--   where      : DBWhereClause | nil
--   groupBy    : list of column refs
--   having     : list of { left = (DBAggregate | colref string), op, value }   -- AND-combined
--   orderBy    : list of { ref, dir = "asc" | "desc" }
--   limit, offset : number | nil

local DB = ns.DB

local QueryPlan = {}

function QueryPlan.new(spec)
    return {
        projection = spec.projection or {},
        distinct   = spec.distinct and true or false,
        from       = spec.from,
        joins      = spec.joins or {},
        where      = spec.where,
        groupBy    = spec.groupBy or {},
        having     = spec.having or {},
        orderBy    = spec.orderBy or {},
        limit      = spec.limit,
        offset     = spec.offset,
    }
end

DB.QueryPlan = QueryPlan
