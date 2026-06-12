local addonName, ns = ...
local Class = ns.Class

-- Core/DB/QueryExecutor.lua
-- Runs a QueryPlan against a Database as a relational-algebra PIPELINE, following SQL's LOGICAL
-- processing order so the pieces compose exactly as SQL promises:
--   FROM/JOIN -> WHERE -> GROUP BY -> (aggregates) -> HAVING -> SELECT/DISTINCT -> ORDER BY -> LIMIT/OFFSET
-- Each stage consumes the previous stage's relation and produces a new, usually NARROWER one, so
-- work shrinks as the query progresses -- exactly how a SQL engine reduces the row set down a plan.
--
-- ISOLATION: the working set never references live storage -- a query can never mutate the database.
-- A row's shallow copy is a COMPLETE clone here because a row is a flat map of native scalars (there
-- are no blob/table columns -- nesting is always relational), so nothing is shared. JOIN queries
-- still snapshot every source table up front; the far more common NO-JOIN query instead scans live
-- rows with WHERE fused in and copies ONLY the survivors (see _ScanBase) -- a point lookup allocates
-- one row copy, not one per stored row.
--
-- INDEXES: a top-level AND'ed equality on an indexed column (PK / unique / declared index / FK --
-- see IndexManager) narrows the base scan to that index bucket, so Where("key","=",k):Limit(1) is
-- O(bucket), not O(table). LIMIT is ENFORCED during the scan: when no later stage can reorder or
-- merge rows (no aggregates / GROUP BY / DISTINCT / ORDER BY), scanning stops at offset+limit.
--
-- CHUNKING: inside a Worker job the row loops offer to yield every CHUNK rows via
-- ns.Worker:MaybeYield() (a no-op everywhere else), so a big query self-partitions to the pump
-- budget instead of stalling a frame. Yielding mid-scan means storage can change underneath the
-- query, so the phases that read LIVE rows run under a per-table GENERATION guard (RowStore:
-- Generation) and restart when the table mutated across a yield; after MAX_RESTARTS such a phase
-- finishes unchunked (correctness over latency). Phases over already-copied rows need no guard.
--
-- The working set is a list of COMPOSITE rows: each is a map alias -> (copied) row, or nil for the
-- unmatched side of an outer join, so a join never flattens away which table a column came from.
-- Stateless: one executor is reused by a Database; all per-query state is local to :Run.

ns.DB = ns.DB or {}
local DB = ns.DB

local SEP = DB.KEY_SEP
local CHUNK = 64            -- rows between yield offers (a clock read each; a switch only when due)
local MAX_RESTARTS = 2      -- mutated-mid-scan restarts before a live-row phase finishes unchunked

