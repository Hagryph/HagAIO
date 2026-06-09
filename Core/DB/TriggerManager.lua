local addonName, ns = ...
local Class = ns.Class

-- Core/DB/TriggerManager.lua
-- Holds a schema's triggers and fires them around the Database's DML, in SQL order:
--   BEFORE  -> (constraints + the actual write, unless replaced) -> AFTER
-- per the trigger's timing (BEFORE / AFTER / INSTEAD_OF) and event (INSERT / UPDATE / DELETE).
--
-- Each ROW trigger's action receives a context:
--   { db, table, time, event, new = <new row | nil>, old = <old row | nil> }
-- INSERT has only `new`; DELETE has only `old`; UPDATE has both. A BEFORE trigger may MUTATE
-- ctx.new (to normalise/fill) or VETO the operation by returning false. An INSTEAD_OF trigger
-- REPLACES the operation (the base insert/update/delete does not run). An optional `when(ctx)`
-- predicate gates whether the action runs.
--
-- STATEMENT-level triggers fire once per DML call (FireStatement); ROW-level fire per row.
-- A re-entrancy guard stops a trigger whose action issues DML on the same table+timing+event from
-- recursing into itself forever.

ns.DB = ns.DB or {}
local DB = ns.DB

local TriggerManager = Class.new("DBTriggerManager")

function TriggerManager:Initialize(schema)
    local p = self:_p()
    p.row = {}        -- table -> time -> event -> { trigger, ... }
    p.stmt = {}       -- same shape, for FOR EACH STATEMENT triggers
    p.active = {}     -- "table\time\event" currently firing (re-entrancy guard)
    for _, t in ipairs(schema:Triggers()) do
        local bucket = (t.level == DB.TriggerLevel.STATEMENT) and p.stmt or p.row
        bucket[t.table] = bucket[t.table] or {}
        bucket[t.table][t.time] = bucket[t.table][t.time] or {}
        local list = bucket[t.table][t.time]
        list[t.event] = list[t.event] or {}
        local le = list[t.event]
        le[#le + 1] = t
    end
end

function TriggerManager:_For(bucket, tname, time, event)
    local a = bucket[tname]; if not a then return nil end
    local b = a[time];       if not b then return nil end
    return b[event]
end

-- Fire ROW triggers. For BEFORE it returns (proceed, replaced):
--   proceed=false -> a BEFORE trigger vetoed; the caller skips the op.
--   replaced=true -> an INSTEAD_OF trigger handled it; the caller skips the base write (+ AFTER).
-- For AFTER it returns (true, false). `newRow`/`oldRow` are live tables a BEFORE trigger may edit.
function TriggerManager:FireRow(db, time, event, tname, newRow, oldRow)
    local p = self:_p()
    local key = tname .. "\1" .. time .. "\1" .. event
    if p.active[key] then return true, false end          -- re-entrancy: don't recurse into ourselves
    p.active[key] = true
    local ok, a, b = pcall(self._FireRowInner, self, db, time, event, tname, newRow, oldRow)
    p.active[key] = nil
    if not ok then error(a, 0) end
    return a, b
end

function TriggerManager:_FireRowInner(db, time, event, tname, newRow, oldRow)
    local ctx = { db = db, table = tname, time = time, event = event, new = newRow, old = oldRow }

    local proceed = true
    for _, t in ipairs(self:_For(self:_p().row, tname, time, event) or {}) do
        if t.when == nil or t.when(ctx) then
            if t.action(ctx) == false then proceed = false end
        end
    end

    local replaced = false
    if time == DB.TriggerTime.BEFORE then
        for _, t in ipairs(self:_For(self:_p().row, tname, DB.TriggerTime.INSTEAD_OF, event) or {}) do
            if t.when == nil or t.when(ctx) then
                t.action(ctx)
                replaced = true
            end
        end
    end
    return proceed, replaced
end

-- Fire FOR EACH STATEMENT triggers once for a DML statement (no veto/replace).
function TriggerManager:FireStatement(db, time, event, tname)
    local ctx = { db = db, table = tname, time = time, event = event }
    for _, t in ipairs(self:_For(self:_p().stmt, tname, time, event) or {}) do
        if t.when == nil or t.when(ctx) then t.action(ctx) end
    end
end

DB.TriggerManager = TriggerManager
