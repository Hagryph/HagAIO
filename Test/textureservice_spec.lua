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

describe("TextureService originals (dedupe)", function()
    it("returns one shared original per image", function()
        local ts = setup()
        assert.are.equal(ts:Original(7), ts:Original(7))
    end)
    it("returns distinct originals for distinct images", function()
        local ts = setup()
        assert.are_not.equal(ts:Original(1), ts:Original(2))
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

describe("TextureService edits hold no original", function()
    it("an edit loads the image path itself and references no original", function()
        local ts = setup()
        local tw = ts:Acquire()
        ts:_Paint(tw, 5, false, 0, 1, 0, 1)
        assert.are.equal(5, tw._image)               -- loaded the path directly
        assert.is_nil(tw._original)                  -- ...and links to no original
    end)
    it("painting edits never creates an original (no redundant second load)", function()
        local ts = setup()
        local a, b = ts:Acquire(), ts:Acquire()
        ts:_Paint(a, 5, false, 0, 1, 0, 1)
        ts:_Paint(b, 5, false, 0, 0.5, 0, 1)
        assert.are.equal(0, ts:Stats().originals)
    end)
    it("an original is created only on explicit request, then weak-cached + deduped", function()
        local ts = setup()
        assert.are.equal(0, ts:Stats().originals)
        local o = ts:Original(5)
        assert.are.equal(5, o._image)                -- the original loaded the plain image
        assert.are.equal(o, ts:Original(5))          -- deduped
        assert.are.equal(1, ts:Stats().originals)
    end)
end)

describe("TextureService hold counts", function()
    it("reports owned / idle / in-use as widgets are acquired and released", function()
        local ts = setup()
        local a = ts:Acquire(); ts:Acquire()
        local s = ts:Stats()
        assert.are.equal(2, s.owned)
        assert.are.equal(0, s.idle)
        assert.are.equal(2, s.inUse)
        ts:Release(a)
        s = ts:Stats()
        assert.are.equal(2, s.owned)                 -- pooled, so the total never grew
        assert.are.equal(1, s.idle)
        assert.are.equal(1, s.inUse)
    end)
end)
