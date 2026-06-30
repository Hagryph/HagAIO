local addonName, ns = ...

-- Lib/Format.lua
-- Pure formatters -- no WoW API. Extracted from the modules that kept them as
-- file-locals so their edge cases (nil, negative, zero-pad, hour rollover) are unit-
-- testable. ns.Format is a single value table (not instantiated), like a small utility lib.

local floor = math.floor

local Format = {}

-- Thousands-separated whole number: rounds to the nearest integer (floor(n+0.5)) then hands
-- off to WoW's BreakUpLargeNumbers for the locale-correct digit grouping. This is the only
-- entry here that touches a WoW global -- it's a thin number formatter, kept with the others
-- so its rounding edge cases stay testable (the global is stubbable headless).
function Format.Commafy(n)
    return BreakUpLargeNumbers(floor(n + 0.5))
end

-- Human duration: "-" for nil/<=0. Shows the two most significant units for the scale:
--   >= 25h -> "1d 01h"   |   >= 1h -> "1h 01m"   |   >= 1m -> "10m 05s"   |   else "45s".
-- Days appear only from 25h up, so the smallest day form is "1d 01h" (never "1d 00h"); 24h-25h
-- still reads "24h MMm".
function Format.Clock(seconds)
    if not seconds or seconds <= 0 then return "-" end
    seconds = floor(seconds)
    if seconds >= 25 * 3600 then
        return ("%dd %02dh"):format(floor(seconds / 86400), floor((seconds % 86400) / 3600))
    end
    local h = floor(seconds / 3600)
    local m = floor((seconds % 3600) / 60)
    local s = seconds % 60
    if h > 0 then return ("%dh %02dm"):format(h, m) end
    if m > 0 then return ("%dm %02ds"):format(m, s) end
    return ("%ds"):format(s)
end

-- Countdown clock "M:SS": "-:--" for nil, clamped at 0, seconds zero-padded ("10:05").
function Format.MMSS(s)
    if s == nil then return "-:--" end
    if s < 0 then s = 0 end
    s = floor(s + 0.5)
    return ("%d:%02d"):format(floor(s / 60), s % 60)
end

-- "x ago" coarse age (it answers "this reset?"): "<1h ago" under an hour, whole hours under a
-- day, then whole days. Floors each unit. Callers pass an already non-negative seconds delta.
function Format.TimeAgo(secs)
    if secs < 3600 then return "<1h ago" end
    if secs < 86400 then return floor(secs / 3600) .. "h ago" end
    return floor(secs / 86400) .. "d ago"
end

ns.LibManager:RegisterValue("Format", Format)
