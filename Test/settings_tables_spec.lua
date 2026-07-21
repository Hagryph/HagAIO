local S = dofile("Test/support.lua")

local DB_FILES = { "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager",
                   "Database", "Aggregate", "WhereClause", "ColumnResolver", "QueryPlan",
                   "QueryBuilder", "QueryExecutor", "CoreTables", "DatabaseManager" }

local SCHEMA = {
    { type = "toggle", key = "a", default = true },
    { type = "select", key = "m", default = "off" },
    { type = "dropdown", key = "skin", default = "none" },
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

describe("SettingsTables: ns.Color default normalisation", function()
    it("decomposes an ns.Color default to a plain { r, g, b } (no metatable reaches the store)", function()
        local ns = S.newNs()
        S.load(ns, "Lib/Color.lua")
        local schema = { { type = "color", key = "c", default = ns.Color:New(0.2, 0.4, 0.6) } }
        local d = ns.SettingsTables.SchemaDefault(schema, "c")
        assert.is_false(ns.Color.Is(d))            -- normalised at the door, not an ns.Color
        assert.is_true(colorEq(d, 0.2, 0.4, 0.6))  -- ...and equal to the authored colour
    end)
end)

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
        assert.is_true(db:Schema():Table("o_module_Foo"):HasColumn("skin"))
    end)
end)

describe("SettingsTables: cascade read/write", function()
    it("returns the code default when nothing is stored", function()
        local db, st = build()
        assert.are.equal(true, st:Get(db, NS, SCHEMA, "a"))
        assert.are.equal("off", st:Get(db, NS, SCHEMA, "m"))
        assert.are.equal("none", st:Get(db, NS, SCHEMA, "skin"))
        assert.is_true(colorEq(st:Get(db, NS, SCHEMA, "c"), 1, 0, 0))
    end)

    it("stores an override that differs from the default, and reads it back", function()
        local db, st = build()
        st:Set(db, NS, SCHEMA, "a", false)
        st:Set(db, NS, SCHEMA, "m", "auto")
        st:Set(db, NS, SCHEMA, "skin", "overwatch")
        st:Set(db, NS, SCHEMA, "c", { 0, 1, 0 })
        assert.are.equal(false, st:Get(db, NS, SCHEMA, "a"))
        assert.are.equal("auto", st:Get(db, NS, SCHEMA, "m"))
        assert.are.equal("overwatch", st:Get(db, NS, SCHEMA, "skin"))
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

describe("SettingsTables: SchemaDefault", function()
    it("returns the code default for a key, nil for a missing key", function()
        local _, st = build()
        assert.are.equal(true,  st.SchemaDefault(SCHEMA, "a"))
        assert.are.equal("off", st.SchemaDefault(SCHEMA, "m"))
        assert.is_true(colorEq(st.SchemaDefault(SCHEMA, "c"), 1, 0, 0))
        assert.is_nil(st.SchemaDefault(SCHEMA, "nope"))        -- key not in the schema -> nil
    end)
end)

describe("SettingsTables: Baseline", function()
    it("is loaded-profile value ?? code default, IGNORING this char's override", function()
        local db, st = build()
        db:Insert("profile", { name = "P" })
        db:Insert("p_module_Foo", { profile = "P", a = false })  -- profile sets 'a', leaves 'm'
        st:SetLoadedProfile(db, "P")
        st:Set(db, NS, SCHEMA, "a", true)                        -- this char overrides 'a' = true
        assert.are.equal(true, st:Get(db, NS, SCHEMA, "a"))      -- override wins for Get
        assert.are.equal(false, st:Baseline(db, NS, SCHEMA, "a")) -- but Baseline ignores it -> profile
        assert.are.equal("off", st:Baseline(db, NS, SCHEMA, "m")) -- profile leaves 'm' -> code default
        assert.is_nil(st:Baseline(db, NS, SCHEMA, "nope"))        -- missing key -> nil
    end)
end)

describe("SettingsTables: EffectiveDiffs", function()
    it("returns only the keys whose effective value differs from the default", function()
        local db, st = build()
        assert.is_nil(st:EffectiveDiffs(db, NS, SCHEMA))         -- all default -> nil
        st:Set(db, NS, SCHEMA, "m", "auto")                      -- 'm' now differs
        local diffs = st:EffectiveDiffs(db, NS, SCHEMA)
        assert.are.equal("auto", diffs.m)
        assert.is_nil(diffs.a)                                   -- 'a' still default -> absent
        assert.is_nil(diffs.c)                                   -- 'c' still default -> absent
    end)
end)

describe("SettingsTables: ReadProfile + WriteProfileValues round trip", function()
    it("writes a value map into a profile row, then reads it back", function()
        local db, st = build()
        db:Insert("profile", { name = "P" })
        assert.is_nil(st:ReadProfile(db, NS, SCHEMA, "P"))       -- empty profile -> nil
        st:WriteProfileValues(db, NS, SCHEMA, "P", { a = false, m = "auto", c = { 0, 1, 0 } })
        local got = st:ReadProfile(db, NS, SCHEMA, "P")
        assert.are.equal(false, got.a)
        assert.are.equal("auto", got.m)
        assert.is_true(colorEq(got.c, 0, 1, 0))
    end)
end)

describe("SettingsTables: _EnableBaseline", function()
    it("is the loaded profile's enable-state ?? the passed default", function()
        local db, st = build()
        assert.is_true(st:_EnableBaseline(db, "Foo", true))      -- no profile -> default true
        assert.is_false(st:_EnableBaseline(db, "Foo", false))    -- no profile -> default false
        db:Insert("profile", { name = "P" })
        db:Insert("profile_module_enable", { profile = "P", name = "Foo", enabled = false })
        st:SetLoadedProfile(db, "P")
        assert.is_false(st:_EnableBaseline(db, "Foo", true))     -- profile says false, beats default
        assert.is_true(st:_EnableBaseline(db, "Bar", true))      -- profile silent on 'Bar' -> default
    end)
end)
