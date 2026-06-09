local addonName, ns = ...
local Class = ns.Class

-- Core/DB/Database.lua
-- The database facade. One instance per registered database, bound to a Schema and a persistence
-- slot. It wires the focused collaborators -- RowStore (storage), IndexManager (lookups),
-- ConstraintEnforcer (validation + cascade refs) -- and exposes the public surface:
--   * DML : Insert / InsertAll / Update / Delete (with constraint checks + cascading delete),
--   * DDL : Truncate / DropTable,
--   * reads: Select(...) -> a fluent QueryBuilder, and View(name) (added by the query layer).
-- Tables/columns/indices/views/triggers are declared up front in the Schema (declarative DDL), so
-- there is no runtime CreateTable; the slot is shaped from the schema on construction.
--
-- Mutation order around every row write is fixed so triggers and constraints compose predictably:
--   BEFORE trigger -> constraint checks + store/index write -> AFTER trigger
-- (the TriggerManager is attached in Phase 5; until then the trigger hooks are inert pass-throughs).

ns.DB = ns.DB or {}
local DB = ns.DB

-- Public engine API kept for callers even when the current addon doesn't exercise every method.
-- deadcode-allow: InsertAll, Names, Slot, HasTable

local Database = Class.new("Database")

-- `globalSlot` is the GLOBAL (account) backing; opts may add { charSlot, localSlot } for the other
-- scopes (each defaults to a fresh in-memory table -- LOCAL is always in-memory). A bare slot keeps
-- back-compat: a schema whose tables are all GLOBAL stores everything there.
-- opts = { charSlot, localSlot, crossResolver, crossChildren }
function Database:Initialize(name, schema, globalSlot, opts)
    opts = opts or {}
    local p = self:_p()
    p.name = name
    p.schema = schema
    local slots = {
        [DB.Scope.LOCAL]  = opts.localSlot,
        [DB.Scope.GLOBAL] = globalSlot or {},
        [DB.Scope.CHAR]   = opts.charSlot,
    }
    p.store = DB.RowStore:New(schema, slots)
    p.index = DB.IndexManager:New(schema, p.store)
    p.enforcer = DB.ConstraintEnforcer:New(schema, p.index, p.store, opts.crossResolver)
    p.triggers = DB.TriggerManager:New(schema)   -- inert if the schema declares no triggers
    p.crossChildren = opts.crossChildren         -- function(tname) -> cross-DB child refs (rarely used now)
    if p.store:Version() == nil then p.store:SetVersion(schema:Version()) end
    self:_RunSeeds()
end

-- Seed any table that declares a seed(db) and is currently empty: a LOCAL reference table every
-- session (it starts empty), a GLOBAL/CHAR table once on first install. Runs after the indexes are
-- built so seeded rows are validated + indexed like any insert.
function Database:_RunSeeds()
    local p = self:_p()
    for _, tname in ipairs(p.schema:TableNames()) do
        local seed = p.schema:Table(tname):Seed()
        if seed and p.store:Count(tname) == 0 then seed(self) end
    end
end

function Database:Name()     return self:_p().name end
function Database:Schema()   return self:_p().schema end
function Database:Index()    return self:_p().index end
function Database:Store()    return self:_p().store end

-- ---- trigger hooks --------------------------------------------------------
-- _FireRow returns (proceed, replaced):
--   proceed=false  -> a BEFORE trigger vetoed the op; skip it.
--   replaced=true  -> an INSTEAD_OF trigger handled it; skip the default write + AFTER.
function Database:_FireRow(time, event, tname, newRow, oldRow)
    local tm = self:_p().triggers
    if not tm then return true, false end
    return tm:FireRow(self, time, event, tname, newRow, oldRow)
end
function Database:_FireStmt(time, event, tname)
    local tm = self:_p().triggers
    if tm then tm:FireStatement(self, time, event, tname) end
end

