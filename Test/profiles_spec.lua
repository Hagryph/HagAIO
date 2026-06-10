local S = dofile("Test/support.lua")

-- Profiles are built ON THE DATABASE: a `profile` row + per-namespace `p_*` rows (FK cascade). The
-- live cascade (override -> loaded profile -> default) is resolved by Lib/SettingsTables.lua. These
-- specs drive the rewritten service against a built database with one registered settings namespace.
local DB_FILES = { "Types", "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager",
                   "Database", "Aggregate", "WhereClause", "ColumnResolver", "QueryPlan",
                   "QueryBuilder", "QueryExecutor", "CoreTables", "DatabaseManager" }

local SCHEMA = { { type = "toggle", key = "x", default = false }, { type = "select", key = "y", default = "a" } }
local NS = "module_Foo"

local function setup()
    _G.HagAIODB = nil
    _G.HagAIOCharDB = nil
    local store, n = {}, 0
    _G.C_EncodingUtil = {
        SerializeCBOR = function(v) n = n + 1; local id = "c" .. n; store[id] = v; return id end,
        DeserializeCBOR = function(s) return store[s] end,
        CompressString = function(s) return s end,
        DecompressString = function(s) return s end,
        EncodeBase64 = function(s) return s end,
        DecodeBase64 = function(s) return s end,
    }
    local ns = S.newNs()
    ns.SlashCommand = { Register = function() end }
    ns.UI.CopyWindow = { Show = function() end }
    ns.ModuleManager = { Iterate = function() return function() return nil end end }  -- no modules in this rig
    for _, f in ipairs(DB_FILES) do S.load(ns, "Core/DB/" .. f .. ".lua") end
    S.load(ns, "Lib/SettingsTables.lua")
    S.load(ns, "Services/Serializer.lua")
    S.load(ns, "Services/Profiles.lua")
    local slots = {}
    ns.SavedVars = { IsLoaded = function() return true end,
                     DataSlot = function(_, name) slots[name] = slots[name] or {}; return slots[name] end }
    local mgr = ns._captured["DatabaseManager"]; mgr:OnInitialize()
    ns.SettingsTables:Register(NS, SCHEMA)
    mgr:Contribute(ns.SettingsTables:DeriveTables(NS, SCHEMA))
    mgr:Build()
    ns._captured["Serializer"]:OnInitialize()
    local pr = ns._captured["Profiles"]; pr:OnInitialize()
    return pr, mgr:Shared(), ns
end

local function set(ns, db, key, value) ns.SettingsTables:Set(db, NS, SCHEMA, key, value) end
local function get(ns, db, key) return ns.SettingsTables:Get(db, NS, SCHEMA, key) end

describe("Profiles", function()
    it("Save snapshots the live config as diffs from default", function()
        local pr, db, ns = setup()
        set(ns, db, "x", true)                          -- differs from default (false)
        assert.is_true((pr:Save("A")))
        local p = pr:Get("A")
        assert.are.equal(true, p[NS].x)
        assert.is_nil(p[NS].y)                          -- unchanged from default -> not stored
    end)

    it("List / Has / Get / Delete", function()
        local pr = setup()
        pr:Save("A")
        assert.are.equal("A", pr:List()[1])
        assert.is_true(pr:Has("A"))
        assert.is_true((pr:Delete("A")))
        assert.is_false(pr:Has("A"))
    end)

    it("LoadProfile wipes overrides and resolves the live config to the profile", function()
        local pr, db, ns = setup()
        db:Insert("profile", { name = "A" })
        db:Insert("p_module_Foo", { profile = "A", x = true })
        set(ns, db, "y", "b")                           -- a live override
        assert.is_true((pr:LoadProfile("A")))
        assert.are.equal("A", pr:GetLoaded())
        assert.are.equal(true, get(ns, db, "x"))        -- from the profile
        assert.are.equal("a", get(ns, db, "y"))         -- override wiped -> default
    end)

    it("ApplyGlobalForFreshChar points an unconfigured char at the global", function()
        local pr, db, ns = setup()
        db:Insert("profile", { name = "G" })
        db:Insert("p_module_Foo", { profile = "G", x = true })
        pr:SetGlobal("G")
        assert.are.equal("G", pr:ApplyGlobalForFreshChar())   -- sets the pointer
        assert.are.equal(true, get(ns, db, "x"))              -- from the global profile
        assert.is_nil(pr:ApplyGlobalForFreshChar())           -- already pointed at one
    end)

    it("Export then Import round-trips a profile", function()
        local pr, db, ns = setup()
        set(ns, db, "x", true)
        pr:Save("A")
        local str = pr:Export("A")
        assert.is_true(type(str) == "string")
        pr:Delete("A")
        local ok, name = pr:Import(str, "B")
        assert.is_true(ok)
        assert.are.equal("B", name)
        assert.are.equal(true, pr:Get("B")[NS].x)
    end)

    it("Import rejects a bad string", function()
        local pr = setup()
        local ok, err = pr:Import("garbage", "X")
        assert.is_false(ok)
        assert.is_true(type(err) == "string")
    end)

    it("the global profile is exclusive and clears when deleted", function()
        local pr = setup()
        pr:Save("A"); pr:Save("B")
        pr:SetGlobal("A")
        assert.is_true(pr:IsGlobal("A"))
        pr:SetGlobal("B")
        assert.is_false(pr:IsGlobal("A"))
        assert.is_true(pr:IsGlobal("B"))
        pr:Delete("B")
        assert.is_nil(pr:GetGlobal())
    end)

    it("Deleting the profile this character has loaded clears its loaded pointer", function()
        local pr = setup()
        pr:Save("A")
        pr:LoadProfile("A")
        assert.are.equal("A", pr:GetLoaded())
        pr:Delete("A")
        assert.is_nil(pr:GetLoaded())
    end)
end)
