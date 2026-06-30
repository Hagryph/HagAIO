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

describe("Format.Commafy", function()
    -- Commafy rounds with floor(n+0.5) then hands the WHOLE number to BreakUpLargeNumbers
    -- for grouping. We stub that global with a faithful comma-grouper so the spec pins both
    -- the rounding (what integer gets passed) and that grouping is applied to it.
    local function group(n)
        local sign = n < 0 and "-" or ""
        local s = tostring(math.abs(n))
        local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
        return sign .. out
    end

    it("rounds to the nearest integer, then groups in thousands", function()
        local F = fmt()
        _G.BreakUpLargeNumbers = group
        assert.are.equal("1,234,567", F.Commafy(1234567))
        assert.are.equal("999", F.Commafy(999))             -- below 1000: no separator
        assert.are.equal("1,000", F.Commafy(1000))          -- exact thousand
        assert.are.equal("0", F.Commafy(0))
        assert.are.equal("1,500", F.Commafy(1499.6))        -- floor(n+0.5) rounds up
        assert.are.equal("1,499", F.Commafy(1499.4))        -- floor(n+0.5) rounds down
        assert.are.equal("-1,234", F.Commafy(-1234))        -- negatives keep their sign
    end)

    it("passes the rounded integer (not the raw float) to BreakUpLargeNumbers", function()
        local F = fmt()
        local seen
        _G.BreakUpLargeNumbers = function(v) seen = v; return tostring(v) end
        F.Commafy(2500.9)
        assert.are.equal(2501, seen)   -- floor(2500.9 + 0.5) == 2501, an integer
    end)

    it("errors on a non-number argument (floor needs a number) -- unchanged behaviour", function()
        local F = fmt()
        _G.BreakUpLargeNumbers = group
        assert.has_error(function() F.Commafy("lots") end)
    end)
end)

describe("Format.TimeAgo", function()
    it("shows <1h under an hour, whole hours under a day, then whole days (floored)", function()
        local F = fmt()
        assert.are.equal("<1h ago", F.TimeAgo(0))
        assert.are.equal("<1h ago", F.TimeAgo(3599))     -- just under an hour
        assert.are.equal("1h ago", F.TimeAgo(3600))      -- exactly an hour
        assert.are.equal("5h ago", F.TimeAgo(5 * 3600 + 59 * 60))  -- floors the partial hour
        assert.are.equal("23h ago", F.TimeAgo(86399))    -- just under a day
        assert.are.equal("1d ago", F.TimeAgo(86400))     -- exactly a day
        assert.are.equal("6d ago", F.TimeAgo(6 * 86400 + 23 * 3600)) -- floors the partial day
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
