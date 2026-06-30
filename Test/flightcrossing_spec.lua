-- Test/flightcrossing_spec.lua -- pure crossing arithmetic extracted from FlightTimers.
-- Feeds SYNTHETIC position streams through FlightCrossing.PollCrossing to exercise the
-- min-distance tracking + CROSS_MARGIN hysteresis + FLYOVER_RANGE skip + no-world-pos skip,
-- and checks the segment-derivation helpers (PathIndexOf / PathNamesBetween / RecordCross /
-- RecordFinalLeg) incl. the seg > 1 floor + skipped-node bridging, plus the DIRECT-write
-- better-time replacement policy (ShouldReplaceDirect). Pure logic: no WoW API, no module.

local S = dofile("Test/support.lua")

local function fc()
    local ns = S.newNs()
    S.load(ns, "Lib/FlightCrossing.lua")
    return ns._captured["FlightCrossing"]
end

local CM, FR = 75, 75   -- mirror Lib defaults (CROSS_MARGIN, FLYOVER_RANGE)

-- A path node at world (x, y) on continent c (default 1).
local function node(name, x, y, c) return { name = name, world = { c = c or 1, x = x, y = y } } end

describe("FlightCrossing.PollCrossing: tracking + hysteresis", function()
    it("tracks an ever-closer approach (returns the new min dist + stamp time)", function()
        local C = fc()
        local n = node("B", 1000, 0)
        -- Far away, first sample -> track (crossMinDist starts nil).
        local d1 = C.PollCrossing(n, 0, 0, 1, 5.0, nil, nil, CM, FR)
        assert.are.equal("track", d1.action)
        assert.are.equal(1000, d1.minDist)
        assert.are.equal(5.0, d1.minTime)
        -- Closer -> track again with the smaller distance.
        local d2 = C.PollCrossing(n, 600, 0, 1, 5.1, 1000, 5.0, CM, FR)
        assert.are.equal("track", d2.action)
        assert.are.equal(400, d2.minDist)
        assert.are.equal(5.1, d2.minTime)
    end)

    it("approaching then crossing: records only once past closest approach + CROSS_MARGIN", function()
        local C = fc()
        local n = node("B", 1000, 0)
        -- Closest approach reached at 30 yds (within FLYOVER_RANGE).
        local closest = C.PollCrossing(n, 970, 0, 1, 6.0, 200, 5.0, CM, FR)
        assert.are.equal("track", closest.action)
        assert.are.equal(30, closest.minDist)
        -- Now 100 yds away: 100 > 30 + 75? No (105). Still waiting -- hysteresis not cleared.
        local notyet = C.PollCrossing(n, 1100, 0, 1, 6.1, 30, 6.0, CM, FR)
        assert.are.equal("wait", notyet.action)
        -- 110 yds away: 110 > 30 + 75 (105) -> advance + record (came within range).
        local crossed = C.PollCrossing(n, 1110, 0, 1, 6.2, 30, 6.0, CM, FR)
        assert.are.equal("advance", crossed.action)
        assert.is_true(crossed.record)
    end)

    it("a fly-over beyond FLYOVER_RANGE advances but does NOT record", function()
        local C = fc()
        local n = node("C", 2000, 0)
        -- Closest approach was 400 yds (swung wide) -- beyond FLYOVER_RANGE.
        -- Now 500 yds: 500 > 400 + 75 (475) -> advance, but record is false.
        local d = C.PollCrossing(n, 2500, 0, 1, 7.0, 400, 6.5, CM, FR)
        assert.are.equal("advance", d.action)
        assert.is_false(d.record)
    end)

    it("a node with no world position is skipped", function()
        local C = fc()
        local n = { name = "X" }   -- no .world
        local d = C.PollCrossing(n, 100, 100, 1, 8.0, 50, 7.0, CM, FR)
        assert.are.equal("skip", d.action)
    end)

    it("waits when the player has no world position", function()
        local C = fc()
        local n = node("B", 1000, 0)
        local d = C.PollCrossing(n, nil, nil, nil, 9.0, 50, 8.0, CM, FR)
        assert.are.equal("wait", d.action)
    end)

    it("waits when the player is on a different continent than the node", function()
        local C = fc()
        local n = node("B", 1000, 0, 1)
        local d = C.PollCrossing(n, 1000, 0, 2, 9.5, 50, 8.0, CM, FR)   -- pc=2, node c=1
        assert.are.equal("wait", d.action)
    end)
end)

