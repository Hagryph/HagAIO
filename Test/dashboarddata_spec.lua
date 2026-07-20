local S = dofile("Test/support.lua")

-- A fresh ns with DashboardData loaded. The rig stubs ns.LibManager:RegisterValue, so the lib
-- anchors at ns.DashboardData. The real DB.Types (for the NULL sentinel) and ResetLedger (for
-- VaultDone's Progress rule) are loaded too, since the lib reaches them at call time.
local function dd()
    local ns = S.newNs()
    S.load(ns, "Lib/ResetLedger.lua")   -- ns.ResetLedger (Progress)
    S.load(ns, "Lib/DashboardData.lua")
    return ns.DashboardData, ns
end

describe("DashboardData.PlainNum", function()
    it("passes the value through unchanged when no Secrets layer is present", function()
        local D, ns = dd()
        ns.Secrets = nil
        assert.are.equal(5, D.PlainNum(5))
        assert.is_nil(D.PlainNum(nil))
        local t = { __secret = true }
        assert.are.equal(t, D.PlainNum(t))      -- without the launder it leaks through unchanged
    end)
    it("launders through ns.Secrets:Number: a secret becomes nil, a number survives", function()
        local D, ns = dd()
        ns.Secrets = { Number = function(_, v)
            if type(v) == "table" and v.__secret then return nil end
            return tonumber(v)
        end }
        assert.is_nil(D.PlainNum({ __secret = true }))   -- secret -> NULL-able nil
        assert.are.equal(7, D.PlainNum(7))
        assert.are.equal(123, D.PlainNum("123"))
        assert.is_nil(D.PlainNum("abc"))                 -- non-numeric -> nil
    end)
end)

describe("DashboardData.CurrentExpacLevel", function()
    it("prefers the display getter when present", function()
        local D = dd()
        local lvl = D.CurrentExpacLevel(function() return 11 end, function() return 9 end, 7)
        assert.are.equal(11, lvl)
    end)
    it("falls back to the level getter when the display getter is absent", function()
        local D = dd()
        assert.are.equal(9, D.CurrentExpacLevel(nil, function() return 9 end, 7))
    end)
    it("falls back to the constant when neither getter is present", function()
        local D = dd()
        assert.are.equal(7, D.CurrentExpacLevel(nil, nil, 7))
    end)
end)

describe("DashboardData.VaultDone", function()
    it("returns a dash when the vault, slots, or slot list is empty", function()
        local D = dd()
        assert.are.equal("-", D.VaultDone(nil))
        assert.are.equal("-", D.VaultDone({}))                 -- no slots
        assert.are.equal("-", D.VaultDone({ slots = {} }))     -- empty slot list
    end)
    it("counts only slots that meet their threshold (ResetLedger:Progress done rule)", function()
        local D = dd()
        local vault = { slots = {
            { progress = 8, threshold = 8 },   -- done
            { progress = 3, threshold = 8 },   -- not done
            { progress = 10, threshold = 8 },  -- over -> done
        } }
        assert.are.equal("2/3", D.VaultDone(vault))
    end)
    it("a non-positive threshold is never done (no requirement)", function()
        local D = dd()
        local vault = { slots = {
            { progress = 5, threshold = 0 },   -- threshold 0 -> not done
            { progress = 1, threshold = 1 },   -- done
        } }
        assert.are.equal("1/2", D.VaultDone(vault))
    end)
end)
