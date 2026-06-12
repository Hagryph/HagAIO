local S = dofile("Test/support.lua")

local function fmt()
    local ns = S.newNs()   -- Format registers via ns.LibManager:RegisterValue (stubbed by the rig)
    S.load(ns, "Lib/Format.lua")
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

    it("uses days + hours from 25h up, hours + minutes below it", function()
        local F = fmt()
        assert.are.equal("24h 00m", F.Clock(24 * 3600))           -- still hours+minutes at 24h
        assert.are.equal("24h 59m", F.Clock(24 * 3600 + 59 * 60)) -- just under the day threshold
        assert.are.equal("1d 01h", F.Clock(25 * 3600))            -- 25h -> smallest day form
        assert.are.equal("6d 23h", F.Clock(6 * 86400 + 23 * 3600))-- a near-full weekly reset
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
