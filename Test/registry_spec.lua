local S = dofile("Test/support.lua")

-- Registry's shared lifecycle sweeps (_StartEach / _ShutdownEach), lifted out of the
-- Service/Module managers so the iteration + guards have one home.
local function realRegistry()
    local ns = { UI = {} }
    assert(loadfile("Core/Class.lua"))("HagAIO", ns)
    assert(loadfile("Core/Registry.lua"))("HagAIO", ns)
    return ns.Class.new("R", ns.Registry):New("thing")
end

-- A minimal registrable item: answers GetName + records when its hook runs.
local function item(name, log)
    local I = { name = name }
    function I:GetName() return self.name end
    function I:Go() log[#log + 1] = self.name end
    function I:Boom() error("boom") end
    return I
end

describe("Registry sweeps", function()
    it("_StartEach walks registration order by default", function()
        local r, log = realRegistry(), {}
        r:Register(item("a", log)); r:Register(item("b", log))
        r:_StartEach(function(it) it:Go() end)
        assert.are.equal("a", log[1]); assert.are.equal("b", log[2])
    end)

    it("_StartEach honours an explicit order", function()
        local r, log = realRegistry(), {}
        r:Register(item("a", log)); r:Register(item("b", log))
        r:_StartEach(function(it) it:Go() end, { "b", "a" })
        assert.are.equal("b", log[1]); assert.are.equal("a", log[2])
    end)

    it("_ShutdownEach reverse walks back-to-front", function()
        local r, log = realRegistry(), {}
        r:Register(item("a", log)); r:Register(item("b", log))
        r:_ShutdownEach("Go", { reverse = true })
        assert.are.equal("b", log[1]); assert.are.equal("a", log[2])
    end)

    it("_ShutdownEach isolates a hook error so the rest still run", function()
        local r, log = realRegistry(), {}
        local bad = item("bad", log); bad.Go = bad.Boom  -- throws when swept
        r:Register(bad); r:Register(item("ok", log))
        assert.is_true(pcall(function() r:_ShutdownEach("Go") end))  -- never propagates
        assert.are.equal("ok", log[1])  -- ok still ran despite bad throwing
    end)
end)
