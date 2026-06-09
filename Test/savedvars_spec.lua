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
        local t2 = sv:Namespace("m", { a = 5, c = 3 })
        assert.are.equal(t, t2)
        assert.are.equal(99, t2.a)
        assert.are.equal(2, t2.b)
        assert.are.equal(3, t2.c)
    end)

    it("keeps per-character and global DATA namespaces separate", function()
        local sv = setup()
        local g = sv:Namespace("k", { v = 1 })
        local c = sv:Namespace("k", { v = 2 }, true)
        g.v = 10
        assert.is_true(g ~= c)
        assert.are.equal(10, g.v)
        assert.are.equal(2, c.v)
    end)
end)

describe("SavedVars settings (materialised)", function()
    it("materialises override <- profile <- code default on bind", function()
        local sv = setup()
        sv:Global().profiles.P = { ns = { a = 9, c = 3 } }
        sv:SetLoadedProfile("P")
        sv:Char().overrides.ns = { a = 7 }            -- stored from a prior session
        sv:SettingsView("ns", { a = 1, b = 2 })       -- bind -> materialise
        assert.are.equal(7, sv:GetSetting("ns", "a")) -- override wins
        assert.are.equal(2, sv:GetSetting("ns", "b")) -- default (profile/override absent)
        assert.are.equal(3, sv:GetSetting("ns", "c")) -- profile (no default/override)
    end)

    it("reads/writes hit the live config directly; the char layer isn't touched until Flush", function()
        local sv = setup()
        sv:SettingsView("ns", { a = 1 })
        sv:SetSetting("ns", "a", 5)
        assert.are.equal(5, sv:GetSetting("ns", "a"))  -- live
        assert.is_nil(sv:Char().overrides.ns)          -- not persisted yet
        sv:Flush()
        assert.are.equal(5, sv:Char().overrides.ns.a)  -- diff written on flush
    end)

    it("Flush stores only diffs from the baseline (profile ?? default)", function()
        local sv = setup()
        sv:SettingsView("ns", { a = 1, b = 2 })
        sv:SetSetting("ns", "a", 5)   -- differs from default -> stored
        sv:SetSetting("ns", "b", 2)   -- equals default -> not stored
        sv:Flush()
        assert.are.equal(5, sv:Char().overrides.ns.a)
        assert.is_nil(sv:Char().overrides.ns.b)
    end)

    it("Flush drops an override that was set back to the baseline", function()
        local sv = setup()
        sv:Char().overrides.ns = { a = 5 }   -- stored from a prior session
        sv:SettingsView("ns", { a = 1 })
        sv:SetSetting("ns", "a", 1)          -- back to the default
        sv:Flush()
        assert.is_nil(sv:Char().overrides.ns)
    end)

    it("Flush diffs against the loaded profile, not just the default", function()
        local sv = setup()
        sv:Global().profiles.P = { ns = { a = 9 } }
        sv:SetLoadedProfile("P")
        sv:SettingsView("ns", { a = 1 })
        assert.are.equal(9, sv:GetSetting("ns", "a"))  -- materialised from the profile
        sv:SetSetting("ns", "a", 9); sv:Flush()
        assert.is_nil(sv:Char().overrides.ns)          -- equals profile -> no override
        sv:SetSetting("ns", "a", 7); sv:Flush()
        assert.are.equal(7, sv:Char().overrides.ns.a)  -- differs from profile -> stored
    end)

    it("preserves stored overrides for namespaces not loaded this session", function()
        local sv = setup()
        sv:Char().overrides.module_Ghost = { x = true }  -- never materialised this session
        sv:SettingsView("ns", { a = 1 })
        sv:SetSetting("ns", "a", 5)
        sv:Flush()
        assert.is_true(sv:Char().overrides.module_Ghost.x)
    end)

    it("a settings view proxies reads/writes to the live config", function()
        local sv = setup()
        local v = sv:SettingsView("ns", { x = 3 })
        assert.are.equal(3, v.x)
        v.x = 8
        assert.are.equal(8, sv:GetSetting("ns", "x"))
    end)
end)

describe("SavedVars module enable state", function()
    it("override ?? profile ?? registered defaultEnabled, diffed on flush", function()
        local sv = setup()
        sv:RegisterModuleDefault("Foo", true)
        assert.is_true(sv:GetModuleState("Foo"))
        sv:SetModuleState("Foo", true); sv:Flush()
        assert.is_nil(sv:Char().overrides.modules)     -- equals default -> nothing stored
        sv:SetModuleState("Foo", false); sv:Flush()
        assert.is_false(sv:GetModuleState("Foo"))
        assert.is_false(sv:Char().overrides.modules.Foo)
    end)
end)

describe("SavedVars SnapshotDiffs", function()
    it("captures the live config as diffs from default only", function()
        local sv = setup()
        sv:SettingsView("ns", { a = 1, b = 2 })
        sv:RegisterModuleDefault("Foo", true)
        sv:SetSetting("ns", "a", 5)
        sv:SetModuleState("Foo", false)
        local snap = sv:SnapshotDiffs()
        assert.are.equal(5, snap.ns.a)
        assert.is_nil(snap.ns.b)
        assert.is_false(snap.modules.Foo)
    end)
end)

describe("SavedVars Rematerialize", function()
    it("rebuilds the live config from a newly loaded profile + (wiped) overrides", function()
        local sv = setup()
        sv:SettingsView("ns", { a = 1 })
        sv:SetSetting("ns", "a", 5)
        sv:Global().profiles.P = { ns = { a = 9 } }
        sv:ClearOverrides(); sv:SetLoadedProfile("P"); sv:Rematerialize()
        assert.are.equal(9, sv:GetSetting("ns", "a"))  -- now from the profile
    end)
end)

describe("SavedVars._RunMigrations", function()
    it("applies pending migrations lowest-first and stamps the version", function()
        local sv = setup()
        local order = {}
        local g = { _schema = 1 }
        local migs = { [2] = function() order[#order + 1] = 2 end,
                       [3] = function() order[#order + 1] = 3 end }
        assert.is_true(sv:_RunMigrations(g, {}, migs, 3))
        assert.are.equal(2, order[1]); assert.are.equal(3, order[2])
        assert.are.equal(3, g._schema)
    end)

    it("skips migrations already applied (from >= their version)", function()
        local sv = setup()
        local ran = {}
        local g = { _schema = 2 }
        sv:_RunMigrations(g, {}, { [2] = function() ran[2] = true end,
                                   [3] = function() ran[3] = true end }, 3)
        assert.is_nil(ran[2]); assert.is_true(ran[3])
        assert.are.equal(3, g._schema)
    end)

    it("a failing migration stops the run and leaves _schema at the last good version", function()
        local sv = setup()
        local ran = {}
        local g = { _schema = 1 }
        local migs = { [2] = function() ran[2] = true end,
                       [3] = function() error("boom") end,
                       [4] = function() ran[4] = true end }
        assert.is_false(sv:_RunMigrations(g, {}, migs, 4))
        assert.is_true(ran[2]); assert.is_nil(ran[4])
        assert.are.equal(2, g._schema)
    end)
end)
