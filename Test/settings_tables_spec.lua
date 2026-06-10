local S = dofile("Test/support.lua")

local DB_FILES = { "Types", "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager",
                   "Database", "Aggregate", "WhereClause", "ColumnResolver", "QueryPlan",
                   "QueryBuilder", "QueryExecutor", "CoreTables", "DatabaseManager" }

local SCHEMA = {
    { type = "toggle", key = "a", default = true },
    { type = "select", key = "m", default = "off" },
    { type = "color",  key = "c", default = { 1, 0, 0 } },
}
local NS = "module_Foo"

-- A built database + the SettingsTables lib, with NS's derived tables contributed.
local function build()
    local ns = S.newNs()
    for _, f in ipairs(DB_FILES) do S.load(ns, "Core/DB/" .. f .. ".lua") end
    S.load(ns, "Lib/SettingsTables.lua")
    local slots = {}
    ns.SavedVars = { IsLoaded = function() return true end,
                     DataSlot = function(_, name) slots[name] = slots[name] or {}; return slots[name] end }
    local mgr = ns._captured["DatabaseManager"]; mgr:OnInitialize()
    local st = ns.SettingsTables
    mgr:Contribute(st:DeriveTables(NS, SCHEMA))
    return mgr:Build(), st, ns
end

local function colorEq(got, r, g, b)
    return type(got) == "table" and got[1] == r and got[2] == g and got[3] == b
end
-- A column is "cleared" when the projected cell is absent or the NULL sentinel.
local function isUnset(ns, v) return v == nil or ns.DB.isNull(v) end

describe("SettingsTables: schema -> tables", function()
    it("derives a CHAR override table and a GLOBAL profile table", function()
        local db, st = build()
        assert.is_true(db:Schema():HasTable("o_module_Foo"))
        assert.is_true(db:Schema():HasTable("p_module_Foo"))
        assert.are.equal("char",   db:Schema():Table("o_module_Foo"):Scope())
        assert.are.equal("global", db:Schema():Table("p_module_Foo"):Scope())
        -- a color became three numeric columns
        assert.is_true(db:Schema():Table("o_module_Foo"):HasColumn("c_r"))
        assert.is_true(db:Schema():Table("o_module_Foo"):HasColumn("c_g"))
        assert.is_true(db:Schema():Table("o_module_Foo"):HasColumn("c_b"))
    end)
end)

describe("SettingsTables: cascade read/write", function()
    it("returns the code default when nothing is stored", function()
        local db, st = build()
        assert.are.equal(true, st:Get(db, NS, SCHEMA, "a"))
        assert.are.equal("off", st:Get(db, NS, SCHEMA, "m"))
        assert.is_true(colorEq(st:Get(db, NS, SCHEMA, "c"), 1, 0, 0))
    end)

    it("stores an override that differs from the default, and reads it back", function()
        local db, st = build()
        st:Set(db, NS, SCHEMA, "a", false)
        st:Set(db, NS, SCHEMA, "m", "auto")
        st:Set(db, NS, SCHEMA, "c", { 0, 1, 0 })
        assert.are.equal(false, st:Get(db, NS, SCHEMA, "a"))
        assert.are.equal("auto", st:Get(db, NS, SCHEMA, "m"))
        assert.is_true(colorEq(st:Get(db, NS, SCHEMA, "c"), 0, 1, 0))
        assert.are.equal(1, db:Store():Count("o_module_Foo"))  -- a single override row (id=1)
    end)

    it("clears the override when a value is set back to the baseline (default)", function()
        local db, st, ns = build()
        st:Set(db, NS, SCHEMA, "a", false)
        assert.are.equal(false, st:Get(db, NS, SCHEMA, "a"))
        st:Set(db, NS, SCHEMA, "a", true)                      -- back to default
        assert.are.equal(true, st:Get(db, NS, SCHEMA, "a"))
        local row = db:Select("a"):From("o_module_Foo"):Where("id", "=", 1):Run()[1]
        assert.is_true(row == nil or isUnset(ns, row.a))       -- the 'a' column is cleared (NULL)
    end)

    it("override ?? loaded profile ?? default", function()
        local db, st = build()
        db:Insert("profile", { name = "P" })
        db:Insert("p_module_Foo", { profile = "P", a = false, m = "button" })
        st:SetLoadedProfile(db, "P")
        assert.are.equal("P", st:LoadedProfile(db))
        assert.are.equal(false, st:Get(db, NS, SCHEMA, "a"))       -- from the profile
        assert.are.equal("button", st:Get(db, NS, SCHEMA, "m"))    -- from the profile
        assert.is_true(colorEq(st:Get(db, NS, SCHEMA, "c"), 1, 0, 0)) -- default (profile leaves it)
        st:Set(db, NS, SCHEMA, "a", true)                          -- override beats the profile
        assert.are.equal(true, st:Get(db, NS, SCHEMA, "a"))
    end)

    it("diffs the override against the loaded profile, not the default", function()
        local db, st = build()
        db:Insert("profile", { name = "P" })
        db:Insert("p_module_Foo", { profile = "P", a = false })
        st:SetLoadedProfile(db, "P")
        st:Set(db, NS, SCHEMA, "a", false)                        -- equals the profile -> no override
        assert.is_nil(db:Select("*"):From("o_module_Foo"):Where("id","=",1):Run()[1])
        st:Set(db, NS, SCHEMA, "a", true)                         -- differs from the profile -> stored
        assert.are.equal(true, (db:Select("a"):From("o_module_Foo"):Where("id","=",1):Run()[1] or {}).a)
    end)
end)

describe("SettingsTables: profile snapshot/clear", function()
    it("SnapshotInto captures effective diffs-from-default; ClearChar wipes the override", function()
        local db, st, ns = build()
        db:Insert("profile", { name = "P" })
        st:Set(db, NS, SCHEMA, "m", "auto")
        st:SnapshotInto(db, NS, SCHEMA, "P")
        local prow = db:Select("*"):From("p_module_Foo"):Where("profile", "=", "P"):Run()[1]
        assert.are.equal("auto", prow.m)
        assert.is_true(isUnset(ns, prow.a))                     -- unchanged from default -> not stored
        st:ClearChar(db, NS)
        assert.are.equal(0, db:Store():Count("o_module_Foo"))
    end)
end)

describe("SettingsTables: module enable-state", function()
    it("override ?? profile ?? default, with diff-on-write", function()
        local db, st = build()
        assert.is_true(st:GetModuleEnabled(db, "Foo", true))     -- default
        st:SetModuleEnabled(db, "Foo", true, true)               -- equals default -> nothing stored
        assert.are.equal(0, db:Store():Count("module_enable"))
        st:SetModuleEnabled(db, "Foo", false, true)              -- differs -> stored
        assert.is_false(st:GetModuleEnabled(db, "Foo", true))
        assert.are.equal(1, db:Store():Count("module_enable"))
    end)
end)

describe("SettingsTables: profile cascade delete", function()
    it("deleting the profile row cascades to its per-namespace rows (FK)", function()
        local db, st = build()
        db:Insert("profile", { name = "P" })
        db:Insert("p_module_Foo", { profile = "P", a = false })
        assert.are.equal(1, db:Store():Count("p_module_Foo"))
        db:Delete("profile", function(r) return r.name == "P" end)
        assert.are.equal(0, db:Store():Count("p_module_Foo"))
    end)
end)
