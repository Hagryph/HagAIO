local addonName, ns = ...

-- Core/DB/Types.lua
-- Frozen vocabulary for the SQL-style database engine: the column/join/cascade/trigger
-- enums, the NULL sentinel, the per-type value checker, and the shared value/key encoding
-- helpers every layer's keys must agree on.
--
-- SQL NULL vs Lua nil: AT REST (in a stored row) NULL is the ABSENT key -- plain Lua `nil`;
-- the `ns.DB.NULL` sentinel is an IN-MEMORY token only and must never be stored (it would
-- serialise as an anonymous {} and lose its identity across a /reload -- see
-- Core/DB/RowStore.lua, the authoritative storage rule). The sentinel exists for the places
-- nil can't flow: writing NULL through Update/Insert (`{ col = DB.NULL }`), projecting a NULL
-- cell into a result row, and trigger contexts. So when READING a cell, "is NULL" means
-- `v == nil or v == DB.NULL` (DB.isSet below is the shared guard). Comparisons
-- (`=`,`<`,`IN`,`LIKE`,`BETWEEN`) against NULL are TWO-VALUED here: they yield false; only
-- `IS NULL` / `IS NOT NULL` inspect nullness. (SQL is three-valued; two-valued is the pragmatic
-- choice for an addon and is applied consistently across the engine.)

ns.DB = ns.DB or {}
local DB = ns.DB
local Enum = ns.Enum

-- ---- the NULL sentinel ----------------------------------------------------
-- A unique, frozen, single-instance table. Identity comparison (== NULL) is the nullness test.
DB.NULL = setmetatable({}, {
    __tostring   = function() return "NULL" end,
    __newindex   = function() error("ns.DB.NULL is read-only", 2) end,
    __metatable  = false,
})

function DB.isNull(v) return v == DB.NULL end

-- Present and non-NULL? The shared row-cell guard (a read cell is NULL when the key is
-- absent OR carries the in-memory sentinel -- see the header).
function DB.isSet(v) return v ~= nil and v ~= DB.NULL end

-- ---- value/key encoding -----------------------------------------------------
-- ONE encoding for every layer that builds keyed lookups over row values (IndexManager's
-- PK/unique/column maps, QueryExecutor's grouping/distinct, Database's load-time de-dup).
-- They must stay byte-compatible with each other, so they live here, not per-file.

DB.KEY_SEP = "\31"   -- unit separator: safe between composite key parts

-- A type-tagged, collision-free string for one scalar value (so number 1 ~= string "1",
-- and true ~= "true"). NULL/absent returns `nullKey` when given (grouping/distinct key
-- NULL cells together), else nil (indexes skip NULLs entirely).
function DB.valueKey(v, nullKey)
    if v == nil or v == DB.NULL then return nullKey end
    local t = type(v)
    if t == "string"  then return "s" .. v end
    if t == "number"  then return "n" .. tostring(v) end
    if t == "boolean" then return v and "b1" or "b0" end
    return "?" .. tostring(v)
end

-- Combined key over an ordered column list; nil if ANY part is NULL (SQL allows many NULLs
-- in a unique key, so NULL rows don't participate in keyed lookups / de-duplication).
function DB.combinedKey(row, cols)
    local parts = {}
    for i = 1, #cols do
        local k = DB.valueKey(row[cols[i]])
        if k == nil then return nil end
        parts[i] = k
    end
    return table.concat(parts, DB.KEY_SEP)
end

-- The bare column name of a "alias.col" ref ("col" passes through unchanged).
function DB.bareName(ref) return tostring(ref):match("([%w_]+)$") or ref end

-- ---- enums (frozen; see ns.Enum) ------------------------------------------
-- Column storage types. Values are the canonical lowercase names so a schema can be authored
-- with either the enum (DB.ColumnType.INTEGER) or the bare string ("integer").
-- DELIBERATELY no "table" type: a database NEVER stores a raw Lua table in a cell. Structured /
-- nested data must be expressed RELATIONALLY -- a child table with a foreign key back to its
-- parent -- never a blob column. A column only ever holds a scalar.
DB.ColumnType = Enum.new("DBColumnType", {
    INTEGER = "integer",   -- a whole number
    NUMBER  = "number",    -- any Lua number
    TEXT    = "text",      -- a string
    BOOLEAN = "boolean",   -- true / false
})

DB.JoinKind = Enum.new("DBJoinKind", {
    INNER = "inner", LEFT = "left", RIGHT = "right", FULL = "full", CROSS = "cross",
    SELF = "self",   -- a table joined to itself under a mandatory alias (inner-join semantics)
})

DB.OnDelete = Enum.new("DBOnDelete", {
    CASCADE   = "cascade",     -- delete the children too
    RESTRICT  = "restrict",    -- block the parent delete while children exist
    SET_NULL  = "set_null",    -- null the child FK (requires a nullable FK column)
    NO_ACTION = "no_action",   -- leave children dangling (no enforcement on delete)
})

-- Where a TABLE's rows live. The database is ONE shared store; each table chooses its scope:
--   LOCAL  -- in-memory only, rebuilt from code each session (reference data: faction, zones);
--   GLOBAL -- account-wide saved variables (shared across all characters);
--   CHAR   -- this character's saved variables.
DB.Scope = Enum.new("DBScope", { LOCAL = "local", GLOBAL = "global", CHAR = "char" })

DB.TriggerTime  = Enum.new("DBTriggerTime",  { BEFORE = "before", AFTER = "after", INSTEAD_OF = "instead_of" })
DB.TriggerEvent = Enum.new("DBTriggerEvent", { INSERT = "insert", UPDATE = "update", DELETE = "delete" })
DB.TriggerLevel = Enum.new("DBTriggerLevel", { ROW = "row", STATEMENT = "statement" })

-- Comparison operators usable in WHERE / HAVING / ON / a trigger WHEN. The user-facing symbol
-- (left) is what the fluent API takes; WhereClause owns the evaluators.
DB.Op = Enum.new("DBOp", {
    EQ      = "=",
    NE      = "!=",
    LT      = "<",
    LE      = "<=",
    GT      = ">",
    GE      = ">=",
    IN      = "in",
    LIKE    = "like",
    BETWEEN = "between",
    IS_NULL     = "is null",
    IS_NOT_NULL = "is not null",
})

-- ---- type checking --------------------------------------------------------
-- Per-type validators. NULL is handled by the constraint layer (nullability), never here, so a
-- checker only ever sees a concrete value. INTEGER accepts a whole-valued Lua number (LuaJIT has
-- no separate integer type, so we test divisibility rather than a subtype).
local CHECKERS = {
    integer = function(v) return type(v) == "number" and v == math.floor(v) and v ~= math.huge and v ~= -math.huge end,
    number  = function(v) return type(v) == "number" end,
    text    = function(v) return type(v) == "string" end,
    boolean = function(v) return type(v) == "boolean" end,
}

-- Normalise a column-type spec (enum value or bare string) to its canonical name, or nil.
function DB.normalizeType(t)
    if type(t) ~= "string" then return nil end
    return CHECKERS[t] and t or nil
end

-- Does `value` satisfy column type `colType`? `value` must not be NULL (caller checks that first).
function DB.checkType(colType, value)
    local fn = CHECKERS[colType]
    return fn ~= nil and fn(value)
end
