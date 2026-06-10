local S = dofile("Test/support.lua")

-- SavedVars is now a pure-storage LIBRARY: it binds the saved-variable globals and hands out named
-- slots, nothing more. (The settings/profile cascade lives in the database now -- see
-- settings_tables_spec / profiles_spec.)
local function setup()
    _G.HagAIODB = nil
    _G.HagAIOCharDB = nil
    local ns = S.newNs()
    S.load(ns, "Lib/SavedVars.lua")
    local sv = ns._captured["SavedVars"]; sv:Load()
    return sv
end

describe("SavedVars library", function()
    it("binds the globals and reports loaded", function()
        local sv = setup()
        assert.is_true(sv:IsLoaded())
    end)

    it("DataSlot returns a stable empty slot, idempotently", function()
        local sv = setup()
        local a = sv:DataSlot("db_global")
        a.x = 1
        local b = sv:DataSlot("db_global")
        assert.are.equal(a, b)            -- same slot handed back
        assert.are.equal(1, b.x)          -- never re-seeded over saved data
    end)

    it("keeps per-character and global slots separate, in the right global", function()
        local sv = setup()
        local g = sv:DataSlot("s", false)
        local c = sv:DataSlot("s", true)
        assert.is_true(g ~= c)
        assert.is_true(_G.HagAIODB.s == g)
        assert.is_true(_G.HagAIOCharDB.s == c)
    end)

    it("DataSlot before Load errors", function()
        local ns = S.newNs()
        S.load(ns, "Lib/SavedVars.lua")
        local sv = ns._captured["SavedVars"]
        assert.is_false(pcall(function() sv:DataSlot("x") end))
    end)
end)
