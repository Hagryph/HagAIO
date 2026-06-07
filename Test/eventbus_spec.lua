local S = dofile("Test/support.lua")

describe("EventBus", function()
    it("auto-registers on the first handler and dispatches game events", function()
        local bus, frames = S.newBus()
        local got = {}
        bus:On("PLAYER_LOGIN", function(ev, a) got.ev, got.a = ev, a end)
        assert.is_true(frames[1].registered["PLAYER_LOGIN"])
        frames[1]:Fire("PLAYER_LOGIN", "x")
        assert.are.equal("PLAYER_LOGIN", got.ev)
        assert.are.equal("x", got.a)
    end)

    it("dispatches to every handler; Off removes one; last drop unregisters", function()
        local bus, frames = S.newBus()
        local n = 0
        local t1 = bus:On("E", function() n = n + 1 end)
        local t2 = bus:On("E", function() n = n + 1 end)
        frames[1]:Fire("E"); assert.are.equal(2, n)
        bus:Off("E", t1)
        frames[1]:Fire("E"); assert.are.equal(3, n)      -- only t2 remains
        assert.is_true(frames[1].registered["E"])
        bus:Off("E", t2)
        assert.is_nil(frames[1].registered["E"])          -- last handler gone -> unregistered
        frames[1]:Fire("E"); assert.are.equal(3, n)       -- nothing fires
    end)

    it("broadcasts custom messages; Unsubscribe removes one subscriber", function()
        local bus = S.newBus()
        local hits = {}
        local a = bus:Subscribe("MSG", function(_, v) hits.a = v end)
        bus:Subscribe("MSG", function(_, v) hits.b = v end)
        bus:Emit("MSG", 5)
        assert.are.equal(5, hits.a); assert.are.equal(5, hits.b)
        bus:Unsubscribe("MSG", a)
        bus:Emit("MSG", 9)
        assert.are.equal(5, hits.a)   -- a removed
        assert.are.equal(9, hits.b)
    end)

    it("returns nil (no throw) for an unknown event", function()
        local bus = S.newBus()
        assert.is_nil(bus:On("BOGUS_EVENT", function() end))
    end)

    it("Off / Unsubscribe with a nil token are harmless", function()
        local bus = S.newBus()
        assert.is_true(pcall(function() bus:Off("E", nil); bus:Unsubscribe("M", nil) end))
    end)

    it("OnUnit registers a dedicated unit-filtered frame; OffUnit stops it", function()
        local bus, frames = S.newBus()
        local got = 0
        local tok = bus:OnUnit("UNIT_HEALTH", function() got = got + 1 end, "player", "target")
        local uf = frames[#frames]                       -- the dedicated unit frame
        assert.is_true(uf.registered["UNIT_HEALTH"])
        assert.are.equal("player", uf.units[1]); assert.are.equal("target", uf.units[2])
        uf:Fire("UNIT_HEALTH", "player"); assert.are.equal(1, got)
        bus:OffUnit(tok)
        uf:Fire("UNIT_HEALTH", "player"); assert.are.equal(1, got)   -- handler detached
    end)

    it("a handler that unsubscribes another mid-dispatch doesn't skip it this fire", function()
        local bus, frames = S.newBus()
        local ran = {}
        local tokB
        bus:On("E", function() ran[#ran + 1] = "A"; bus:Off("E", tokB) end)  -- removes B mid-dispatch
        tokB = bus:On("E", function() ran[#ran + 1] = "B" end)
        frames[1]:Fire("E")
        assert.are.equal(2, #ran)   -- B was in the fire's snapshot, so it still ran
        frames[1]:Fire("E")
        assert.are.equal(3, #ran)   -- B now unsubscribed -> only A
    end)
end)
