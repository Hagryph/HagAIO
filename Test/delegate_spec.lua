-- Test/delegate_spec.lua — ns.Delegate (Core/Delegate.lua), the multicast signal.
local function newDelegate()
    local ns = {}
    assert(loadfile("Core/Class.lua"))("HagAIO", ns)
    assert(loadfile("Core/Delegate.lua"))("HagAIO", ns)
    return ns.Delegate:New()
end

describe("Delegate", function()
    it("fires all connected handlers with the args", function()
        local d = newDelegate()
        local sum = 0
        d:Connect(function(n) sum = sum + n end)
        d:Connect(function(n) sum = sum + n * 10 end)
        d:Fire(2)
        assert.are.equal(22, sum)
        assert.are.equal(2, d:Count())
    end)

    it("fires in connection order", function()
        local d = newDelegate()
        local order = {}
        d:Connect(function() order[#order + 1] = "a" end)
        d:Connect(function() order[#order + 1] = "b" end)
        d:Fire()
        assert.are.equal("a", order[1])
        assert.are.equal("b", order[2])
    end)

    it("Disconnect removes a handler", function()
        local d = newDelegate()
        local hits = 0
        local token = d:Connect(function() hits = hits + 1 end)
        d:Fire()
        d:Disconnect(token)
        d:Fire()
        assert.are.equal(1, hits)
        assert.are.equal(0, d:Count())
    end)

    it("a handler may disconnect another mid-fire safely", function()
        local d = newDelegate()
        local hits = 0
        local t2
        d:Connect(function() d:Disconnect(t2) end)   -- removes the second before it runs
        t2 = d:Connect(function() hits = hits + 1 end)
        d:Fire()
        assert.are.equal(0, hits)
    end)

    it("Clear drops every handler", function()
        local d = newDelegate()
        d:Connect(function() end)
        d:Clear()
        assert.are.equal(0, d:Count())
    end)
end)
