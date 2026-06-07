local S = dofile("Test/support.lua")

-- Theme is a plain table (ns.Theme), built on ns.Color, so load Class -> Type -> Color ->
-- Theme into a bare namespace (the shared newNs() stubs Theme, so it can't be used here).
local function theme()
    local ns = {}
    assert(loadfile("Core/Class.lua"))("HagAIO", ns)
    assert(loadfile("Core/Type.lua"))("HagAIO", ns)
    assert(loadfile("Core/Color.lua"))("HagAIO", ns)
    assert(loadfile("Core/Theme.lua"))("HagAIO", ns)
    return ns.Theme
end

describe("Theme", function()
    it("Colorize wraps text in the palette colour escape", function()
        assert.are.equal("|cff4ab3e6hi|r", (theme()).Colorize("accent", "hi"))
    end)

    it("Colorize falls back to the text colour for an unknown key", function()
        local T = theme()
        assert.are.equal("|cff" .. T.hex.text .. "X|r", T.Colorize("nope", "X"))
    end)

    it("Unpack returns r,g,b,a from the Color-backed palette", function()
        local r, g, b, a = (theme()).Unpack("accent")   -- #4ab3e6 @ alpha 1
        assert.near(0.290, r, 1e-3); assert.near(0.702, g, 1e-3); assert.near(0.902, b, 1e-3)
        assert.are.equal(1, a)
    end)

    it("Unpack honours an alpha override", function()
        local _, _, _, a = (theme()).Unpack("accent", 0.5)
        assert.are.equal(0.5, a)
    end)

    it("Unpack falls back to the text colour for an unknown key", function()
        local T = theme()
        assert.are.equal(select(1, T.Unpack("text")), select(1, T.Unpack("nope")))
    end)

    it("Backdrop has the expected shape with a default 1px edge", function()
        local T = theme()
        local b = T.Backdrop()
        assert.are.equal(T.WHITE, b.bgFile)
        assert.are.equal(T.WHITE, b.edgeFile)
        assert.are.equal(1, b.edgeSize)
        assert.are.equal(0, b.insets.left)
        assert.are.equal(3, T.Backdrop(3).edgeSize)   -- explicit edge size
    end)
end)
