local addonName, ns = ...

-- Core/DB/Types.lua
-- Frozen vocabulary for the SQL-style database engine: the column/join/cascade/trigger
-- enums, the NULL sentinel, and the per-type value checker. No logic beyond classification --
-- every other DB file dispatches on the constants defined here.
--
-- SQL NULL vs Lua nil: a Lua `nil` in a table means ABSENT KEY, not "present and null", and
-- `pairs`/`#` skip it -- so we cannot store a real NULL as `nil`. Instead every nullable column
-- holds the explicit `ns.DB.NULL` sentinel. `IS NULL` means `value == ns.DB.NULL`. Comparisons
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
