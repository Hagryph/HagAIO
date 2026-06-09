local addonName, ns = ...
local Class = ns.Class

-- Core/DB/IndexManager.lua
-- In-memory lookup structures derived from the rows: the primary-key map, one map per UNIQUE
-- constraint, and one map per single-column index (which also covers PK/unique single columns so
-- foreign-key existence checks and equality lookups are O(1)). These are NEVER persisted -- they
-- are rebuilt from the RowStore on load and maintained incrementally as rows are inserted,
-- updated and deleted. The IndexManager validates nothing on its own; it answers "does this key
-- already exist?" and "which rows have column = value?" for the constraint + query layers.
--
-- NULL handling: a key column that is NULL (absent) is NOT indexed. SQL lets a UNIQUE column hold
-- many NULLs, and a NULL never equals anything, so NULL rows simply don't participate in any map.

ns.DB = ns.DB or {}
local DB = ns.DB

local SEP = "\31"   -- unit separator: safe between composite key parts

-- A type-tagged, collision-free string for one scalar value (so number 1 ~= string "1",
-- and true ~= "true"). Returns nil for a NULL/absent value (callers skip indexing it).
local function valueKey(v)
    if v == nil or v == DB.NULL then return nil end
    local t = type(v)
    if t == "string"  then return "s" .. v end
    if t == "number"  then return "n" .. tostring(v) end
    if t == "boolean" then return v and "b1" or "b0" end
    return "?" .. tostring(v)
end

-- Combined key over an ordered list of columns; nil if ANY part is NULL (composite NULLs, like
-- single NULLs, are not enforced/looked up).
local function combinedKey(row, cols)
    local parts = {}
    for i = 1, #cols do
        local k = valueKey(row[cols[i]])
        if k == nil then return nil end
        parts[i] = k
    end
    return table.concat(parts, SEP)
end

local IndexManager = Class.new("DBIndexManager")

function IndexManager:Initialize(schema, rowStore)
    local p = self:_p()
    p.schema = schema
    p.store = rowStore
    self:Rebuild()
end

-- Throw away every map and re-derive them from the current rows. Called once on load and whenever
-- the row set is replaced wholesale (e.g. after a migration).
function IndexManager:Rebuild()
    local p = self:_p()
    p.pk = {}        -- table -> { combinedKey -> row }
    p.unique = {}    -- table -> list of { cols, map = combinedKey -> row }
    p.col = {}       -- table -> col -> { valueKey -> { row, ... } }
    for _, tname in ipairs(p.schema:TableNames()) do
        self:_InitTable(tname)
        for _, row in ipairs(p.store:Rows(tname) or {}) do
            self:OnInsert(tname, row)
        end
    end
end

function IndexManager:_InitTable(tname)
    local p = self:_p()
    local tbl = p.schema:Table(tname)

    local pkCols = tbl:PrimaryKey()
    if #pkCols > 0 then p.pk[tname] = { cols = pkCols, map = {} } end

    p.unique[tname] = {}
    for _, cols in ipairs(tbl:Uniques()) do
        p.unique[tname][#p.unique[tname] + 1] = { cols = cols, map = {} }
    end

    -- Single-column maps for: PK members, single-column UNIQUE columns, and declared index columns.
    -- These back FindByColumn (FK existence + equality query lookups).
    p.col[tname] = {}
    local function ensureCol(c) p.col[tname][c] = p.col[tname][c] or {} end
    for _, c in ipairs(pkCols) do ensureCol(c) end
    for _, cols in ipairs(tbl:Uniques()) do if #cols == 1 then ensureCol(cols[1]) end end
    for _, idx in ipairs(tbl:Indices()) do for _, c in ipairs(idx.columns) do ensureCol(c) end end
end

-- ---- incremental maintenance (rows are pre-validated by ConstraintEnforcer) ----
function IndexManager:OnInsert(tname, row)
    local p = self:_p()
    local pk = p.pk[tname]
    if pk then local k = combinedKey(row, pk.cols); if k then pk.map[k] = row end end
    for _, u in ipairs(p.unique[tname] or {}) do
        local k = combinedKey(row, u.cols); if k then u.map[k] = row end
    end
    for c, map in pairs(p.col[tname] or {}) do
        local k = valueKey(row[c])
        if k then local list = map[k]; if not list then list = {}; map[k] = list end; list[#list + 1] = row end
    end
end

function IndexManager:OnDelete(tname, row)
    local p = self:_p()
    local pk = p.pk[tname]
    if pk then local k = combinedKey(row, pk.cols); if k then pk.map[k] = nil end end
    for _, u in ipairs(p.unique[tname] or {}) do
        local k = combinedKey(row, u.cols); if k and u.map[k] == row then u.map[k] = nil end
    end
    for c, map in pairs(p.col[tname] or {}) do
        local k = valueKey(row[c])
        if k and map[k] then
            local list = map[k]
            for i = 1, #list do if list[i] == row then table.remove(list, i); break end end
            if #list == 0 then map[k] = nil end
        end
    end
end

-- ---- queries used by ConstraintEnforcer + QueryExecutor ----
-- The row with this primary key, or nil. pkValues is a { col = value } map or an ordered list.
function IndexManager:FindByPrimaryKey(tname, row)
    local p = self:_p()
    local pk = p.pk[tname]
    if not pk then return nil end
    local k = combinedKey(row, pk.cols)
    return k and pk.map[k] or nil
end

-- If inserting/updating `row` would duplicate a UNIQUE (or PK) key held by a DIFFERENT row,
-- return that violated constraint's column list; otherwise nil. `exceptRow` is the row being
-- updated (so it doesn't clash with itself).
function IndexManager:UniqueViolation(tname, row, exceptRow)
    local p = self:_p()
    local pk = p.pk[tname]
    if pk then
        local k = combinedKey(row, pk.cols)
        if k then local hit = pk.map[k]; if hit and hit ~= exceptRow then return pk.cols end end
    end
    for _, u in ipairs(p.unique[tname] or {}) do
        local k = combinedKey(row, u.cols)
        if k then local hit = u.map[k]; if hit and hit ~= exceptRow then return u.cols end end
    end
    return nil
end

-- Rows where column == value (only for indexed columns: PK/unique-single/declared index). Returns
-- a (possibly empty) array. Used for FK existence and equality-predicate acceleration.
function IndexManager:FindByColumn(tname, col, value)
    local p = self:_p()
    local map = p.col[tname] and p.col[tname][col]
    if not map then return nil end          -- column isn't indexed; caller falls back to a scan
    local k = valueKey(value)
    return (k and map[k]) or {}
end

-- Is `col` indexed for this table (so FindByColumn is usable)?
function IndexManager:HasColumnIndex(tname, col)
    local p = self:_p()
    return (p.col[tname] and p.col[tname][col]) ~= nil
end

DB.IndexManager = IndexManager
