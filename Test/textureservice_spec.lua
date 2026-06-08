local S = dofile("Test/support.lua")

-- A fresh TextureService with a stubbed holder frame and a FAKE "dumb widget" that records its
-- setters (a _sets counter on every SetTexture/SetAtlas), so we can assert pooling / original dedupe
-- / paint memoisation / hold counts without the real WoW texture objects.
local function setup()
    _G.UIParent = {}
    _G.CreateFrame = function() return { Hide = function() end, Show = function() end } end
    _G.C_Texture = nil                          -- nothing resolves as an atlas (isAtlas -> false)
    local ns = S.newNs()
    ns.UI = ns.UI or {}
    ns.UI.Widgets = { Texture = function()
        local w = { _sets = 0 }
        function w:SetTexture(f) self._image, self._sets = f, self._sets + 1; return self end
        function w:SetAtlas(a)   self._image, self._sets = a, self._sets + 1; return self end
        function w:SetCoords(l, r, t, b) self._coords = { l, r, t, b }; return self end
        function w:SetParent()       return self end
        function w:ClearAllPoints()  return self end
        function w:SetPoint()        return self end
        function w:SetSize()         return self end
        function w:SetDrawLayer()    return self end
        function w:Show() self._shown = true;  return self end
        function w:Hide() self._shown = false; return self end
        function w:Reset() self._image, self._coords, self._shown = nil, nil, false; return self end
        return w
    end }
    S.load(ns, "Services/TextureService.lua")
    local ts = ns._captured["TextureService"]
    ts:OnInitialize()
    return ts
end

describe("TextureService edit pooling", function()
    it("reuses a released edit widget instead of making a new one", function()
        local ts = setup()
        local a = ts:Acquire()
        ts:Release(a)
        assert.are.equal(a, ts:Acquire())       -- same object handed back out of the pool
    end)
    it("creates a fresh widget when the pool is empty", function()
        local ts = setup()
        assert.are_not.equal(ts:Acquire(), ts:Acquire())
    end)
end)

describe("TextureService paint memoisation", function()
    it("skips re-painting the same image + edits, repaints on a change", function()
        local ts = setup()
        local tw = ts:Acquire()
        ts:_Paint(tw, 5, false, 0, 1, 0, 1)
        local n = tw._sets
        ts:_Paint(tw, 5, false, 0, 1, 0, 1)     -- identical -> no-op (no new SetTexture)
        assert.are.equal(n, tw._sets)
        ts:_Paint(tw, 5, false, 0, 0.5, 0, 1)   -- different crop -> repaint
        assert.are.equal(n + 1, tw._sets)
        ts:_Paint(tw, 9, false, 0, 0.5, 0, 1)   -- different image -> repaint
        assert.are.equal(n + 2, tw._sets)
    end)
    it("repaints again after the widget is released and reused", function()
        local ts = setup()
        local tw = ts:Acquire()
        ts:_Paint(tw, 5, false, 0, 1, 0, 1)
        local n = tw._sets
        ts:Release(tw)
        local tw2 = ts:Acquire()
        assert.are.equal(tw, tw2)               -- pooled back out
        ts:_Paint(tw2, 5, false, 0, 1, 0, 1)    -- memo cleared on release -> repaints
        assert.are.equal(n + 1, tw2._sets)
    end)
end)

describe("TextureService edits load the path directly", function()
    it("an edit loads the image path itself (no second copy)", function()
        local ts = setup()
        local tw = ts:Acquire()
        ts:_Paint(tw, 5, false, 0, 1, 0, 1)
        assert.are.equal(5, tw._image)               -- loaded the path directly onto the widget
    end)
end)

describe("TextureService image links (refcount)", function()
    it("counts one image per distinct path, held while any edit shows it", function()
        local ts = setup()
        local a, b = ts:Acquire(), ts:Acquire()
        ts:_Paint(a, 5, false, 0, 1, 0, 1)
        ts:_Paint(b, 5, false, 0, 1, 0, 1)           -- same image on two edits
        local s = ts:Stats()
        assert.are.equal(1, s.owned)                 -- one distinct image
        assert.are.equal(1, s.inUse)                 -- held
        assert.are.equal(0, s.idle)
    end)
    it("a replaced image idles ONLY when nothing else still shows it", function()
        local ts = setup()
        local a, b = ts:Acquire(), ts:Acquire()
        ts:_Paint(a, 5, false, 0, 1, 0, 1)
        ts:_Paint(b, 5, false, 0, 1, 0, 1)           -- image 5 shown by a AND b
        ts:_Paint(a, 9, false, 0, 1, 0, 1)           -- a: 5 -> 9; b still shows 5
        local s = ts:Stats()
        assert.are.equal(2, s.owned)                 -- images 5 and 9
        assert.are.equal(2, s.inUse)                 -- both held (5 by b, 9 by a)
        assert.are.equal(0, s.idle)
        ts:_Paint(b, 9, false, 0, 1, 0, 1)           -- b: 5 -> 9; now nothing shows 5
        s = ts:Stats()
        assert.are.equal(1, s.inUse)                 -- only image 9 held
        assert.are.equal(1, s.idle)                  -- image 5 idled
    end)
    it("changing only the crop does not churn the link", function()
        local ts = setup()
        local a = ts:Acquire()
        ts:_Paint(a, 5, false, 0, 1, 0, 1)
        ts:_Paint(a, 5, false, 0, 0.5, 0, 1)         -- same image, different crop
        local s = ts:Stats()
        assert.are.equal(1, s.owned); assert.are.equal(1, s.inUse); assert.are.equal(0, s.idle)
    end)
    it("re-showing an idled image reuses its link (no new image)", function()
        local ts = setup()
        local a = ts:Acquire()
        ts:_Paint(a, 5, false, 0, 1, 0, 1)
        ts:_Paint(a, 9, false, 0, 1, 0, 1)           -- 5 idled, 9 in use
        assert.are.equal(2, ts:Stats().owned)
        ts:_Paint(a, 5, false, 0, 1, 0, 1)           -- back to 5 (reuse its link), 9 idled
        local s = ts:Stats()
        assert.are.equal(2, s.owned)                 -- no new image record
        assert.are.equal(1, s.inUse); assert.are.equal(1, s.idle)
    end)
    it("releasing an edit drops its image to idle", function()
        local ts = setup()
        local a = ts:Acquire()
        ts:_Paint(a, 5, false, 0, 1, 0, 1)
        assert.are.equal(1, ts:Stats().inUse)
        ts:Release(a)
        local s = ts:Stats()
        assert.are.equal(0, s.inUse); assert.are.equal(1, s.idle)
    end)
end)

describe("TextureService widget pool", function()
    it("reuses widgets: the widget total doesn't grow on release + reacquire", function()
        local ts = setup()
        local a = ts:Acquire(); ts:Acquire()
        assert.are.equal(2, ts:Stats().widgets)
        assert.are.equal(0, ts:Stats().widgetsIdle)
        ts:Release(a)
        assert.are.equal(1, ts:Stats().widgetsIdle)
        ts:Acquire()                                 -- reuse the released one
        assert.are.equal(2, ts:Stats().widgets)      -- total never grew
        assert.are.equal(0, ts:Stats().widgetsIdle)
    end)
end)