-- ---- INSERT ---------------------------------------------------------------
function Database:Insert(tname, values)
    local p = self:_p()
    local INSERT = DB.TriggerEvent.INSERT
    self:_FireStmt(DB.TriggerTime.BEFORE, INSERT, tname)
    local nextId = function(t) return p.store:NextId(t) end
    local row = p.enforcer:BuildRow(tname, values, nextId)

    local proceed, replaced = self:_FireRow(DB.TriggerTime.BEFORE, INSERT, tname, row, nil)
    if not proceed then return nil end
    if not replaced then
        -- a BEFORE trigger may have edited the row; auto/default columns are already filled, but
        -- re-validate types so a trigger can't smuggle a bad value past the schema
        p.enforcer:RecheckTypes(tname, row)
        p.enforcer:CheckUnique(tname, row, nil)
        p.enforcer:CheckForeignKeys(tname, row)
        p.store:Append(tname, row)
        p.index:OnInsert(tname, row)
        self:_FireRow(DB.TriggerTime.AFTER, INSERT, tname, row, nil)
    end
    self:_FireStmt(DB.TriggerTime.AFTER, INSERT, tname)
    return row
end

function Database:InsertAll(tname, list)
    local out = {}
    for _, values in ipairs(list or {}) do out[#out + 1] = self:Insert(tname, values) end
    return out
end

-- ---- UPDATE ---------------------------------------------------------------
-- Apply `changes` ({ col = value | DB.NULL }) to every row matching `predicate(row)` (nil = all).
-- Returns the number of rows changed. Note: referential ON UPDATE actions are out of scope -- a
-- PK edit that children reference is the caller's responsibility (rare; flagged if it breaks FKs).
function Database:Update(tname, changes, predicate)
    local p = self:_p()
    local tbl = p.schema:Table(tname)
    assert(tbl, ("unknown table '%s'"):format(tostring(tname)))
    local count = 0
    self:_FireStmt(DB.TriggerTime.BEFORE, DB.TriggerEvent.UPDATE, tname)
    -- snapshot the matching rows first (we mutate the array's contents, not its membership)
    local targets = {}
    for _, row in ipairs(p.store:Rows(tname)) do
        if predicate == nil or predicate(row) then targets[#targets + 1] = row end
    end
    for _, row in ipairs(targets) do
        -- merged candidate values: existing fields overlaid with the requested changes
        local merged = {}
        for _, col in ipairs(tbl:Columns()) do merged[col:Name()] = row[col:Name()] end
        for k, v in pairs(changes) do merged[k] = v end
        local candidate = p.enforcer:BuildRow(tname, merged, nil)

        local old = self:_Snapshot(row)
        local proceed, replaced = self:_FireRow(DB.TriggerTime.BEFORE, DB.TriggerEvent.UPDATE, tname, candidate, old)
        if proceed and not replaced then
            p.enforcer:RecheckTypes(tname, candidate)       -- guard a BEFORE trigger's edits
            p.enforcer:CheckUnique(tname, candidate, row)
            p.enforcer:CheckForeignKeys(tname, candidate)
            p.index:OnDelete(tname, row)
            for _, col in ipairs(tbl:Columns()) do row[col:Name()] = candidate[col:Name()] end
            p.index:OnInsert(tname, row)
            count = count + 1
            self:_FireRow(DB.TriggerTime.AFTER, DB.TriggerEvent.UPDATE, tname, row, old)
        end
    end
    self:_FireStmt(DB.TriggerTime.AFTER, DB.TriggerEvent.UPDATE, tname)
    return count
end

-- ---- DELETE (with cascading) ----------------------------------------------
function Database:Delete(tname, predicate)
    local p = self:_p()
    assert(p.schema:Table(tname), ("unknown table '%s'"):format(tostring(tname)))
    local targets = {}
    for _, row in ipairs(p.store:Rows(tname)) do
        if predicate == nil or predicate(row) then targets[#targets + 1] = row end
    end
    self:_FireStmt(DB.TriggerTime.BEFORE, DB.TriggerEvent.DELETE, tname)
    local count = 0
    for _, row in ipairs(targets) do
        count = count + self:_DeleteRow(tname, row)
    end
    self:_FireStmt(DB.TriggerTime.AFTER, DB.TriggerEvent.DELETE, tname)
    return count
end

-- Child rows of `parentTable` referencing `value` through `ref` (uses the FK index; scans only if
-- somehow unindexed). Returns a fresh array (safe to delete from during iteration).
function Database:_ChildRows(ref, value)
    local p = self:_p()
    local hits = p.index:FindByColumn(ref.childTable, ref.childCol, value)
    local out = {}
    if hits then
        for i = 1, #hits do out[i] = hits[i] end
    else
        for _, r in ipairs(p.store:Rows(ref.childTable) or {}) do
            if r[ref.childCol] == value then out[#out + 1] = r end
        end
    end
    return out
end

function Database:_DeleteRow(tname, row)
    local p = self:_p()
    local refs = p.enforcer:ChildRefs(tname)                 -- same-DB child refs
    local cross = p.crossChildren and p.crossChildren(tname) or {}   -- cross-DB child refs

    -- 1) RESTRICT: block the delete if any restricting child (here or in another DB) still refers.
    for _, ref in ipairs(refs) do
        if ref.onDelete == DB.OnDelete.RESTRICT and #self:_ChildRows(ref, row[ref.refCol]) > 0 then
            error(("DB: RESTRICT: %s row still referenced by %s.%s"):format(tname, ref.childTable, ref.childCol), 0)
        end
    end
    for _, cref in ipairs(cross) do
        if cref.onDelete == DB.OnDelete.RESTRICT then
            local hits = cref.targetDb:Index():FindByColumn(cref.childTable, cref.childCol, row[cref.refCol])
            if hits and #hits > 0 then
                error(("DB: RESTRICT: %s row still referenced by %s.%s.%s")
                    :format(tname, cref.targetDb:Name(), cref.childTable, cref.childCol), 0)
            end
        end
    end

    local proceed, replaced = self:_FireRow(DB.TriggerTime.BEFORE, DB.TriggerEvent.DELETE, tname, nil, self:_Snapshot(row))
    if not proceed then return 0 end
    if replaced then return 1 end          -- an INSTEAD_OF trigger handled the delete; skip the base op

    -- 2) CASCADE / SET NULL the children before removing the parent.
    for _, ref in ipairs(refs) do
        local value = row[ref.refCol]
        if ref.onDelete == DB.OnDelete.CASCADE then
            for _, kid in ipairs(self:_ChildRows(ref, value)) do self:_DeleteRow(ref.childTable, kid) end
        elseif ref.onDelete == DB.OnDelete.SET_NULL then
            for _, kid in ipairs(self:_ChildRows(ref, value)) do
                p.index:OnDelete(ref.childTable, kid)
                kid[ref.childCol] = nil
                p.index:OnInsert(ref.childTable, kid)
            end
        end
    end
    -- cross-DB children go through the OTHER database's public API, so its own cascades + triggers fire
    for _, cref in ipairs(cross) do
        local value = row[cref.refCol]
        if cref.onDelete == DB.OnDelete.CASCADE then
            cref.targetDb:Delete(cref.childTable, function(r) return r[cref.childCol] == value end)
        elseif cref.onDelete == DB.OnDelete.SET_NULL then
            cref.targetDb:Update(cref.childTable, { [cref.childCol] = DB.NULL },
                function(r) return r[cref.childCol] == value end)
        end
    end

    -- 3) remove the row itself.
    local old = self:_Snapshot(row)
    p.index:OnDelete(tname, row)
    p.store:RemoveRow(tname, row)
    self:_FireRow(DB.TriggerTime.AFTER, DB.TriggerEvent.DELETE, tname, nil, old)
    return 1
end

-- Rebuild the in-memory indexes from current rows (used after a migration bulk-edits storage).
function Database:RebuildIndexes() self:_p().index:Rebuild() end

-- A shallow copy of a stored row (used as the OLD/NEW trigger context, so handlers can't mutate
-- live storage).
function Database:_Snapshot(row)
    local out = {}
    for k, v in pairs(row) do out[k] = v end
    return out
end

-- ---- reads ----------------------------------------------------------------
-- Start a fluent SELECT. The projection is column refs ("col" / "alias.col" / "*" / "alias.*")
-- and/or DB.Fn aggregates.
function Database:Select(...)
    return DB.QueryBuilder:New(self, { ... })
end

-- Run a declared view's query (its build(db) returns a QueryBuilder) and return its rows.
function Database:View(name)
    local v = self:_p().schema:Views()[name]
    assert(v, ("DB: unknown view '%s'"):format(tostring(name)))
    local qb = v.build(self)
    return qb:Run()
end

-- ---- DDL ------------------------------------------------------------------
function Database:Truncate(tname)
    local p = self:_p()
    p.store:Truncate(tname)
    p.index:Rebuild()
end

function Database:DropTable(tname)
    local p = self:_p()
    p.store:DropTable(tname)
    p.index:Rebuild()
end

DB.Database = Database
