local S = dofile("Test/support.lua")

local function rl()
    local ns = S.newNs()
    S.load(ns, "Lib/ResetLedger.lua")
    return ns._captured["ResetLedger"]
end

local DAY, WEEK = 24 * 60 * 60, 7 * 24 * 60 * 60

describe("ResetLedger:CharKey", function()
    it("joins name and realm and strips realm whitespace", function()
        local l = rl()
        assert.are.equal("Thrall-Area52", l:CharKey("Thrall", "Area 52"))
        assert.are.equal("Jaina-Stormrage", l:CharKey("Jaina", "Stormrage"))
    end)
    it("is nil-safe", function()
        assert.are.equal("?-", (rl()):CharKey(nil, nil))
    end)
end)

describe("ResetLedger reset rollover", function()
    it("flags a weekly reset when last seen before the previous reset boundary", function()
        local l = rl()
        local now, untilNext = 1000000, 3 * DAY    -- last weekly reset was now + 3d - 7d = now - 4d
        local lastReset = now + untilNext - WEEK
        assert.is_true(l:NeedsWeeklyReset(lastReset - 10, now, untilNext))   -- seen before reset -> stale
        assert.is_false(l:NeedsWeeklyReset(lastReset + 10, now, untilNext))  -- seen after reset -> fresh
    end)
    it("flags a daily reset on the same rule", function()
        local l = rl()
        local now, untilNext = 1000000, 6 * 60 * 60   -- 6h until next daily
        local lastReset = now + untilNext - DAY
        assert.is_true(l:NeedsDailyReset(lastReset - 1, now, untilNext))
        assert.is_false(l:NeedsDailyReset(lastReset + 1, now, untilNext))
    end)
    it("never-seen (nil lastSeen) is not a reset", function()
        local l = rl()
        assert.is_false(l:NeedsWeeklyReset(nil, 1000000, DAY))
        assert.is_false(l:NeedsDailyReset(nil, 1000000, DAY))
    end)
end)

describe("ResetLedger last-reset boundary", function()
    -- The module feeds these from C_DateAndTime.GetSecondsUntil*Reset(); when that WoW API is
    -- present we get a number, when it's absent (returns nil) the "secsUntilNext or 0" default
    -- pins the boundary to exactly one period before `now`.
    it("derives the previous weekly/daily reset from seconds-until-next (API present)", function()
        local l = rl()
        _G.C_DateAndTime = {
            GetSecondsUntilWeeklyReset = function() return 3 * DAY end,
            GetSecondsUntilDailyReset  = function() return 6 * 60 * 60 end,
        }
        local now = 1000000
        local weekly = _G.C_DateAndTime.GetSecondsUntilWeeklyReset()
        local daily  = _G.C_DateAndTime.GetSecondsUntilDailyReset()
        assert.are.equal(now + weekly - WEEK, l:LastWeeklyReset(now, weekly))
        assert.are.equal(now + daily  - DAY,  l:LastDailyReset(now, daily))
        _G.C_DateAndTime = nil
    end)
    it("defaults secsUntilNext to 0 when the reset API is absent (nil)", function()
        local l = rl()
        _G.C_DateAndTime = nil   -- API unavailable -> GetSecondsUntil*Reset() yields nil
        local now = 1000000
        assert.are.equal(now - WEEK, l:LastWeeklyReset(now, nil))
        assert.are.equal(now - DAY,  l:LastDailyReset(now, nil))
    end)
    it("the nil default still feeds NeedsWeeklyReset/NeedsDailyReset correctly", function()
        local l = rl()
        local now = 1000000
        -- With secsUntilNext nil the boundary is now - WEEK; a char seen before that is stale.
        assert.is_true(l:NeedsWeeklyReset(now - WEEK - 1, now, nil))
        assert.is_false(l:NeedsWeeklyReset(now - WEEK + 1, now, nil))
        assert.is_true(l:NeedsDailyReset(now - DAY - 1, now, nil))
        assert.is_false(l:NeedsDailyReset(now - DAY + 1, now, nil))
    end)
end)

