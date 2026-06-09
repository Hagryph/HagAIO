local S = dofile("Test/support.lua")

local function setup()
    _G.HagAIODB = nil
    _G.HagAIOCharDB = nil
    local ns = S.newNs()
    S.load(ns, "Services/SavedVars.lua")
    local sv = ns._captured["SavedVars"]; sv:OnInitialize(); sv:Load()
    return sv
end

describe("SavedVars data namespaces", function()
    it("Namespace seeds missing defaults without clobbering, and is idempotent", function()
        local sv = setup()
        local t = sv:Namespace("m", { a = 1, b = 2 })
        t.a = 99
        local t2 = sv:Namespace("m", { a = 5, c = 3 })  -- same table, fill-missing only
        assert.are.equal(t, t2)
        assert.are.equal(99, t2.a)
        assert.are.equal(2, t2.b)
        assert.are.equal(3, t2.c)
    end)

    it("keeps per-character and global DATA namespaces separate", function()
        local sv = setup()
        local g = sv:Namespace("k", { v = 1 })
        local c = sv:Namespace("k", { v = 2 }, true)   -- perChar
        g.v = 10
        assert.is_true(g ~= c)
        assert.are.equal(10, g.v)
        assert.are.equal(2, c.v)
    end)
end)

describe("SavedVars settings cascade", function()
    it("resolves override ?? profile ?? code default", function()
        local sv = setup()
        sv:SettingsView("ns", { a = 1, b = 2 })            -- register code defaults
        assert.are.equal(1, sv:GetSetting("ns", "a"))      -- default layer

        sv:Global().profiles.P = { ns = { a = 9 } }
        sv:SetLoadedProfile("P")
        assert.are.equal(9, sv:GetSetting("ns", "a"))      -- profile layer
        assert.are.equal(2, sv:GetSetting("ns", "b"))      -- profile didn't set b -> default

        sv:SetSetting("ns", "a", 7)                         -- char override over the profile
        assert.are.equal(7, sv:GetSetting("ns", "a"))
        assert.are.equal(7, sv:Char().overrides.ns.a)
    end)

    it("writes only diffs: setting a value equal to the baseline drops the override", function()
        local sv = setup()
        sv:SettingsView("ns", { a = 1 })
        sv:SetSetting("ns", "a", 5)
        assert.are.equal(5, sv:Char().overrides.ns.a)
        sv:SetSetting("ns", "a", 1)                         -- back to the default baseline
        assert.is_nil(sv:Char().overrides.ns)              -- override dropped + empty ns cleaned
        assert.are.equal(1, sv:GetSetting("ns", "a"))

        sv:Global().profiles.P = { ns = { a = 9 } }
        sv:SetLoadedProfile("P")
        sv:SetSetting("ns", "a", 9)                         -- equals the PROFILE baseline now
        assert.is_nil(sv:Char().overrides.ns)              -- still no override
    end)

    it("a settings view proxies reads/writes to the cascade", function()
        local sv = setup()
        local v = sv:SettingsView("ns", { x = 3 })
        assert.are.equal(3, v.x)
        v.x = 8
        assert.are.equal(8, v.x)
        assert.are.equal(8, sv:GetSetting("ns", "x"))
        assert.are.equal(8, sv:Char().overrides.ns.x)
    end)

    it("deep-equals table values (a colour set back to default drops the override)", function()
        local sv = setup()
        sv:SettingsView("ns", { col = { 1, 1, 1 } })
        sv:SetSetting("ns", "col", { 0.5, 0.5, 0.5 })
        assert.are.equal("table", type(sv:Char().overrides.ns.col))
        sv:SetSetting("ns", "col", { 1, 1, 1 })            -- structurally equal to default
        assert.is_nil(sv:Char().overrides.ns)
    end)
end)

describe("SavedVars module enable state (cascade)", function()
    it("override ?? profile ?? registered defaultEnabled, diffed on write", function()
        local sv = setup()
        sv:RegisterModuleDefault("Foo", true)
        assert.is_true(sv:GetModuleState("Foo"))           -- registered default

        sv:SetModuleState("Foo", true)                     -- equals default -> no override
        assert.is_nil(sv:Char().overrides.modules)
        sv:SetModuleState("Foo", false)                    -- differs -> override
        assert.is_false(sv:GetModuleState("Foo"))
        assert.is_false(sv:Char().overrides.modules.Foo)
    end)
end)

describe("SavedVars SnapshotDiffs", function()
    it("captures effective config as diffs from default only", function()
        local sv = setup()
        sv:SettingsView("ns", { a = 1, b = 2 })
        sv:RegisterModuleDefault("Foo", true)
        sv:SetSetting("ns", "a", 5)
        sv:SetModuleState("Foo", false)
        local snap = sv:SnapshotDiffs()
        assert.are.equal(5, snap.ns.a)
        assert.is_nil(snap.ns.b)                            -- unchanged -> not captured
        assert.is_false(snap.modules.Foo)
    end)
end)

describe("SavedVars._RunMigrations", function()
    it("applies pending migrations lowest-first and stamps the version", function()
        local sv = setup()
        local order = {}
        local g = { _schema = 1 }
        local migs = {
            [2] = function() order[#order + 1] = 2 end,
            [3] = function() order[#order + 1] = 3 end,
        }
        assert.is_true(sv:_RunMigrations(g, {}, migs, 3))
        assert.are.equal(2, order[1])
        assert.are.equal(3, order[2])
        assert.are.equal(3, g._schema)
    end)

    it("skips migrations already applied (from >= their version)", function()
        local sv = setup()
        local ran = {}
        local g = { _schema = 2 }
        local migs = {
            [2] = function() ran[2] = true end,
            [3] = function() ran[3] = true end,
        }
        sv:_RunMigrations(g, {}, migs, 3)
        assert.is_nil(ran[2])
        assert.is_true(ran[3])
        assert.are.equal(3, g._schema)
    end)

    it("a failing migration stops the run and leaves _schema at the last good version", function()
        local sv = setup()
        local ran = {}
        local g = { _schema = 1 }
        local migs = {
            [2] = function() ran[2] = true end,
            [3] = function() error("boom") end,
            [4] = function() ran[4] = true end,
        }
        assert.is_false(sv:_RunMigrations(g, {}, migs, 4))
        assert.is_true(ran[2])
        assert.is_nil(ran[4])
        assert.are.equal(2, g._schema)
    end)
end)