-- Offer to hand the frame back at a chunk boundary (no-op outside a Worker job's coroutine).
local function offerYield(n)
    if n % CHUNK == 0 and ns.Worker then ns.Worker:MaybeYield() end
end

-- The shared value/key encoding + ref helper (Core/DB/Types.lua). Grouping/distinct key NULL
-- cells together, so vkey maps NULL to "\0" instead of skipping it like the index layer.
local NULL_KEY = "\0"
local function vkey(v) return DB.valueKey(v, NULL_KEY) end
local bareName = DB.bareName

local function shallow(t) local o = {}; if t then for k, v in pairs(t) do o[k] = v end end; return o end

-- Snapshot a source table into the pipeline (JOIN path): a fresh array of shallow row copies (a
-- full clone, since rows are flat scalar maps). The query then works on this copy and never touches
-- storage. Chunk-yields under the generation guard (see header) -- the copy reads LIVE rows.
local function snapshotRows(db, tableName)
    local store = db:Store()
    local restarts = 0
    while true do
        local gen = store:Generation(tableName)
        local src = store:Rows(tableName) or {}
        local out, dirty = {}, false
        for i = 1, #src do
            out[i] = shallow(src[i])
            if restarts < MAX_RESTARTS and i % CHUNK == 0 and ns.Worker then
                ns.Worker:MaybeYield()
                if store:Generation(tableName) ~= gen then dirty = true; break end
            end
        end
        if not dirty then return out end
        restarts = restarts + 1
    end
end

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
        for li, lc in ipairs(left) do
            for _, rr in ipairs(rightRows) do local n = shallow(lc); n[alias] = rr; out[#out + 1] = n end
            offerYield(li)                       -- working copies: safe to chunk without a guard
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
        for ri, rr in ipairs(rightRows) do
            local any = false
            for _, lc in ipairs(left) do
                if matches(lc, rr) then local n = shallow(lc); n[alias] = rr; out[#out + 1] = n; any = true end
            end
            if not any then out[#out + 1] = { [alias] = rr } end
            offerYield(ri)
        end
        return out
    end

    -- INNER / SELF / LEFT / FULL all iterate the left side; FULL also appends unmatched right rows.
    local matchedR = (kind == DB.JoinKind.FULL) and {} or nil
    for li, lc in ipairs(left) do
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
        offerYield(li)
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

    -- decide grouped vs row-wise up front (it also gates the scan's LIMIT enforcement)
    local hasAgg = #plan.groupBy > 0
    if not hasAgg then for _, e in ipairs(plan.projection) do if e.kind == "agg" then hasAgg = true; break end end end

    local rows
    if #plan.joins == 0 then
        -- FROM with no joins (the common case): index-narrowed live scan with WHERE fused in --
        -- only surviving rows are copied, and the scan stops at offset+limit when nothing later
        -- can reorder rows. WHERE is fully applied here.
        rows = self:_ScanBase(db, plan, resolver, hasAgg)
    else
        -- JOIN path: snapshot every source up front (the relation is recombined, so per-row lazy
        -- copies buy nothing), then narrow/extend per join, then WHERE over the working copies.
        rows = {}
        for _, r in ipairs(snapshotRows(db, plan.from.table)) do rows[#rows + 1] = { [plan.from.alias] = r } end
        for _, j in ipairs(plan.joins) do
            rows = applyJoin(rows, j, snapshotRows(db, j.table), resolver)
        end
        if plan.where and not plan.where:IsEmpty() then
            local kept = {}
            for i, comp in ipairs(rows) do
                if plan.where:Matches(comp, resolver) then kept[#kept + 1] = comp end
                offerYield(i)
            end
            rows = kept
        end
    end

    local outputs   -- list of { row = <map>, ctx = <compRow for ORDER BY of non-selected cols> }
    if not hasAgg then
        outputs = {}
        for i, comp in ipairs(rows) do
            outputs[#outputs + 1] = { row = self:_ProjectRow(plan.projection, comp, resolver), ctx = comp }
            offerYield(i)
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

-- The no-join FROM/WHERE stage: build the working relation straight off live storage. A top-level
-- AND'ed equality on an indexed column narrows the scan to that index bucket (the whole WHERE still
-- runs on each candidate); only rows the query KEEPS are copied; and when no later stage can
-- reorder or merge rows (no aggregates / GROUP BY / DISTINCT / ORDER BY), the scan ENFORCES LIMIT
-- by stopping at offset+limit rows. Reads LIVE rows, so it chunk-yields under the generation guard
-- (see header). This is the point-lookup fast path: Where("key","=",k):Limit(1) costs one bucket
-- probe and one row copy.
function QueryExecutor:_ScanBase(db, plan, resolver, hasAgg)
    local alias, tname = plan.from.alias, plan.from.table
    local store, index = db:Store(), db:Index()
    local where = plan.where
    if where and where:IsEmpty() then where = nil end

    -- pick the narrowing index: the first top-level AND'ed equality leaf on THIS table's indexed column
    local candCol, candVal
    if where then
        for _, eq in ipairs(where:IndexableEqs() or {}) do
            local a, c = tostring(eq.col):match("^([%w_]+)%.([%w_]+)$")
            if not a or a == alias then
                c = c or eq.col
                if index:HasColumnIndex(tname, c) then candCol, candVal = c, eq.value; break end
            end
        end
    end

    -- LIMIT enforcement: only when post-WHERE storage order survives to the slice stage
    local cap
    if not hasAgg and not plan.distinct and #plan.orderBy == 0 and plan.limit then
        cap = plan.limit + (plan.offset or 0)
    end

    local probe = {}        -- reusable composite for the WHERE test (kept rows get a real copy)
    local restarts = 0
    while true do
        local gen = store:Generation(tname)
        local src = candCol and (index:FindByColumn(tname, candCol, candVal) or {}) or store:Rows(tname) or {}
        local out, dirty = {}, false
        for i = 1, #src do
            local r = src[i]
            local keep = true
            if where then probe[alias] = r; keep = where:Matches(probe, resolver) end
            if keep then
                out[#out + 1] = { [alias] = shallow(r) }   -- copy ONLY the rows the query keeps
                if cap and #out >= cap then break end
            end
            if restarts < MAX_RESTARTS and i % CHUNK == 0 and ns.Worker then
                ns.Worker:MaybeYield()
                if store:Generation(tname) ~= gen then dirty = true; break end
            end
        end
        if not dirty then return out end
        restarts = restarts + 1
    end
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
        for ci, comp in ipairs(rows) do
            local parts = {}
            for i, ref in ipairs(plan.groupBy) do parts[i] = vkey(resolver:Value(comp, ref)) end
            local key = table.concat(parts, SEP)
            local g = groups[key]
            if not g then g = {}; groups[key] = g; order[#order + 1] = key end
            g[#g + 1] = comp
            offerYield(ci)                       -- working copies: safe to chunk without a guard
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
    for oi, o in ipairs(outputs) do
        offerYield(oi)
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
