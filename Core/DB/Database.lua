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

-- `slots` maps a scope to its backing table: { [Scope.GLOBAL] = <account slot>, [Scope.CHAR] =
-- <char slot> }. Any omitted scope (and LOCAL always) gets a fresh in-memory backing.
function Database:Initialize(name, schema, slots)
    local p = self:_p()
    p.name = name
    p.schema = schema
    p.store = DB.RowStore:New(schema, slots or {})
    self:_Conform()                              -- drop persisted rows that violate the current schema
    p.index = DB.IndexManager:New(schema, p.store)
    p.enforcer = DB.ConstraintEnforcer:New(schema, p.index, p.store)
    p.triggers = DB.TriggerManager:New(schema)   -- inert if the schema declares no triggers
    if p.store:Version() == nil then p.store:SetVersion(schema:Version()) end
    self:_RunSeeds()
end

-- Does a stored row satisfy the schema's column rules (NOT NULL + types)? Used by the load-time
-- conformance sweep; unique/FK aren't checked here (they need the index, built afterwards).
function Database:_RowConforms(tbl, row)
    for _, col in ipairs(tbl:Columns()) do
        local v = row[col:Name()]
        if v == nil or v == DB.NULL then
            if not col:IsNullable() then return false end
        elseif not DB.checkType(col:Type(), v) then
            return false
        end
    end
    return true
end

