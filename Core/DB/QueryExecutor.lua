local addonName, ns = ...
local Class = ns.Class

-- Core/DB/QueryExecutor.lua
-- Runs a QueryPlan against a Database, following SQL's LOGICAL processing order so the pieces
-- compose exactly as SQL promises:
--   FROM/JOIN -> WHERE -> GROUP BY -> (aggregates) -> HAVING -> SELECT/DISTINCT -> ORDER BY -> LIMIT/OFFSET
-- The working set is a list of COMPOSITE rows: each is a map alias -> stored-row (or nil for the
-- unmatched side of an outer join), so a join never flattens away which table a column came from.
-- Stateless: one executor is reused by a Database; all per-query state is local to :Run.

ns.DB = ns.DB or {}
local DB = ns.DB

local SEP = "\31"

-- type-tagged key for grouping / distinct (NULL -> "\0")
local function vkey(v)
    if v == nil or v == DB.NULL then return "\0" end
    local t = type(v)
    if t == "string"  then return "s" .. v end
    if t == "number"  then return "n" .. tostring(v) end
    if t == "boolean" then return v and "b1" or "b0" end
    return "?" .. tostring(v)
end

local function shallow(t) local o = {}; if t then for k, v in pairs(t) do o[k] = v end end; return o end
local function bareName(ref) return tostring(ref):match("([%w_]+)$") or ref end

