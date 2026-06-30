local addonName, ns = ...
local Class = ns.Class

-- Core/DB/WhereClause.lua
-- The predicate grammar shared by WHERE (and, via the executor, by a trigger WHEN). A clause is a
-- sequence of leaf comparisons joined by AND / OR, with sub-groups for parenthesisation. It is
-- pure: :Matches(compRow, resolver) reads column values through the resolver and returns a boolean.
--
-- Operators: =, !=, <, <=, >, >=, in, like, between, is null, is not null.
-- NULL is TWO-VALUED here (see Types.lua): a NULL operand makes every comparison false; only
-- `is null` / `is not null` inspect nullness. AND binds tighter than OR (standard precedence).
--
--   w:Where("faction", "=", "Horde"):AndWhere("t", "<", 60)
--   w:Where("q", "in", { 1, 2 }):OrWhere("via", "is null")
--   w:Group(function(g) g:Where("a","=",1):OrWhere("b","=",2) end):AndWhere("c","=",3)

ns.DB = ns.DB or {}
local DB = ns.DB

-- ---- LIKE: SQL pattern ('%','_') -> anchored Lua pattern, escaping Lua magic ----
local MAGIC = "^$()%.[]*+-?"
local function likeToLua(sql)
    local out = { "^" }
    for i = 1, #sql do
        local c = sql:sub(i, i)
        if c == "%" then out[#out + 1] = ".*"
        elseif c == "_" then out[#out + 1] = "."
        elseif MAGIC:find(c, 1, true) then out[#out + 1] = "%" .. c
        else out[#out + 1] = c end
    end
    out[#out + 1] = "$"
    return table.concat(out)
end

-- ---- leaf evaluation ------------------------------------------------------
local function sameOrderableType(a, b) return type(a) == type(b) and (type(a) == "number" or type(a) == "string") end

local function evalLeaf(leaf, left, right)
    local op = leaf.op
    if op == "is null"     then return DB.isNull(left) end
    if op == "is not null" then return not DB.isNull(left) end
    if DB.isNull(left) then return false end                 -- two-valued: NULL fails every comparison
    if DB.isNull(right) then return false end                -- comparing against a NULL column also fails
    if op == "="  then return left == right end
    if op == "!=" then return left ~= right end
    if op == "<"  then return sameOrderableType(left, right) and left <  right end
    if op == "<=" then return sameOrderableType(left, right) and left <= right end
    if op == ">"  then return sameOrderableType(left, right) and left >  right end
    if op == ">=" then return sameOrderableType(left, right) and left >= right end
    if op == "in" then
        for _, v in ipairs(right) do if left == v then return true end end
        return false
    end
    if op == "like" then
        return type(left) == "string" and left:find(leaf._pat or likeToLua(right)) ~= nil
    end
    if op == "between" then
        local lo, hi = right[1], right[2]
        return sameOrderableType(left, lo) and sameOrderableType(left, hi) and left >= lo and left <= hi
    end
    error("DB: unknown operator '" .. tostring(op) .. "'", 0)
end

-- Operators that take no value argument.
local NULLARY = { ["is null"] = true, ["is not null"] = true }

local function makeLeaf(col, op, value)
    op = tostring(op):lower()
    local leaf = { kind = "leaf", col = col, op = op, right = value }
    if op == "like" and type(value) == "string" then leaf._pat = likeToLua(value) end
    if not NULLARY[op] and op ~= "like" then
        -- in/between expect tables; the rest expect a scalar -- light shape checks catch typos early.
        if op == "in" and type(value) ~= "table" then error("DB: 'in' needs a list value", 0) end
        if op == "between" and (type(value) ~= "table" or value[1] == nil or value[2] == nil) then
            error("DB: 'between' needs a { lo, hi } value", 0)
        end
    end
    return leaf
end

-- ===========================================================================
local WhereClause = Class.new("DBWhereClause")

function WhereClause:Initialize()
    -- terms interleaved with connectors: { term, "and"|"or", term, ... }
    self:_p().seq = {}
end

function WhereClause:_Append(connector, term)
    local seq = self:_p().seq
    if #seq > 0 then seq[#seq + 1] = connector end
    seq[#seq + 1] = term
end

-- First/AND condition. Accepts a leaf (col, op, value) or a sub-group builder function.
function WhereClause:Where(col, op, value)    self:_Append("and", self:_TermFrom(col, op, value)); return self end
function WhereClause:AndWhere(col, op, value) return self:Where(col, op, value) end
function WhereClause:OrWhere(col, op, value)  self:_Append("or", self:_TermFrom(col, op, value)); return self end

-- A parenthesised sub-clause: :Group(function(g) g:Where(...):OrWhere(...) end)
function WhereClause:Group(fn)    self:_Append("and", self:_BuildGroup(fn)); return self end
function WhereClause:OrGroup(fn)  self:_Append("or", self:_BuildGroup(fn));  return self end

function WhereClause:_BuildGroup(fn)
    local g = WhereClause:New()
    fn(g)
    return g
end

function WhereClause:_TermFrom(col, op, value)
    if type(col) == "function" then return self:_BuildGroup(col) end
    return makeLeaf(col, op, value)
end

function WhereClause:IsEmpty() return #self:_p().seq == 0 end

-- The TOP-LEVEL AND'ed equality leaves, as { col, value } pairs -- the surface the executor uses to
-- pick an index that narrows the base-table scan (every match of the whole clause necessarily
-- satisfies each top-level AND'ed leaf). Returns nil when ANY top-level connector is OR: a
-- disjunction's matches need not satisfy any single leaf, so no one index bounds them. Sub-groups
-- are skipped, not descended -- they still filter via Matches, they just don't nominate an index.
-- Column-vs-column comparisons and NULL literals are skipped too (NULL never equals anything).
function WhereClause:IndexableEqs()
    local seq = self:_p().seq
    local out = {}
    for i = 1, #seq do
        local t = seq[i]
        if t == "or" then return nil end
        if type(t) == "table" and t.kind == "leaf" and t.op == "=" then
            local right = t.right
            if not DB.isNull(right) and not (type(right) == "table" and right.__dbcol) then
                out[#out + 1] = { col = t.col, value = right }
            end
        end
    end
    return out
end

-- Evaluate against a composite row using `resolver:Value(compRow, colRef) -> value|DB.NULL`.
-- Empty clause matches everything. AND binds tighter than OR.
-- Evaluate one term (a leaf comparison, or a sub-group) against compRow through the resolver.
-- HOISTED to a file-local: it used to be a closure rebuilt inside Matches on every call, and Matches
-- runs ONCE PER STORED ROW in _ScanBase -- so a table scan allocated a closure per row. Threading
-- compRow/resolver as arguments keeps it allocation-free.
local function evalTerm(term, compRow, resolver)
    if term.kind == "leaf" then
        local right = term.right
        if type(right) == "table" and right.__dbcol then right = resolver:Value(compRow, right.ref) end
        return evalLeaf(term, resolver:Value(compRow, term.col), right)
    end
    return term:Matches(compRow, resolver)         -- a sub-group
end

function WhereClause:Matches(compRow, resolver)
    local seq = self:_p().seq
    if #seq == 0 then return true end
    local result = false
    local curAnd = evalTerm(seq[1], compRow, resolver)
    local i = 2
    while i <= #seq do
        local connector, term = seq[i], seq[i + 1]
        if connector == "and" then
            curAnd = curAnd and evalTerm(term, compRow, resolver)
        else
            result = result or curAnd
            curAnd = evalTerm(term, compRow, resolver)
        end
        i = i + 2
    end
    return result or curAnd
end

-- Evaluate a single operator against a value (used by HAVING, which compares an aggregate or a
-- grouped column against a literal with the same operator semantics as WHERE).
function DB.evalOp(op, left, value)
    return evalLeaf(makeLeaf(nil, op, value), left, value)
end

-- Mark a WHERE right-hand side as ANOTHER column (so a predicate can compare two columns, e.g. a
-- self join's :Where("a.id", "!=", ns.DB.col("b.id"))). Bare values stay literals.
function DB.col(ref) return { __dbcol = true, ref = ref } end

DB.WhereClause = WhereClause
DB._likeToLua = likeToLua    -- exposed for unit tests
