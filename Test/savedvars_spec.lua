local S = dofile("Test/support.lua")

local function setup()
    _G.HagAIODB = nil
    _G.HagAIOCharDB = nil
    local ns = S.newNs()
    S.load(ns, "Services/SavedVars.lua")
    local sv = ns._captured["SavedVars"]; sv:OnInitialize(); sv:Load()
    return sv
end

describe("SavedVars", function()
    it("Namespace seeds missing defaults without clobbering, and is idempotent", function()
        local sv = setup()
        local t = sv:Namespace("m", { a = 1, b = 2 })
        t.a = 99
        local t2 = sv:Namespace("m", { a = 5, c = 3 })  -- same table, fill-missing only
        assert.are.equal(t, t2)      -- idempotent: same table returned
        assert.are.equal(99, t2.a)   -- existing value kept
        assert.are.equal(2, t2.b)
        assert.are.equal(3, t2.c)    -- new default added
    end)

    it("deep-merges nested default tables", function()
        local sv = setup()
        local t = sv:Namespace("n", { sub = { a = 1 } })
        t.sub.a = 7; t.sub.keep = 1
        sv:Namespace("n", { sub = { a = 9, b = 2 } })
        assert.are.equal(7, t.sub.a)   -- not clobbered
        assert.are.equal(2, t.sub.b)   -- new nested default added
        assert.are.equal(1, t.sub.keep)
    end)

    it("keeps per-character and global namespaces separate", function()
        local sv = setup()
        local g = sv:Namespace("k", { v = 1 })
        local c = sv:Namespace("k", { v = 2 }, true)   -- perChar
        g.v = 10
        assert.is_true(g ~= c)
        assert.are.equal(10, g.v)
        assert.are.equal(2, c.v)
    end)

    it("module enable-state get/set round-trips per scope", function()
        local sv = setup()
        sv:SetModuleState("Foo", true)
        sv:SetModuleState("Foo", false, true)  -- per character
        assert.is_true(sv:GetModuleState("Foo"))
        assert.is_false(sv:GetModuleState("Foo", true))
    end)

    it("Migrate stamps a fresh DB at the current schema", function()
        local sv = setup()  -- HagAIODB was nil -> fresh install
        sv:Migrate()
        assert.is_true(sv:Global()._schema ~= nil)
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
        assert.is_nil(ran[2])    -- already applied
        assert.is_true(ran[3])
        assert.are.equal(3, g._schema)
    end)

    it("an up-to-date DB (from == version) is a no-op that runs no migrations", function()
        local sv = setup()
        local ran = false
        local g = { _schema = 3 }
        assert.is_true(sv:_RunMigrations(g, {}, { [3] = function() ran = true end }, 3))
        assert.is_false(ran)        -- nothing pending
        assert.are.equal(3, g._schema)
    end)

    it("passes (global, char) to each migration", function()
        local sv = setup()
        local seen
        local g, char = { _schema = 1 }, { who = "char" }
        sv:_RunMigrations(g, char, { [2] = function(gg, cc) seen = { gg, cc } end }, 2)
        assert.are.equal(g, seen[1])
        assert.are.equal(char, seen[2])
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
        assert.is_true(ran[2])      -- v2 applied
        assert.is_nil(ran[4])       -- v4 never reached (stopped at the v3 failure)
        assert.are.equal(2, g._schema)  -- last good version

        -- retried on a later load: still fails at v3, still pinned to v2
        assert.is_false(sv:_RunMigrations(g, {}, migs, 4))
        assert.are.equal(2, g._schema)
    end)
end)
