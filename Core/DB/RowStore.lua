local addonName, ns = ...
local Class = ns.Class

-- Core/DB/RowStore.lua
-- The ONLY thing that reads or writes the persistence backing. The database is ONE shared store,
-- but each TABLE chooses where its rows live (see ns.DB.Scope): a LOCAL table sits in a fresh
-- in-memory backing rebuilt every session, a GLOBAL table in the account saved-variables slot, a
-- CHAR table in this character's slot. RowStore routes every table to the right backing by its
-- scope. Each backing has the same shape:
--
--   { _schema = <db version>,
--     _meta   = { autoIds = { <table> = <next id> } },
--     tables  = { <table> = { <row>, <row>, ... } } }
--
-- A row is a flat map of column -> SCALAR. SQL NULL is represented AT REST by the ABSENT key
-- (Lua nil): the shared ns.DB.NULL sentinel is an in-memory token only and must never be stored
-- (WoW would serialise it as an anonymous {} and it would lose its identity across a /reload).
-- RowStore is "dumb" storage: it does no validation and maintains no indexes -- ConstraintEnforcer
-- and IndexManager own those. It just keeps the arrays, the auto-id counters, and the backing shape.

local DB = ns.DB

local RowStore = Class.new("DBRowStore")

-- slots = { [Scope.LOCAL] = <tbl>, [Scope.GLOBAL] = <tbl>, [Scope.CHAR] = <tbl> } -- any may be
-- omitted (defaults to a fresh in-memory table; the LOCAL backing is ALWAYS in-memory).
function RowStore:Initialize(schema, slots)
    local p = self:_p()
    p.schema = schema
    slots = slots or {}
    p.slots = {
        [DB.Scope.LOCAL]  = slots[DB.Scope.LOCAL]  or {},
        [DB.Scope.GLOBAL] = slots[DB.Scope.GLOBAL] or {},
        [DB.Scope.CHAR]   = slots[DB.Scope.CHAR]   or {},
    }
    p.gen = {}        -- table -> mutation counter (in-memory only; see Generation below)
    self:_EnsureShape()
end

-- Monotonic per-table MUTATION counter (never persisted). A chunked query that yielded mid-scan
-- compares generations across the yield and restarts if the table changed underneath it (see
-- QueryExecutor); Database:Update touches it too, since an update mutates rows in place.
function RowStore:Generation(tableName) return self:_p().gen[tableName] or 0 end
function RowStore:Touch(tableName)
    local g = self:_p().gen
    g[tableName] = (g[tableName] or 0) + 1
end

-- The backing table for `tableName`, chosen by the table's scope.
function RowStore:_Backing(tableName)
    return self:_p().slots[self:_p().schema:Table(tableName):Scope()]
end

-- Make each backing conform to the documented shape, seeding an empty array per schema table.
function RowStore:_EnsureShape()
    local p = self:_p()
    for _, s in pairs(p.slots) do
        s._meta = s._meta or {}
        s._meta.autoIds = s._meta.autoIds or {}
        s.tables = s.tables or {}
    end
    for _, tname in ipairs(p.schema:TableNames()) do
        local b = self:_Backing(tname)
        b.tables[tname] = b.tables[tname] or {}
    end
end

-- The DB schema version is stamped on the GLOBAL backing (the canonical persisted one).
function RowStore:Version()          return self:_p().slots[DB.Scope.GLOBAL]._schema end
function RowStore:SetVersion(v)      self:_p().slots[DB.Scope.GLOBAL]._schema = v end

-- The live array of rows for a table (callers iterate it directly; do not hold across a Drop).
function RowStore:Rows(tableName)
    return self:_Backing(tableName).tables[tableName]
end

function RowStore:Count(tableName)
    local rows = self:Rows(tableName)
    return rows and #rows or 0
end

-- Allocate the next auto-increment id for a table (monotonic; persisted in the backing's _meta).
function RowStore:NextId(tableName)
    local autoIds = self:_Backing(tableName)._meta.autoIds
    local n = (autoIds[tableName] or 0) + 1
    autoIds[tableName] = n
    return n
end

-- Note the highest id seen for a table so a manually-inserted id never collides with a future
-- auto id (mirrors how SQLite tracks the rowid high-water mark).
function RowStore:NoteId(tableName, id)
    local autoIds = self:_Backing(tableName)._meta.autoIds
    if type(id) == "number" and id > (autoIds[tableName] or 0) then autoIds[tableName] = id end
end

-- Append an already-built row (NULL fields must already be absent, not the sentinel).
function RowStore:Append(tableName, row)
    local rows = self:Rows(tableName)
    rows[#rows + 1] = row
    self:Touch(tableName)
    return row
end

-- Remove a specific row object (linear search by identity). Returns true if found.
function RowStore:RemoveRow(tableName, row)
    local rows = self:Rows(tableName)
    for i = 1, #rows do
        if rows[i] == row then table.remove(rows, i); self:Touch(tableName); return true end
    end
    return false
end

-- Empty a table's rows (keeps the table + its auto-id counter).
function RowStore:Truncate(tableName)
    self:_Backing(tableName).tables[tableName] = {}
    self:Touch(tableName)
end

-- Drop a table entirely from its backing (rows + auto-id counter).
function RowStore:DropTable(tableName)
    local b = self:_Backing(tableName)
    b.tables[tableName] = nil
    b._meta.autoIds[tableName] = nil
    self:Touch(tableName)
end

DB.RowStore = RowStore