describe("FlightCrossing.PathIndexOf", function()
    it("finds a node by name", function()
        local C = fc()
        local path = { node("A", 0, 0), node("B", 1, 0), node("C", 2, 0) }
        assert.are.equal(2, C.PathIndexOf(path, "B"))
    end)
    it("returns nil for an absent name and for a nil path", function()
        local C = fc()
        local path = { node("A", 0, 0) }
        assert.is_nil(C.PathIndexOf(path, "Z"))
        assert.is_nil(C.PathIndexOf(nil, "A"))
    end)
end)

describe("FlightCrossing.PathNamesBetween", function()
    it("returns the names strictly between two indices", function()
        local C = fc()
        local path = { node("A", 0, 0), node("B", 1, 0), node("C", 2, 0), node("D", 3, 0) }
        local via = C.PathNamesBetween(path, 1, 4)   -- between A(1) and D(4) -> B, C
        assert.are.equal("B", via[1])
        assert.are.equal("C", via[2])
        assert.are.equal(2, #via)
    end)
    it("returns nil for adjacent indices (nothing between)", function()
        local C = fc()
        local path = { node("A", 0, 0), node("B", 1, 0) }
        assert.is_nil(C.PathNamesBetween(path, 1, 2))   -- j not > i+1
    end)
    it("returns nil when a name in the gap is missing (no holey span)", function()
        local C = fc()
        local path = { node("A", 0, 0), { world = { c = 1, x = 1, y = 0 } }, node("C", 2, 0) }
        assert.is_nil(C.PathNamesBetween(path, 1, 3))   -- middle node has no name
    end)
    it("returns nil for nil/incomplete inputs", function()
        local C = fc()
        assert.is_nil(C.PathNamesBetween(nil, 1, 4))
        local path = { node("A", 0, 0), node("B", 1, 0) }
        assert.is_nil(C.PathNamesBetween(path, nil, 4))
    end)
end)

describe("FlightCrossing.RecordCross: segment derivation", function()
    it("derives the prev->this segment with the seg > 1 floor", function()
        local C = fc()
        local path = { node("A", 0, 0), node("B", 1000, 0), node("C", 2000, 0) }
        local crossTimes = { [1] = 100.0, [3] = 120.0 }   -- crossing C stamped at 120
        local a, b, seg, via = C.RecordCross(path, crossTimes, 1, 3, 120.0)
        assert.are.equal("A", a)
        assert.are.equal("C", b)
        assert.are.equal(20.0, seg)
    end)

    it("bridges a skipped node as a via hop (A->C over B)", function()
        local C = fc()
        local path = { node("A", 0, 0), node("B", 1000, 0), node("C", 2000, 0) }
        local crossTimes = { [1] = 100.0, [3] = 120.0 }
        local _, _, _, via = C.RecordCross(path, crossTimes, 1, 3, 120.0)
        assert.are.equal("B", via[1])   -- the skipped node bridged as a hop
        assert.are.equal(1, #via)
    end)

    it("floors out a sub-1s segment (returns nil)", function()
        local C = fc()
        local path = { node("A", 0, 0), node("B", 1000, 0) }
        local crossTimes = { [1] = 100.0, [2] = 100.5 }   -- only 0.5s apart
        assert.is_nil(C.RecordCross(path, crossTimes, 1, 2, 100.5))
    end)

    it("returns nil when prev and this resolve to the same name", function()
        local C = fc()
        local path = { node("A", 0, 0), node("A", 1000, 0) }   -- duplicate name
        local crossTimes = { [1] = 100.0, [2] = 130.0 }
        assert.is_nil(C.RecordCross(path, crossTimes, 1, 2, 130.0))
    end)

    it("returns nil when the previous stamp is missing", function()
        local C = fc()
        local path = { node("A", 0, 0), node("B", 1000, 0) }
        local crossTimes = { [2] = 130.0 }   -- no [1]
        assert.is_nil(C.RecordCross(path, crossTimes, 1, 2, 130.0))
    end)
end)

describe("FlightCrossing.RecordFinalLeg: dismount segment", function()
    it("times the last-flown node -> landing dismount", function()
        local C = fc()
        local path = { node("A", 0, 0), node("B", 1000, 0), node("C", 2000, 0) }
        local crossTimes = { [1] = 100.0, [2] = 110.0 }   -- last actually crossed = B (idx 2)
        local from, landed, seg, via = C.RecordFinalLeg(path, crossTimes, 2, "C", 121.0)
        assert.are.equal("B", from)
        assert.are.equal("C", landed)
        assert.are.equal(11.0, seg)
        assert.is_nil(via)   -- B and C are adjacent: nothing between
    end)

    it("bridges a skipped second-to-last node (from source over the skip)", function()
        local C = fc()
        -- B (idx 2) was skipped, so the last node we flew over is the source A (idx 1).
        local path = { node("A", 0, 0), node("B", 1000, 0), node("C", 2000, 0) }
        local crossTimes = { [1] = 100.0 }   -- only the source is stamped
        local from, landed, seg, via = C.RecordFinalLeg(path, crossTimes, 1, "C", 125.0)
        assert.are.equal("A", from)
        assert.are.equal("C", landed)
        assert.are.equal(25.0, seg)
        assert.are.equal("B", via[1])   -- the skipped second-to-last bridged as a hop
    end)

    it("floors out a sub-1s final leg", function()
        local C = fc()
        local path = { node("A", 0, 0), node("B", 1000, 0) }
        local crossTimes = { [1] = 100.0 }
        assert.is_nil(C.RecordFinalLeg(path, crossTimes, 1, "B", 100.6))   -- 0.6s
    end)

    it("returns nil when the from node equals the landed node", function()
        local C = fc()
        local path = { node("A", 0, 0), node("B", 1000, 0) }
        local crossTimes = { [2] = 100.0 }
        assert.is_nil(C.RecordFinalLeg(path, crossTimes, 2, "B", 130.0))   -- from==landed
    end)
end)

describe("FlightCrossing.ShouldReplaceDirect: better-time policy", function()
    local DIRECT, FLY = 2, 1
    it("inserts when there is no existing row", function()
        assert.are.equal("insert", (fc()).ShouldReplaceDirect(nil, 20, DIRECT))
    end)
    it("replaces a lower-quality (FLY) row even for a tiny time change", function()
        local row = { t = 20, quality = FLY }
        assert.are.equal("replace", (fc()).ShouldReplaceDirect(row, 20.5, DIRECT))
    end)
    it("replaces a DIRECT row only when the time changed by >= 5s", function()
        local row = { t = 20, quality = DIRECT }
        assert.are.equal("replace", (fc()).ShouldReplaceDirect(row, 26, DIRECT))   -- +6s
        assert.are.equal("replace", (fc()).ShouldReplaceDirect(row, 15, DIRECT))   -- -5s (boundary)
    end)
    it("skips a DIRECT row when the time barely moved (< 5s)", function()
        local row = { t = 20, quality = DIRECT }
        assert.are.equal("skip", (fc()).ShouldReplaceDirect(row, 23, DIRECT))   -- +3s
    end)
end)
