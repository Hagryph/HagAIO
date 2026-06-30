local addonName, ns = ...
local Class = ns.Class

-- Lib/ResetLedger.lua
-- Pure data-shaping for the Dashboard module -- no WoW API. Extracted so the bits that
-- decide what's stale and how a cell reads are unit-testable:
--   * CharKey         -- the stable cross-character store key ("Name-Realm").
--   * NeedsWeeklyReset / NeedsDailyReset -- has a reset passed since a char was last seen?
--     (so stored weekly/daily progress for an offline alt is shown as reset, not stale).
--   * Progress        -- a (done count, threshold) -> fraction + done flag (nil/zero-safe).
--   * KeystoneText    -- "Dungeon +Level", or a dash when the character holds no key.
-- The reset boundary comes from C_DateAndTime.GetSecondsUntil*Reset() (a plain number, not a
-- secret), passed in by the module; this lib never touches the live client.

local ResetLedger = Class.new("ResetLedger", ns.Lib)

local DAY  = 24 * 60 * 60
local WEEK = 7 * DAY

-- Stable account-wide key for a character. Realm whitespace is stripped so "Area 52" and
-- "Area52" can't produce two rows for the same character.
function ResetLedger:CharKey(name, realm)
    return tostring(name or "?") .. "-" .. (tostring(realm or ""):gsub("%s+", ""))
end

-- The server time of the most recent reset, derived from the seconds until the NEXT one.
function ResetLedger:LastWeeklyReset(now, secsUntilNext) return now + (secsUntilNext or 0) - WEEK end
function ResetLedger:LastDailyReset(now, secsUntilNext)  return now + (secsUntilNext or 0) - DAY  end

-- Has a weekly reset occurred since this character was last snapshotted? If so its stored
-- weekly progress (vault, lockouts, weekly quests) is from before the reset and should read
-- as fresh/empty rather than as last week's leftovers. nil lastSeen -> false (never seen).
function ResetLedger:NeedsWeeklyReset(lastSeen, now, secsUntilNext)
    if not lastSeen then return false end
    return lastSeen < self:LastWeeklyReset(now, secsUntilNext)
end

function ResetLedger:NeedsDailyReset(lastSeen, now, secsUntilNext)
    if not lastSeen then return false end
    return lastSeen < self:LastDailyReset(now, secsUntilNext)
end

-- (done, threshold) -> clamped fraction in [0,1] and a done flag. Nil-safe; a non-positive
-- threshold is treated as "no requirement" (fraction 0, not done).
function ResetLedger:Progress(done, threshold)
    done = done or 0
    if not threshold or threshold <= 0 then return 0, false end
    local r = done / threshold
    if r > 1 then r = 1 end
    return r, done >= threshold
end

-- "Dungeon +Level" for the held keystone, or "-" when the character holds none.
function ResetLedger:KeystoneText(dungeonName, level)
    if not (dungeonName and level and level > 0) then return "-" end
    return ("%s +%d"):format(dungeonName, level)
end

-- Reset-aware doneness: a turn-in only counts while its done_at falls inside the CURRENT reset
-- window (daily/weekly). A legacy row without done_at (nil or 0) never counts (it re-earns its
-- check on the next turn-in). `now` is the server clock and `untilNext` the seconds-until-next
-- reset for this frequency; nil untilNext means no reset info -> trust the recorded state (true).
-- The caller does the GetServerTime / C_DateAndTime reads and hands the numbers in.
function ResetLedger:InCurrentWindow(doneAt, freq, now, untilNext)
    if not doneAt or doneAt == 0 then return false end
    if not untilNext then return true end                 -- no reset info: trust the recorded state
    local period = (freq == "daily") and DAY or WEEK
    return doneAt >= ((now + untilNext) - period)         -- after the LAST reset = inside this window
end

ns.LibManager:Register(ResetLedger:New("ResetLedger"))
