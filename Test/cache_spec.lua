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

    -- ---- Cache:Memoize (delegates to the Memoize service; load it into the same ns) ----
    local function newCacheWithMemoize()
        local c, clock, ns = newCache()
        S.load(ns, "Services/Memoize.lua")        -- captureRegister publishes ns.Memoize
        ns._captured["Memoize"]:OnInitialize()
        return c, clock, ns
    end

    it("Memoize computes once per distinct arg, then serves the cached value", function()
        local c = newCacheWithMemoize()
        local calls = 0
        local f = c:Memoize(function(n) calls = calls + 1; return n * 2 end)
        assert.are.equal(6, f(3))
        assert.are.equal(6, f(3))                 -- same arg -> cached, fn not re-run
        assert.are.equal(1, calls)
        assert.are.equal(8, f(4))                 -- distinct arg -> computed
        assert.are.equal(2, calls)
        assert.are.equal(6, f(3))                 -- still cached after the second arg
        assert.are.equal(2, calls)
    end)

    it("Memoize with weak=true stores in a GC-reclaimable (weak) cache", function()
        local c = newCacheWithMemoize()
        local calls = 0
        local f = c:Memoize(function(t) calls = calls + 1; return t.x end, "k")
        local arg = { x = 11 }
        assert.are.equal(11, f(arg))
        assert.are.equal(11, f(arg))              -- same key object -> served from the weak cache
        assert.are.equal(1, calls)                -- proves it cached (weak store still serves a live key)
    end)

    -- ---- HasStore / GetId / ClearAll across TWO named stores (isolation + bulk clear) ----
    it("HasStore reports only stores that exist, and GetId echoes the store's name", function()
        local c = newCache()
        assert.is_false(c:HasStore("alpha"))
        local a = c:Store("alpha")
        assert.is_true(c:HasStore("alpha"))
        assert.is_false(c:HasStore("beta"))       -- never created
        assert.are.equal("alpha", a:GetId())
        local b = c:Store("beta")
        assert.are.equal("beta", b:GetId())
    end)

    it("two named stores are isolated: a key in store A is absent from store B", function()
        local c = newCache()
        local a = c:Store("alpha")
        local b = c:Store("beta")
        a:Set("shared", "from-A")
        assert.are.equal("from-A", select(1, a:Get("shared")))
        assert.is_false(select(2, b:Get("shared")))   -- B never saw it
        b:Set("shared", "from-B")
        assert.are.equal("from-A", select(1, a:Get("shared")))  -- A unchanged by B's write
        assert.are.equal("from-B", select(1, b:Get("shared")))
    end)

    it("ClearAll empties every named store but keeps the handles valid", function()
        local c = newCache()
        local a = c:Store("alpha")
        local b = c:Store("beta")
        a:Set("k", 1)
        b:Set("k", 2)
        c:ClearAll()
        assert.is_false(select(2, a:Get("k")))    -- both stores drained
        assert.is_false(select(2, b:Get("k")))
        assert.is_true(c:HasStore("alpha"))       -- the stores themselves survive
        a:Set("k", 9)                             -- existing handle still usable
        assert.are.equal(9, select(1, a:Get("k")))
    end)
end)
