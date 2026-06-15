local S = dofile("Test/support.lua")

local function newCache()
    local clock = S.newClock()
    _G.GetTime = clock.GetTime   -- Cache captures GetTime at load, so set it first
    _G.C_Timer = clock.C_Timer
    local ns = S.newNs()
    S.load(ns, "Services/Cache.lua")
    local c = ns._captured["Cache"]
    c:OnInitialize()
    return c, clock, ns
end

describe("Cache", function()
    it("Set / Get returns a hit flag and misses unknown keys", function()
        local c = newCache()
        local s = c:Store("t")
        s:Set("k", 42)
        local v, hit = s:Get("k")
        assert.are.equal(42, v)
        assert.is_true(hit)
        local v2, hit2 = s:Get("nope")
        assert.is_nil(v2)
        assert.is_false(hit2)
    end)

    it("GetOrCompute computes once, then serves from cache", function()
        local c = newCache()
        local s = c:Store("t")
        local calls = 0
        local f = function() calls = calls + 1; return 7 end
        assert.are.equal(7, s:GetOrCompute("k", f))
        assert.are.equal(7, s:GetOrCompute("k", f))
        assert.are.equal(1, calls)
    end)

    it("caches a stored nil distinctly from a miss", function()
        local c = newCache()
        local s = c:Store("t")
        s:Set("k", nil)
        local v, hit = s:Get("k")
        assert.is_nil(v)
        assert.is_true(hit)
    end)

    it("LRU evicts the least-recently-used entry", function()
        local c = newCache()
        local s = c:Store("lru", { max = 2 })
        s:Set("a", 1)
        s:Set("b", 2)
        assert.is_true(select(2, s:Get("a")))   -- touch a -> b becomes LRU
        s:Set("c", 3)                            -- over capacity -> evict b
        assert.is_true(select(2, s:Get("a")))
        assert.is_false(select(2, s:Get("b")))
        assert.is_true(select(2, s:Get("c")))
    end)

    it("TTL expires entries by the clock", function()
        local c, clock = newCache()
        local s = c:Store("ttl", { ttl = 10 })
        s:Set("k", 1)
        clock.now = 5
        assert.is_true(select(2, s:Get("k")))
        clock.now = 11
        assert.is_false(select(2, s:Get("k")))
    end)

    it("Invalidate and Clear drop entries", function()
        local c = newCache()
        local s = c:Store("t")
        s:Set("k", 1)
        s:Invalidate("k")
        assert.is_false(select(2, s:Get("k")))
        s:Set("a", 1)
        s:Set("b", 2)
        s:Clear()
        assert.is_false(select(2, s:Get("a")))
    end)

    it("Stats tracks hits and misses", function()
        local c = newCache()
        local s = c:Store("t")
        s:Set("k", 1)
        s:Get("k")      -- hit
        s:Get("x")      -- miss
        local st = s:Stats()
        assert.are.equal(1, st.hits)
        assert.are.equal(1, st.misses)
    end)

    it("ttl = 0 is valid same-tick but expires once the clock advances", function()
        local c, clock = newCache()
        local s = c:Store("z", { ttl = 0 })
        s:Set("k", 1)
        assert.is_true(select(2, s:Get("k")))   -- now == expiry, not yet expired
        clock.now = clock.now + 1
        assert.is_false(select(2, s:Get("k")))
    end)

    it("max = 0 stores nothing (the just-added entry is evicted)", function()
        local c = newCache()
        local s = c:Store("z0", { max = 0 })
        s:Set("k", 1)
        assert.is_false(select(2, s:Get("k")))
    end)

    -- ---- weak stores (the GC-reclaimed branch; logic is testable without forcing GC) ----
    it("a weak store holds and serves values", function()
        local c = newCache()
        local s = c:Store("w", { weak = "v" })
        local obj = { x = 1 }
        s:Set("k", obj)
        local v, hit = s:Get("k")
        assert.are.equal(obj, v); assert.is_true(hit)
        assert.is_false(select(2, s:Get("nope")))
    end)

    it("a weak store treats Set(nil) and Invalidate as deletes; Clear empties it", function()
        local c = newCache()
        local s = c:Store("w", { weak = "kv" })
        s:Set("k", { 1 })
        s:Set("k", nil)                          -- weak can't hold nil -> delete
        assert.is_false(select(2, s:Get("k")))
        s:Set("a", { 2 }); s:Invalidate("a")
        assert.is_false(select(2, s:Get("a")))
        s:Set("b", { 3 }); s:Clear()
        assert.is_false(select(2, s:Get("b")))
    end)

    it("a weak store omits count from Stats (the GC owns lifetime)", function()
        local c = newCache()
        local s = c:Store("w", { weak = "k" })
        s:Set("k", { 1 })
        s:Get("k"); s:Get("x")
        local st = s:Stats()
        assert.are.equal(1, st.hits); assert.are.equal(1, st.misses)
        assert.is_nil(st.count)                  -- omitted for weak stores
    end)

    it("weak + ttl is downgraded to managed and warns", function()
        local c, _, ns = newCache()
        local warned
        ns.Logger.Core = function()
            return { Debug = function() end, Info = function() end, Success = function() end,
                     Warn = function(_, msg) warned = msg end, Error = function() end }
        end
        local s = c:Store("dg", { weak = "v", ttl = 10 })
        assert.is_true(type(warned) == "string")     -- the downgrade warning fired
        s:Set("k", 1)
        assert.are.equal(1, s:Stats().count)         -- managed now: count tracked (weak would omit it)
    end)

    it("sweeps expired-but-UNREAD nodes from a ttl-only store (not just the key being read)", function()
        local c, clock = newCache()
        local s = c:Store("ttl", { ttl = 10 })
        s:Set("a", 1); s:Set("b", 2); s:Set("c", 3)
        assert.are.equal(3, s:Stats().count)
        clock.now = 11                            -- everything has expired, but none re-read yet
        -- A single interaction with ANY key triggers the (now-due) full sweep, reclaiming all three.
        s:Get("a")
        assert.are.equal(0, s:Stats().count)      -- b and c were dropped too, not just a
    end)

    it("Stats count is the LIVE size: it never reports expired nodes", function()
        local c, clock = newCache()
        local s = c:Store("ttl", { ttl = 10 })
        s:Set("a", 1); s:Set("b", 2)
        clock.now = 11
        assert.are.equal(0, s:Stats().count)      -- forced sweep -> count excludes the expired pair
    end)

    it("ttl and max compose: LRU eviction AND per-entry expiry on one store", function()
        local c, clock = newCache()
        local s = c:Store("tm", { max = 2, ttl = 10 })
        s:Set("a", 1); s:Set("b", 2)
        s:Get("a")                               -- touch a -> b becomes LRU
        s:Set("c", 3)                            -- over max -> evict b
        assert.is_true(select(2, s:Get("a")))
        assert.is_false(select(2, s:Get("b")))   -- evicted by LRU
        assert.is_true(select(2, s:Get("c")))
        clock.now = clock.now + 11
        assert.is_false(select(2, s:Get("a")))   -- expired by ttl
        assert.is_false(select(2, s:Get("c")))
    end)
end)