-- ---- aggregates -----------------------------------------------------------
local function computeAgg(agg, rows, resolver)
    local fn, arg, distinct = agg:Fn(), agg:Arg(), agg:IsDistinct()
    if fn == "count" and arg == "*" then return #rows end

    local vals, seen = {}, {}
    for _, comp in ipairs(rows) do
        local v = resolver:Value(comp, arg)
        if not DB.isNull(v) then
            if distinct then
                local k = vkey(v)
                if not seen[k] then seen[k] = true; vals[#vals + 1] = v end
            else
                vals[#vals + 1] = v
            end
        end
    end

    if fn == "count" then return #vals end
    if fn == "total" then local s = 0; for _, v in ipairs(vals) do s = s + v end; return s end
    if #vals == 0 then return DB.NULL end                       -- sum/avg/min/max/group_concat over nothing
    if fn == "sum" then local s = 0; for _, v in ipairs(vals) do s = s + v end; return s end
    if fn == "avg" then local s = 0; for _, v in ipairs(vals) do s = s + v end; return s / #vals end
    if fn == "min" then local m = vals[1]; for _, v in ipairs(vals) do if v < m then m = v end end; return m end
    if fn == "max" then local m = vals[1]; for _, v in ipairs(vals) do if v > m then m = v end end; return m end
    if fn == "group_concat" then
        local s = {}; for i, v in ipairs(vals) do s[i] = tostring(v) end
        return table.concat(s, agg:Sep())
    end
    error("DB: unknown aggregate '" .. tostring(fn) .. "'", 0)
end

-- ---- join ------------------------------------------------------------------
local function applyJoin(left, join, rightRows, resolver)
    local alias, kind, out = join.alias, join.kind, {}

    if kind == DB.JoinKind.CROSS then
        for _, lc in ipairs(left) do
            for _, rr in ipairs(rightRows) do local n = shallow(lc); n[alias] = rr; out[#out + 1] = n end
        end
        return out
    end

    local on = join.on
    local function matches(lc, rr)
        local m = shallow(lc); m[alias] = rr
        local lv, rv = resolver:Value(m, on[1]), resolver:Value(m, on[2])
        return not DB.isNull(lv) and not DB.isNull(rv) and lv == rv
    end

    if kind == DB.JoinKind.RIGHT then
        for _, rr in ipairs(rightRows) do
            local any = false
            for _, lc in ipairs(left) do
                if matches(lc, rr) then local n = shallow(lc); n[alias] = rr; out[#out + 1] = n; any = true end
            end
            if not any then out[#out + 1] = { [alias] = rr } end
        end
        return out
    end

    -- INNER / SELF / LEFT / FULL all iterate the left side; FULL also appends unmatched right rows.
    local matchedR = (kind == DB.JoinKind.FULL) and {} or nil
    for _, lc in ipairs(left) do
        local any = false
        for _, rr in ipairs(rightRows) do
            if matches(lc, rr) then
                local n = shallow(lc); n[alias] = rr; out[#out + 1] = n; any = true
                if matchedR then matchedR[rr] = true end
            end
        end
        if not any and (kind == DB.JoinKind.LEFT or kind == DB.JoinKind.FULL) then
            out[#out + 1] = shallow(lc)                          -- right alias absent -> NULL
        end
    end
    if matchedR then
        for _, rr in ipairs(rightRows) do
            if not matchedR[rr] then out[#out + 1] = { [alias] = rr } end
        end
    end
    return out
end

-- ---- ordering --------------------------------------------------------------
-- Compare two NON-NULL, order-comparable values (NULL handling happens in the comparator so it can
-- stay direction-independent -- NULLs always sort last whether the key is ASC or DESC).
local function orderCompare(a, b)
    if type(a) ~= type(b) then return type(a) < type(b) and -1 or 1 end
    if a < b then return -1 elseif a > b then return 1 else return 0 end
end

-- ===========================================================================
local QueryExecutor = Class.new("DBQueryExecutor")

function QueryExecutor:Run(db, plan)
    local schema = db:Schema()

    -- sources (FROM + joins) -> resolver
    local sources = { { alias = plan.from.alias, table = assert(schema:Table(plan.from.table),
        ("DB: unknown table '%s'"):format(tostring(plan.from.table))) } }
    for _, j in ipairs(plan.joins) do
        sources[#sources + 1] = { alias = j.alias, table = assert(schema:Table(j.table),
            ("DB: unknown table '%s'"):format(tostring(j.table))) }
    end
    local resolver = DB.ColumnResolver:New(sources)

    -- FROM
    local rows = {}
    for _, r in ipairs(db:Store():Rows(plan.from.table) or {}) do rows[#rows + 1] = { [plan.from.alias] = r } end
    -- JOIN
    for _, j in ipairs(plan.joins) do
        rows = applyJoin(rows, j, db:Store():Rows(j.table) or {}, resolver)
    end

    -- WHERE
    if plan.where and not plan.where:IsEmpty() then
        local kept = {}
        for _, comp in ipairs(rows) do if plan.where:Matches(comp, resolver) then kept[#kept + 1] = comp end end
        rows = kept
    end

    -- decide grouped vs row-wise
    local hasAgg = #plan.groupBy > 0
    if not hasAgg then for _, e in ipairs(plan.projection) do if e.kind == "agg" then hasAgg = true; break end end end

    local outputs   -- list of { row = <map>, ctx = <compRow for ORDER BY of non-selected cols> }
    if not hasAgg then
        outputs = {}
        for _, comp in ipairs(rows) do
            outputs[#outputs + 1] = { row = self:_ProjectRow(plan.projection, comp, resolver), ctx = comp }
        end
    else
        outputs = self:_Grouped(plan, rows, resolver)
    end

    -- DISTINCT
    if plan.distinct then outputs = self:_Distinct(outputs) end

    -- ORDER BY
    if #plan.orderBy > 0 then self:_Order(outputs, plan.orderBy, resolver) end

    -- LIMIT / OFFSET
    outputs = self:_Slice(outputs, plan.limit, plan.offset)

    local result = {}
    for i, o in ipairs(outputs) do result[i] = o.row end
    return result
end

-- project a single composite row (no aggregates)
function QueryExecutor:_ProjectRow(projection, comp, resolver)
    local row = {}
    for _, e in ipairs(projection) do
        if e.kind == "col" then
            row[e.out] = resolver:Value(comp, e.ref)
        elseif e.kind == "star" then
            for _, x in ipairs(resolver:ExpandStar(e.ref)) do row[x.out] = resolver:Value(comp, x.ref) end
        else
            error("DB: aggregate in a non-grouped projection (add GROUP BY or remove the column)", 0)
        end
    end
    return row
end

-- group, compute aggregates, apply HAVING, project
function QueryExecutor:_Grouped(plan, rows, resolver)
    -- partition into groups (a single group over everything when there is no GROUP BY)
    local groups, order = {}, {}
    if #plan.groupBy == 0 then
        order[1] = "*"; groups["*"] = rows
    else
        for _, comp in ipairs(rows) do
            local parts = {}
            for i, ref in ipairs(plan.groupBy) do parts[i] = vkey(resolver:Value(comp, ref)) end
            local key = table.concat(parts, SEP)
            local g = groups[key]
            if not g then g = {}; groups[key] = g; order[#order + 1] = key end
            g[#g + 1] = comp
        end
    end

    local outputs = {}
    for _, key in ipairs(order) do
        local grp = groups[key]
        local rep = grp[1]
        if self:_Having(plan.having, grp, rep, resolver) then
            local row = {}
            for _, e in ipairs(plan.projection) do
                if e.kind == "agg" then
                    row[e.agg:OutputName()] = computeAgg(e.agg, grp, resolver)
                elseif e.kind == "col" then
                    row[e.out] = rep and resolver:Value(rep, e.ref) or DB.NULL
                else -- star
                    for _, x in ipairs(resolver:ExpandStar(e.ref)) do
                        row[x.out] = rep and resolver:Value(rep, x.ref) or DB.NULL
                    end
                end
            end
            outputs[#outputs + 1] = { row = row, ctx = rep }
        end
    end
    return outputs
end

function QueryExecutor:_Having(having, grp, rep, resolver)
    for _, cond in ipairs(having) do
        local left
        if DB.isAggregate(cond.left) then
            left = computeAgg(cond.left, grp, resolver)
        else
            left = rep and resolver:Value(rep, cond.left) or DB.NULL
        end
        if not DB.evalOp(cond.op, left, cond.value) then return false end
    end
    return true
end

function QueryExecutor:_Distinct(outputs)
    local seen, kept = {}, {}
    for _, o in ipairs(outputs) do
        local keys = {}
        for k in pairs(o.row) do keys[#keys + 1] = k end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. vkey(o.row[k]) end
        local sig = table.concat(parts, SEP)
        if not seen[sig] then seen[sig] = true; kept[#kept + 1] = o end
    end
    return kept
end

function QueryExecutor:_Order(outputs, orderBy, resolver)
    local function valueOf(o, ref)
        local bare = bareName(ref)
        if o.row[ref] ~= nil then return o.row[ref] end
        if o.row[bare] ~= nil then return o.row[bare] end
        return o.ctx and resolver:Value(o.ctx, ref) or DB.NULL
    end
    -- decorate with original index for a STABLE sort (table.sort is not stable)
    for i, o in ipairs(outputs) do o._i = i end
    table.sort(outputs, function(a, b)
        for _, key in ipairs(orderBy) do
            local av, bv = valueOf(a, key.ref), valueOf(b, key.ref)
            local an, bn = (av == nil or av == DB.NULL), (bv == nil or bv == DB.NULL)
            local c
            if an or bn then
                c = (an and bn) and 0 or (an and 1 or -1)       -- NULLs last, regardless of dir
            else
                c = orderCompare(av, bv)
                if key.dir == "desc" then c = -c end
            end
            if c ~= 0 then return c < 0 end
        end
        return a._i < b._i
    end)
    for _, o in ipairs(outputs) do o._i = nil end
end

function QueryExecutor:_Slice(outputs, limit, offset)
    offset = offset or 0
    if offset == 0 and limit == nil then return outputs end
    local out = {}
    local last = limit and (offset + limit) or #outputs
    for i = offset + 1, math.min(last, #outputs) do out[#out + 1] = outputs[i] end
    return out
end

-- Run is a pure method over (db, plan): callable straight on the class table (no per-query state).
DB.QueryExecutor = QueryExecutor
