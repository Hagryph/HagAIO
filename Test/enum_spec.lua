-- Test/enum_spec.lua — ns.Enum, the frozen-enum factory (Core/Enum.lua).
local function enumNs()
    local ns = {}
    assert(loadfile("Core/Enum.lua"))("HagAIO", ns)
    return ns
end

describe("Enum", function()
    it("reads members by name", function()
        local Q = enumNs().Enum.new("Quality", { DIRECT = 1, FLY = 2 })
        assert.are.equal(1, Q.DIRECT)
        assert.are.equal(2, Q.FLY)
    end)

    it("errors on an unknown member (typo protection)", function()
        local Q = enumNs().Enum.new("Quality", { DIRECT = 1 })
        assert.is_false((pcall(function() return Q.NOPE end)))
    end)

    it("is read-only (no overwrite, no new members)", function()
        local Q = enumNs().Enum.new("Quality", { DIRECT = 1 })
        assert.is_false((pcall(function() Q.DIRECT = 9 end)))
        assert.is_false((pcall(function() Q.NEW = 5 end)))
        assert.are.equal(1, Q.DIRECT)
    end)

    it("reverse-looks-up, tests membership, and lists ordered names", function()
        local ns = enumNs()
        local Q = ns.Enum.new("Quality", { DIRECT = 1, FLY = 2 })
        assert.are.equal("FLY", ns.Enum.nameOf(Q, 2))
        assert.is_nil(ns.Enum.nameOf(Q, 99))
        assert.is_true(ns.Enum.has(Q, 1))
        assert.is_false(ns.Enum.has(Q, 99))
        local names = ns.Enum.names(Q)
        assert.are.equal("DIRECT", names[1])
        assert.are.equal("FLY", names[2])
    end)

    it("each() iterates members in key order", function()
        local ns = enumNs()
        local Q = ns.Enum.new("Quality", { B = 2, A = 1 })
        local seen = {}
        ns.Enum.each(Q, function(k, v) seen[#seen + 1] = k .. "=" .. v end)
        assert.are.equal("A=1", seen[1])
        assert.are.equal("B=2", seen[2])
    end)
end)
