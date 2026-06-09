local addonName, ns = ...
local Class = ns.Class

-- Core/DB/Constraints.lua
-- ConstraintEnforcer: turns a caller's { col = value } map into a validated, normalised row, and
-- guards every write against the schema's rules:
--   * type-checking each scalar against its column type,
--   * NOT NULL (with default-fill and auto-increment),
--   * UNIQUE / PRIMARY KEY (via the IndexManager),
--   * FOREIGN KEY parent-exists on insert/update,
--   * and the reverse direction on delete: it knows which child tables reference a parent, so the
--     Database can CASCADE / RESTRICT / SET NULL.
-- It validates only; the Database performs the actual mutation + index maintenance + triggers.
-- NULL is normalised to an ABSENT key in the stored row (never the sentinel) so it persists safely.

ns.DB = ns.DB or {}
local DB = ns.DB

local function fail(msg) error("DB: " .. msg, 0) end

local ConstraintEnforcer = Class.new("DBConstraintEnforcer")

function ConstraintEnforcer:Initialize(schema, index, store)
    local p = self:_p()
    p.schema = schema
    p.index = index
    p.store = store
    self:_BuildChildRefs()
end

-- childrenOf[parentTable] = list of { childTable, childCol, refCol, onDelete } -- the reverse
-- foreign-key map used to drive cascade on delete.
function ConstraintEnforcer:_BuildChildRefs()
    local p = self:_p()
    p.childrenOf = {}
    for _, tname in ipairs(p.schema:TableNames()) do
        for _, fk in ipairs(p.schema:Table(tname):ForeignKeys()) do
            local list = p.childrenOf[fk.table]
            if not list then list = {}; p.childrenOf[fk.table] = list end
            list[#list + 1] = { childTable = tname, childCol = fk.column, refCol = fk.refColumn, onDelete = fk.onDelete }
        end
    end
end

function ConstraintEnforcer:ChildRefs(parentTable) return self:_p().childrenOf[parentTable] or {} end

-- Build a validated row from `values`. `nextId(table)` supplies an auto-increment id. Raises on
-- any violation. Unknown columns are rejected (a typo silently dropping data is exactly what this
-- layer exists to prevent).
function ConstraintEnforcer:BuildRow(tname, values, nextId)
    local p = self:_p()
    local tbl = p.schema:Table(tname)
    assert(tbl, ("unknown table '%s'"):format(tostring(tname)))
    values = values or {}

    for k in pairs(values) do
        if not tbl:HasColumn(k) then fail(("table '%s' has no column '%s'"):format(tname, tostring(k))) end
    end

    local row = {}
    for _, col in ipairs(tbl:Columns()) do
        local cn = col:Name()
        local v = values[cn]
        if v == DB.NULL then v = nil end                       -- explicit NULL -> absent
        if v == nil then
            if col:IsAuto() then
                v = nextId and nextId(tname) or nil
            elseif col:HasDefault() then
                v = col:Default()
            elseif not col:IsNullable() then
                fail(("NOT NULL constraint failed: %s.%s"):format(tname, cn))
            end
        end
        if v ~= nil then
            if not DB.checkType(col:Type(), v) then
                fail(("type error: %s.%s expects %s, got %s (%s)")
                    :format(tname, cn, col:Type(), type(v), tostring(v)))
            end
            row[cn] = v
            if col:IsAuto() then p.store:NoteId(tname, v) end   -- keep the high-water mark ahead of manual ids
        end
    end
    return row
end

-- Re-validate an already-built row's NOT NULL + types (used after a BEFORE trigger may have edited
-- it, so a trigger can't smuggle a wrong-typed / null value past the schema).
function ConstraintEnforcer:RecheckTypes(tname, row)
    local tbl = self:_p().schema:Table(tname)
    for _, col in ipairs(tbl:Columns()) do
        local cn, v = col:Name(), row[col:Name()]
        if v == nil then
            if not col:IsNullable() then fail(("NOT NULL constraint failed: %s.%s"):format(tname, cn)) end
        elseif not DB.checkType(col:Type(), v) then
            fail(("type error: %s.%s expects %s, got %s"):format(tname, cn, col:Type(), type(v)))
        end
    end
end

-- Raise if `row` duplicates a PK/UNIQUE key held by a different row (`exceptRow` is skipped, for
-- updates). The message names whether it was the PRIMARY KEY or a UNIQUE constraint.
function ConstraintEnforcer:CheckUnique(tname, row, exceptRow)
    local p = self:_p()
    local cols = p.index:UniqueViolation(tname, row, exceptRow)
    if cols then
        local pk, isPK = p.schema:Table(tname):PrimaryKey(), false
        if #pk == #cols then
            isPK = true
            for i = 1, #pk do if pk[i] ~= cols[i] then isPK = false; break end end
        end
        fail(("%s constraint failed: %s(%s)"):format(isPK and "PRIMARY KEY" or "UNIQUE", tname, table.concat(cols, ", ")))
    end
end

-- Raise if any foreign key in `row` points at a parent that does not exist.
function ConstraintEnforcer:CheckForeignKeys(tname, row)
    local p = self:_p()
    for _, fk in ipairs(p.schema:Table(tname):ForeignKeys()) do
        local v = row[fk.column]
        if v ~= nil then                                       -- a NULL FK is allowed (optional link)
            if not self:_ParentExists(fk, v) then
                fail(("FOREIGN KEY constraint failed: %s.%s -> %s.%s (%s)")
                    :format(tname, fk.column, fk.table, fk.refColumn, tostring(v)))
            end
        end
    end
end

function ConstraintEnforcer:_ParentExists(fk, value)
    local p = self:_p()
    local hits = p.index:FindByColumn(fk.table, fk.refColumn, value)
    if hits then return #hits > 0 end
    -- Not indexed (shouldn't happen for a PK/unique target) -> scan fallback.
    for _, r in ipairs(p.store:Rows(fk.table) or {}) do if r[fk.refColumn] == value then return true end end
    return false
end

DB.ConstraintEnforcer = ConstraintEnforcer