describe("ResetLedger:Progress", function()
    it("returns fraction + done flag", function()
        local l = rl()
        local r, done = l:Progress(4, 8)
        assert.near(0.5, r); assert.is_false(done)
        local r2, done2 = l:Progress(8, 8)
        assert.are.equal(1, r2); assert.is_true(done2)
    end)
    it("clamps over-threshold to 1 and stays done", function()
        local l = rl()
        local r, done = l:Progress(12, 8)
        assert.are.equal(1, r); assert.is_true(done)
    end)
    it("treats a non-positive / missing threshold as no requirement", function()
        local l = rl()
        local r, done = l:Progress(5, 0)
        assert.are.equal(0, r); assert.is_false(done)
        assert.is_false(select(2, l:Progress(nil, nil)))
    end)
end)

describe("ResetLedger:InCurrentWindow", function()
    -- The module reads GetServerTime + C_DateAndTime.GetSecondsUntil*Reset() and hands the
    -- numbers in; this is the pure window test. now + untilNext - period is the LAST reset.
    it("counts a turn-in inside the current daily/weekly window, not before it", function()
        local l = rl()
        local now, untilDaily = 1000000, 6 * 60 * 60      -- last daily reset = now + 6h - 1d
        local lastDaily = now + untilDaily - DAY
        assert.is_true(l:InCurrentWindow(lastDaily + 1, "daily", now, untilDaily))   -- after reset
        assert.is_false(l:InCurrentWindow(lastDaily - 1, "daily", now, untilDaily))  -- before reset
        local untilWeekly = 3 * DAY
        local lastWeekly = now + untilWeekly - WEEK
        assert.is_true(l:InCurrentWindow(lastWeekly + 1, "weekly", now, untilWeekly))
        assert.is_false(l:InCurrentWindow(lastWeekly - 1, "weekly", now, untilWeekly))
    end)
    it("is inclusive at the exact reset boundary (>=)", function()
        local l = rl()
        local now, untilDaily = 1000000, 6 * 60 * 60
        local lastDaily = now + untilDaily - DAY
        assert.is_true(l:InCurrentWindow(lastDaily, "daily", now, untilDaily))   -- exactly at boundary
    end)
    it("treats a missing/legacy done_at (nil or 0) as never done", function()
        local l = rl()
        assert.is_false(l:InCurrentWindow(nil, "weekly", 1000000, 3 * DAY))
        assert.is_false(l:InCurrentWindow(0, "weekly", 1000000, 3 * DAY))   -- legacy zero row
        assert.is_false(l:InCurrentWindow(0, "daily", 1000000, nil))        -- zero wins over missing-info
    end)
    it("trusts the recorded state (true) when there is no reset info (nil untilNext)", function()
        local l = rl()
        assert.is_true(l:InCurrentWindow(1, "weekly", 1000000, nil))   -- any non-zero done_at -> true
        assert.is_true(l:InCurrentWindow(999, "daily", 1000000, nil))
    end)
    it("uses the right period per frequency (daily 1d vs weekly 7d)", function()
        local l = rl()
        local now, untilNext = 1000000, 0   -- last reset is exactly `now` for either frequency
        -- A done_at one period-minus-a-bit before now: inside the DAY window only as weekly.
        local doneAt = now - DAY - 1        -- before the daily reset, after the weekly reset
        assert.is_false(l:InCurrentWindow(doneAt, "daily", now, untilNext))
        assert.is_true(l:InCurrentWindow(doneAt, "weekly", now, untilNext))
    end)
end)

describe("ResetLedger:KeystoneText", function()
    it("formats a held keystone", function()
        assert.are.equal("Ara-Kara +12", (rl()):KeystoneText("Ara-Kara", 12))
    end)
    it("shows a dash when there's no key", function()
        local l = rl()
        assert.are.equal("-", l:KeystoneText(nil, nil))
        assert.are.equal("-", l:KeystoneText("Ara-Kara", 0))
        assert.are.equal("-", l:KeystoneText("Ara-Kara", nil))
    end)
end)
