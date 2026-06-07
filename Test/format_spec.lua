local S = dofile("Test/support.lua")

local function fmt()
    local ns = {}
    assert(loadfile("Lib/Format.lua"))("HagAIO", ns)
    return ns.Format
end

describe("Format.Clock", function()
    it("formats durations with the right unit and zero-padding", function()
        local F = fmt()
        assert.are.equal("-", F.Clock(nil))
        assert.are.equal("-", F.Clock(0))
        assert.are.equal("-", F.Clock(-5))
        assert.are.equal("45s", F.Clock(45))
        assert.are.equal("10m 05s", F.Clock(605))
        assert.are.equal("1h 01m", F.Clock(3661))
    end)
end)

describe("Format.MMSS", function()
    it("formats a countdown clock, clamped and zero-padded", function()
        local F = fmt()
        assert.are.equal("-:--", F.MMSS(nil))
        assert.are.equal("0:00", F.MMSS(-5))   -- clamped at 0
        assert.are.equal("1:23", F.MMSS(83))
        assert.are.equal("10:05", F.MMSS(605)) -- seconds zero-padded
        assert.are.equal("0:01", F.MMSS(0.6))  -- rounds to nearest second
    end)
end)
