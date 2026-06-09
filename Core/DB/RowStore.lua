local addonName, ns = ...
local Class = ns.Class

-- Core/DB/RowStore.lua
-- The ONLY thing that reads or writes the persistence slot. A slot is the plain table the
-- SavedVariables library hands back for one database; the engine mutates it in place and WoW
-- serialises it at logout. Shape:
--
--   { _schema = <db version>,
--     _meta   = { autoIds = { <table> = <next id> } },
--     tables  = { <table> = { <row>, <row>, ... } } }
--
-- A row is a flat map of column -> SCALAR. SQL NULL is represented AT REST by the ABSENT key
-- (Lua nil): the shared ns.DB.NULL sentinel is an in-memory token only and must never be stored
-- (WoW would serialise it as an anonymous {} and it would lose its identity across a /reload).
-- RowStore is "dumb" storage: it does no validation and maintains no indexes -- ConstraintEnforcer
-- and IndexManager own those. It just keeps the arrays, the auto-id counters, and the slot shape.

ns.DB = ns.DB or {}
local DB = ns.DB

local RowStore = Class.new("DBRowStore")

function RowStore:Initialize(slot, schema)
    assert(type(slot) == "table", "RowStore: slot must be a table")
    local p = self:_p()
    p.slot = slot
    p.schema = schema
    self:_EnsureShape()
end

-- Make the slot conform to the documented shape, seeding an empty array for every schema table.
function RowStore:_EnsureShape()
    local p = self:_p()
    local s = p.slot
    s._meta = s._meta or {}
    s._meta.autoIds = s._meta.autoIds or {}
    s.tables = s.tables or {}
    for _, tname in ipairs(p.schema:TableNames()) do
        s.tables[tname] = s.tables[tname] or {}
    end
end

function RowStore:Slot()             return self:_p().slot end
function RowStore:Version()          return self:_p().slot._schema end
function RowStore:SetVersion(v)      self:_p().slot._schema = v end

-- The live array of rows for a table (callers iterate it directly; do not hold across a Drop).
function RowStore:Rows(tableName)
    return self:_p().slot.tables[tableName]
end

function RowStore:Count(tableName)
    local rows = self:_p().slot.tables[tableName]
    return rows and #rows or 0
end

-- Allocate the next auto-increment id for a table (monotonic; persisted in _meta.autoIds).
function RowStore:NextId(tableName)
    local autoIds = self:_p().slot._meta.autoIds
    local n = (autoIds[tableName] or 0) + 1
    autoIds[tableName] = n
    return n
end

-- Note the highest id seen for a table so a manually-inserted id never collides with a future
-- auto id (mirrors how SQLite tracks the rowid high-water mark).
function RowStore:NoteId(tableName, id)
    local autoIds = self:_p().slot._meta.autoIds
    if type(id) == "number" and id > (autoIds[tableName] or 0) then autoIds[tableName] = id end
end

-- Append an already-built row (NULL fields must already be absent, not the sentinel).
function RowStore:Append(tableName, row)
    local rows = self:_p().slot.tables[tableName]
    rows[#rows + 1] = row
    return row
end

-- Remove a specific row object (linear search by identity). Returns true if found.
function RowStore:RemoveRow(tableName, row)
    local rows = self:_p().slot.tables[tableName]
    for i = 1, #rows do
        if rows[i] == row then table.remove(rows, i); return true end
    end
    return false
end

-- Empty a table's rows (keeps the table + its auto-id counter).
function RowStore:Truncate(tableName)
    self:_p().slot.tables[tableName] = {}
end

-- Drop a table entirely from the slot (rows + auto-id counter).
function RowStore:DropTable(tableName)
    local s = self:_p().slot
    s.tables[tableName] = nil
    s._meta.autoIds[tableName] = nil
end

DB.RowStore = RowStore