-- The load-sweep de-dup key: the SHARED combined key over `cols` (Core/DB/Types.lua); nil if
-- any part is NULL (SQL allows many NULLs in a unique key, so NULL rows aren't duplicates).
local conformKey = DB.combinedKey

-- Reconcile a persisted row to the CURRENT schema (an automatic column-level migration), in place:
--   * DROP any key whose column no longer exists (e.g. a removed PK column left behind in old saves,
--     like flight_master.id once node_id became the PK), so it stops lingering in the saved data; and
--   * ADD any newly-introduced column from its default.
-- A column still missing afterwards (added NOT NULL with no default) is left to _RowConforms, which
-- drops the row. `valid` is the set of current column names for the table.
function Database:_Reconcile(tbl, row, valid)
    for k in pairs(row) do
        if not valid[k] then row[k] = nil end                              -- column dropped from the schema
    end
    for _, col in ipairs(tbl:Columns()) do
        local n = col:Name()
        if row[n] == nil and col:HasDefault() then row[n] = col:Default() end   -- column added with a default
    end
end

-- On load, persisted data may predate a schema change (a column became NOT NULL, a type changed, a
-- column was added or removed, became the primary key, ...). First RECONCILE each row's columns to the
-- current schema (_Reconcile: drop removed columns, fill new defaulted ones), then drop every row that
-- still doesn't conform -- bad NULL/type, OR a DUPLICATE primary-key / unique key (keeping the first)
-- -- and WARN how many per table, so stale or invalid rows never silently poison queries or constraint
-- checks. Runs before the index is built.
function Database:_Conform()
    local p = self:_p()
    for _, tname in ipairs(p.schema:TableNames()) do
        local tbl, rows = p.schema:Table(tname), p.store:Rows(tname)
        if rows and #rows > 0 then
            local pkCols, uniques = tbl:PrimaryKey(), tbl:Uniques()
            local valid = {}
            for _, col in ipairs(tbl:Columns()) do valid[col:Name()] = true end
            local seenPK, seenU = {}, {}
            for i = 1, #uniques do seenU[i] = {} end
            local kept, removed = {}, 0
            for _, row in ipairs(rows) do
                self:_Reconcile(tbl, row, valid)         -- column-level auto-migration before the row checks
                local ok = self:_RowConforms(tbl, row)
                if ok and #pkCols > 0 then
                    local k = conformKey(row, pkCols)
                    if k and seenPK[k] then ok = false elseif k then seenPK[k] = true end
                end
                if ok then
                    for i, u in ipairs(uniques) do
                        local k = conformKey(row, u)
                        if k and seenU[i][k] then ok = false; break elseif k then seenU[i][k] = true end
                    end
                end
                if ok then kept[#kept + 1] = row else removed = removed + 1 end
            end
            if removed > 0 then
                for i = #rows, 1, -1 do rows[i] = nil end
                for i = 1, #kept do rows[i] = kept[i] end
                ns.Logger:Core():Warn(("db '%s': dropped %d non-conforming/duplicate row(s) from '%s' on load")
                    :format(p.name, removed, tname))
            end
        end
    end
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

-- Resolve an Update/Delete `predicate` to its matching rows (always a FRESH array, safe to mutate
-- against). The predicate is nil (all rows), a function(row) -> boolean (full scan), or a
-- { col = value } map matched by equality -- the MAP form is index-accelerated: any indexed column
-- in it (PK / unique / declared index / FK) narrows the scan to that index bucket, so a PK-keyed
-- upsert never walks the table. Map values must be non-NULL scalars (NULL never equals anything).
function Database:_Targets(tname, predicate)
    local p = self:_p()
    local out = {}
    if type(predicate) == "table" then
        local src
        for col, value in pairs(predicate) do
            local hits = p.index:FindByColumn(tname, col, value)
            if hits then src = hits; break end             -- indexed column -> its bucket is a superset
        end
        for _, row in ipairs(src or p.store:Rows(tname)) do
            local match = true
            for col, value in pairs(predicate) do
                if row[col] ~= value then match = false; break end
            end
            if match then out[#out + 1] = row end
        end
    else
        for _, row in ipairs(p.store:Rows(tname)) do
            if predicate == nil or predicate(row) then out[#out + 1] = row end
        end
    end
    return out
end

-- ---- UPDATE ---------------------------------------------------------------
-- Apply `changes` ({ col = value | DB.NULL }) to every row matching `predicate` (nil = all rows; a
-- function(row), or an index-accelerated { col = value } map -- see _Targets). Returns the number
-- of rows changed. Note: referential ON UPDATE actions are out of scope -- a PK edit that children
-- reference is the caller's responsibility (rare; flagged if it breaks FKs).
function Database:Update(tname, changes, predicate)
    local p = self:_p()
    local tbl = p.schema:Table(tname)
    assert(tbl, ("unknown table '%s'"):format(tostring(tname)))
    local count = 0
    self:_FireStmt(DB.TriggerTime.BEFORE, DB.TriggerEvent.UPDATE, tname)
    -- resolve the matching rows first (we mutate the array's contents, not its membership)
    local targets = self:_Targets(tname, predicate)
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
    if count > 0 then p.store:Touch(tname) end   -- rows mutated in place: bump the generation guard
    self:_FireStmt(DB.TriggerTime.AFTER, DB.TriggerEvent.UPDATE, tname)
    return count
end

-- ---- DELETE (with cascading) ----------------------------------------------
-- `predicate`: nil (all rows), a function(row), or an index-accelerated { col = value } map.
function Database:Delete(tname, predicate)
    local p = self:_p()
    assert(p.schema:Table(tname), ("unknown table '%s'"):format(tostring(tname)))
    -- BEFORE-statement trigger first, THEN resolve targets (same order as Update) -- so a
    -- statement trigger that inserts/edits rows still influences which rows match.
    self:_FireStmt(DB.TriggerTime.BEFORE, DB.TriggerEvent.DELETE, tname)
    local targets = self:_Targets(tname, predicate)
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
    local refs = p.enforcer:ChildRefs(tname)

    -- 1) RESTRICT: block the delete if any restricting child still references this row.
    for _, ref in ipairs(refs) do
        if ref.onDelete == DB.OnDelete.RESTRICT and #self:_ChildRows(ref, row[ref.refCol]) > 0 then
            error(("DB: RESTRICT: %s row still referenced by %s.%s"):format(tname, ref.childTable, ref.childCol), 0)
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

    -- 3) remove the row itself.
    local old = self:_Snapshot(row)
    p.index:OnDelete(tname, row)
    p.store:RemoveRow(tname, row)
    self:_FireRow(DB.TriggerTime.AFTER, DB.TriggerEvent.DELETE, tname, nil, old)
    return 1
end

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
