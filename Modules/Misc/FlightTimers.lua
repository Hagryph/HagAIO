local addonName, ns = ...
local Class = ns.Class
local Theme = ns.Theme
local W = ns.UI.Widgets

-- Upvalue the globals the flight RECORDER hits while polling a flight: a local lookup beats a
-- global-table lookup on every tick. (Same-name locals -> no call-site churn.)
local GetTime, C_Map, CreateVector2D = GetTime, C_Map, CreateVector2D
local sqrt, huge = math.sqrt, math.huge

-- Modules/Misc/FlightTimers.lua
-- The Flight Timers submodule of Misc (registered under the parent "Misc" module). Times each flight
-- path and shows a countdown both while in flight and when hovering a flight point on the map. The
-- RECORDER is ALWAYS on -- installed in OnInitialize, it builds the shared flight_route/flight_hop
-- tables (contributed by the parent Misc module) even while the submodule is off; the on-screen
-- DISPLAY is gated on the submodule being loaded. The DAO (_Flight*/_Master*) queries the shared
-- database via self:DB().

local fmt = ns.Format.MMSS   -- pure "M:SS" countdown formatter (Lib/Format.lua)
local Flight  = ns.FlightResolver
local Quality = Flight.Quality

-- ========================================================================================
-- FLIGHT TIMERS submodule. The flight feature is one cohesive engine (recorder + timing +
-- display) sharing per-flight state, so it lives as a Submodule SUBCLASS -- every method keeps
-- `self` as the submodule, with no host-prefixing.
-- ========================================================================================
local FlightTimers = Class.new("FlightTimers", ns.Submodule)

-- ---- tunables (flight-path detection distances, yards) --------------------
local ARRIVE_YARDS = 40    -- within this of a path node = we landed there
local CROSS_MARGIN = 75   -- moved this many (linear) yards past the closest approach = passed it
local FLYOVER_RANGE = 75  -- closest approach must be within this to count as flying OVER a node;
                          -- farther than this and the node is skipped (never recorded)

-- DIRECTIONAL route key: a -> b is stored separately from b -> a, because the two
-- directions don't always take the same time (path asymmetry). New recordings use this;
-- the resolver (_RouteTime) prefers same-direction data and falls back to the reverse.
-- Flight times are recorded PER FACTION (the two factions have different flight masters and
-- routes), so every query is scoped by this tag. "?" when the faction isn't known yet.
function FlightTimers:_Faction()
    return UnitFactionGroup("player") or "?"
end

-- ---- lifecycle ------------------------------------------------------------
-- ALWAYS-ON recorder: flight recording builds the data even while the module/submodule is off, so
-- it is installed ONCE at boot (the framework runs Submodule:OnInitialize for every registered
-- submodule, regardless of whether it loads) and never torn down on unload. It uses ns.EventBus:On
-- + a raw C_Timer ticker + a permanent secure hook -- NOT self:On (which would be released on
-- unload). Routes live in the shared SQL database (flight_route + flight_hop, contributed by the
-- parent Misc module; see the _Flight* DAO below).
function FlightTimers:OnInitialize()
    local p = self:_p()
    p.phase = nil       -- nil / "boarding" / "flying"
    p.src = nil

    ns.EventBus:On("TAXIMAP_OPENED", function() self:_OnTaxiMap() end)
    -- TakeTaxiNode is a permanent secure hook, so it installs once per SESSION (the private latch
    -- on this singleton). It resolves the live registered FlightTimers submodule each call rather
    -- than capturing `self`, so it never points at a stale instance.
    if not p.taxiHooked and type(TakeTaxiNode) == "function" then
        hooksecurefunc("TakeTaxiNode", function(slot)
            local f = ns.SubmoduleManager:Get("FlightTimers")
            if f then f:_OnTakeTaxi(slot) end
        end)
        p.taxiHooked = true
    end
end

-- DISPLAY lifecycle (loaded-scoped, run by onLoad/onUnload). The recorder above keeps running
-- regardless; only the on-screen timer + early-landing redirect are gated on the submodule loading.
function FlightTimers:_OnLoad()
    self:_SyncEditMode()   -- register the timer with Edit Mode (only while the "in flight" setting is on)
    -- Redirect on Request-Stop / early landing: hook the API itself (always present; fires however
    -- it's triggered -- button, keybind, macro) rather than the fragile button method. Via the
    -- removable hook helper so unloading uninstalls it automatically.
    if type(TaxiRequestEarlyLanding) == "function" then
        local sub = self
        self:Hook("TaxiRequestEarlyLanding", function()
            if UnitOnTaxi("player") and sub:GetSetting("showInFlight") then
                sub:_OnEarlyLanding()
            end
        end)
    end
end

function FlightTimers:_OnUnload()
    -- Subscriptions + the early-landing hook are released by the framework. Do NOT stop the in-flight
    -- ticker: it is the recording engine (it detects the landing and stores the time), and flight
    -- recording must run even while the submodule is unloaded -- _Tick's recording is ungated; the
    -- DISPLAY is gated in _RefreshDisplay, so the frame stays hidden on its own.
    self:_SyncEditMode()  -- unloaded -> unregister the timer from Edit Mode + hide it
end

-- ======================= recording =========================================
function FlightTimers:_OnTaxiMap()
    self:_CaptureSource()
    self:_HookFlightPins()
    -- flight-master DISCOVERY (seeding flight_master + zone) lives in the LocalTables service.
end

function FlightTimers:_CaptureSource()
    local p = self:_p()
    if not (NumTaxiNodes and TaxiNodeGetType and TaxiNodeName) then return end
    for i = 1, NumTaxiNodes() do
        if TaxiNodeGetType(i) == "CURRENT" then
            p.src = Flight:NodeName(TaxiNodeName(i))
            return
        end
    end
end

-- Record (always) when a flight is taken.
function FlightTimers:_OnTakeTaxi(slot)
    local p = self:_p()
    if TaxiNodeGetType and TaxiNodeGetType(slot) ~= "REACHABLE" then return end
    -- Use the FLIGHT-MAP node name (matched by slotIndex) so the recorded key
    -- matches the one the map-hover tooltip builds; TaxiNodeName(slot) can return
    -- a differently-formatted name and would never match on lookup.
    local dst = (p.nodeNames and p.nodeNames[slot]) or (TaxiNodeName and Flight:NodeName(TaxiNodeName(slot)))
    if not (p.src and dst) then return end

    p.dst = dst
    p.dstMapID = p.flightMapID
    -- resolve the expected time NOW, while the flight map (taxi data) is still
    -- open -- GetNumRoutes/TaxiGetNodeSlot stop working once it closes.
    p.known = (self:_RouteTime(p.src, dst, slot, dst))
    p.path = self:_BuildPath(slot, dst)   -- ordered nodes (+world pos) for timing/landing
    p.earlyLanding = false                -- reset any prior Request-Stop redirect
    p.earlyComputedIdx = nil              -- _UpdateEarlyTarget recompute latch (per flight)
    p.lastDestText, p.lastTimeText = nil, nil   -- force the new flight's first display SetText
    p.phase = "boarding"
    p.boardStart = GetTime()
    self:_StartTicker()
end

-- Poll at 10 Hz, not every rendered frame: take-off / landing detection and the countdown
-- only need ~0.1s granularity, and a ticker runs the body 10x/s instead of 60-150x/s. We use
-- ns.Scheduler:Every (NOT self:Every) so it survives the submodule being unloaded -- flight
-- recording is always on (see OnInitialize/_OnUnload).
function FlightTimers:_StartTicker()
    local p = self:_p()
    if p.ticker then return end
    local sub = self
    p.ticker = ns.Scheduler:Every(0.1, function() sub:_Tick() end)
end

function FlightTimers:_StopTicker()
    local p = self:_p()
    if p.ticker then p.ticker:Cancel(); p.ticker = nil end
    p.phase = nil
    p.earlyLanding = false
end

-- A measured DIRECT (landing) write for the a -> b direction, spanning the booked
-- intermediates `via` (nil for an atomic leg):
--   always replaces a lower-quality (fly) entry, even < 5s;
--   direct-over-direct only when the time changed by >= 5s.
function FlightTimers:_Store(a, b, seconds, via)
    if self:_FlightStore(self:_Faction(), a, b, seconds, via) then
        self:_p().legsCache = nil   -- recorded data changed -> rebuild atomic legs lazily
    end
end

-- Fill-only write for fly-over (closest-approach) segment times in the a -> b direction,
-- spanning `via`: the lowest quality tier, so it ONLY populates an empty slot.
function FlightTimers:_StoreIfNew(a, b, seconds, via)
    if self:_FlightStoreIfNew(self:_Faction(), a, b, seconds, via) then
        self:_p().legsCache = nil
    end
end

-- ---- Flight database access (the submodule's own DAO over self:DB()) -------------------------
-- A flight node is one `flight_master` row (discovered, with its zone, by the LocalTables service).
-- A `flight_route` references two masters by id (src, dst) and carries no faction of its own.
-- FACTION CONTRACT: `faction` exists in this DAO for exactly one purpose -- guaranteeing that a
-- route's stops are all usable by the player: every name -> id resolution is scoped to
-- { faction, Neutral }, and _FlightRecords returns only routes whose EVERY stop (src, each hop,
-- dst) passes that test. Callers derive it ONCE per operation (self:_Faction()) and thread it
-- through, so it's never re-read per lookup. The rest of the submodule works in node NAMES; this
-- DAO translates names -> master ids at the boundary. Recording only LOOKS masters up (discovery
-- creates them); a node that hasn't been discovered yet is simply not recorded. Small tables.

-- The flight_master node id (its PK) for a node name usable by a `faction` player -- one of that
-- faction or a Neutral point -- or nil if undiscovered (or the faction can't be attributed).
function FlightTimers:_MasterId(name, faction)
    local db = self:DB(); if not db then return nil end
    if faction ~= "Alliance" and faction ~= "Horde" and faction ~= "Neutral" then return nil end
    -- Normalise here too (idempotent) so a raw taxi name from any caller still keys correctly.
    local rows = db:Select("node_id"):From("flight_master")
        :Where("name", "=", Flight:NodeName(tostring(name))):AndWhere("faction", "in", { faction, "Neutral" }):Limit(1):Run()
    return rows[1] and rows[1].node_id or nil
end

-- The flight_route row { id, t, quality } for the directed master pair, or nil.
function FlightTimers:_FlightRow(srcId, dstId)
    local db = self:DB(); if not db or not srcId or not dstId then return nil end
    local rows = db:Select("id", "t", "quality"):From("flight_route")
        :Where("src", "=", srcId):AndWhere("dst", "=", dstId):Limit(1):Run()
    return rows[1]
end

-- The entry { t, q } for the a -> b direction (node names), or nil. Read-only (creates no master);
-- both endpoints must resolve within { faction, Neutral }.
function FlightTimers:_FlightGet(faction, a, b)
    local srcId, dstId = self:_MasterId(a, faction), self:_MasterId(b, faction)
    local row = self:_FlightRow(srcId, dstId)
    if not row then return nil end
    return { t = row.t, q = row.quality }
end

-- Replace a route's hops with `via` (node names -> intermediate master ids; nil clears them).
function FlightTimers:_FlightSetHops(routeId, via, faction)
    local db = self:DB(); if not db then return end
    db:Delete("flight_hop", { route_id = routeId })   -- FK map: index lookup, no scan
    if via then
        for i, n in ipairs(via) do
            local mid = self:_MasterId(n, faction)
            if mid then db:Insert("flight_hop", { route_id = routeId, ordinal = i, master = mid }) end
        end
    end
end

-- A measured DIRECT (landing) write: always replaces a lower-quality (fly) entry, even < 5s;
-- direct-over-direct only when the time changed by >= 5s. Returns true if anything changed.
function FlightTimers:_FlightStore(faction, a, b, seconds, via)
    local db = self:DB(); if not db then return false end
    local srcId, dstId = self:_MasterId(a, faction), self:_MasterId(b, faction)
    if not srcId or not dstId then return false end
    local row = self:_FlightRow(srcId, dstId)
    if not row then
        local r = db:Insert("flight_route", { src = srcId, dst = dstId, t = seconds, quality = Quality.DIRECT })
        self:_FlightSetHops(r.id, via, faction)
        return true
    end
    if row.quality < Quality.DIRECT then
        db:Update("flight_route", { t = seconds, quality = Quality.DIRECT }, { id = row.id })
        self:_FlightSetHops(row.id, via, faction)
        return true
    elseif math.abs(seconds - row.t) >= 5 then
        db:Update("flight_route", { t = seconds }, { id = row.id })
        self:_FlightSetHops(row.id, via, faction)
        return true
    end
    return false
end

-- Fill-only FLY write: insert only if the direction has no entry. Returns true if it inserted.
function FlightTimers:_FlightStoreIfNew(faction, a, b, seconds, via)
    local db = self:DB(); if not db then return false end
    local srcId, dstId = self:_MasterId(a, faction), self:_MasterId(b, faction)
    if not srcId or not dstId then return false end
    if self:_FlightRow(srcId, dstId) then return false end
    local r = db:Insert("flight_route", { src = srcId, dst = dstId, t = seconds, quality = Quality.FLY })
    self:_FlightSetHops(r.id, via, faction)
    return true
end

-- Every recorded segment USABLE by a `faction` player, as a FlightGraph record: an ordered
-- node-name sequence (src, hops..., dst) with its total time + quality. Routes carry no faction
-- of their own, so the guarantee lives here: a record is returned ONLY when EVERY stop -- src,
-- each hop AND dst -- resolves to a master of `faction` or a Neutral one; a record with any
-- off-faction (or no-longer-known) stop is dropped whole, since the player couldn't fly that
-- path. One pass over flight_master builds the id -> { name, usable } map, so per-stop checks
-- and hop name resolution cost no further master queries.
function FlightTimers:_FlightRecords(faction)
    local db = self:DB(); if not db then return {} end
    local master = {}
    for _, m in ipairs(db:Select("node_id", "name", "faction"):From("flight_master"):Run()) do
        master[m.node_id] = { name = m.name, usable = (m.faction == faction or m.faction == "Neutral") }
    end
    -- The stop's node name, or nil when a `faction` player can't use it (off-faction/unknown).
    local function stop(id)
        local m = master[id]
        if m and m.usable then return m.name end
    end
    local out = {}
    for _, row in ipairs(db:Select("id", "src", "dst", "t", "quality"):From("flight_route"):Run()) do
        local seq, ok = { stop(row.src) }, nil
        ok = seq[1] ~= nil
        if ok then
            local hops = db:Select("master"):From("flight_hop")
                :Where("route_id", "=", row.id):OrderBy("ordinal", "asc"):Run()
            for _, h in ipairs(hops) do
                local n = stop(h.master)
                if not n then ok = false; break end
                seq[#seq + 1] = n
            end
        end
        if ok then
            seq[#seq + 1] = stop(row.dst)
            ok = seq[#seq] ~= nil
        end
        if ok then out[#out + 1] = { seq = seq, t = row.t, q = row.quality } end
    end
    return out
end

-- Best known time for a current flight src -> dst as (seconds, isEstimate). Resolved in
-- priority order (the two directions can differ, so same-direction wins within each tier):
--   1. DIRECT same direction   -- a real landing on this exact trip            (exact)
--   2. DIRECT other direction  -- a real landing on the return trip            (~)
--   3. FLY  same direction     -- a same-direction fly-over closest approach   (~)
--   4. FLY  other direction    -- a reverse fly-over guess                     (~)
--   5. an assembled estimate from the atomic legs ALONG THE BOOKED ROUTE        (~)
-- Every result is tied to real measurements of THIS route: tiers 1-4 measure the exact
-- src->dst pair; tier 5 sums the atomic legs of the actual taxi path the game would fly
-- src -> dst, each leg either measured or DERIVED by subtraction from a span that genuinely
-- covered it. A route with any unknown leg shows "-:--" -- we never compose a time from a
-- different routing (e.g. estimating a direct hop by detouring through some other node).
-- Only a same-direction DIRECT is exact; the rest are estimates, prefixed with "~".
function FlightTimers:_RouteTime(src, dst, slot, name)
    local faction = self:_Faction()
    local fwd, rev = self:_FlightGet(faction, src, dst), self:_FlightGet(faction, dst, src)
    if fwd and fwd.q == Quality.DIRECT then return fwd.t, false end           -- 1
    if rev and rev.q == Quality.DIRECT then return rev.t, true  end           -- 2
    if fwd then return fwd.t, true end                                        -- 3 (fwd is FLY here)
    if rev then return rev.t, true end                                        -- 4 (rev is FLY here)
    local est = self:_EstimateRoute(slot, name)                               -- 5 (booked-path sum)
    if est then return est, true end
    return nil, false
end

-- Ordered nodes the taxi flies through (source ... destination), each tagged with
-- its WORLD position (continent + yards). Built at take-off while the taxi data
-- is still live; used both to detect where a stopped flight ended and to time the
-- closest approach to each node mid-flight.
function FlightTimers:_BuildPath(destSlot, destName)
    local p = self:_p()
    -- Position + name come from the captured flight-map pins (keyed by the same slotIndex
    -- the taxi route uses), so every node here is genuinely on the booked route. (An earlier
    -- attempt to backfill positions from C_TaxiMap.GetAllTaxiNodes was reverted: its slotIndex
    -- does NOT line up with TaxiGetNodeSlot, so it mis-keyed nodes onto off-route names/pos.)
    local function nodeAt(slot, name)
        local mp = slot and p.nodePos and p.nodePos[slot]
        local world
        if mp and p.flightMapID and C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D then
            local c, w = C_Map.GetWorldPosFromMapPos(p.flightMapID, CreateVector2D(mp.x, mp.y))
            if c and w then world = { c = c, x = w.x, y = w.y } end
        end
        return { name = name, world = world }
    end

    local path = {}
    local hops = (GetNumRoutes and GetNumRoutes(destSlot)) or 0
    if hops >= 1 and TaxiGetNodeSlot then
        for h = 1, hops do
            local s = TaxiGetNodeSlot(destSlot, h, true)
            path[h] = nodeAt(s, s and p.nodeNames and p.nodeNames[s])
        end
        path[hops + 1] = nodeAt(destSlot, destName)
    else
        path[1] = nodeAt(nil, p.src)
        path[2] = nodeAt(destSlot, destName)
    end
    path[1].name = p.src or path[1].name   -- node 1 is authoritatively the source
    return path
end

-- Player position in WORLD coordinates: x, y, continentID (or nil if unavailable).
function FlightTimers:_PlayerWorld()
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition
        and C_Map.GetWorldPosFromMapPos) then return nil end
    local m = C_Map.GetBestMapForUnit("player")
    local pos = m and C_Map.GetPlayerMapPosition(m, "player")
    if not pos then return nil end
    local c, w = C_Map.GetWorldPosFromMapPos(m, pos)
    if not (c and w) then return nil end
    return w.x, w.y, c
end

-- Which path node are we standing at? Nearest within ARRIVE_YARDS. Returns its
-- name (the target on a full flight, an earlier node on a stopped one), nil if we
-- are near none (ported off the path), or the target if position is unmeasurable.
-- The ORIGIN (node 1) is never a candidate: you cannot land back where you took off,
-- so it must never be picked as a landing point (start at node 2).
function FlightTimers:_LandedNode()
    local p = self:_p()
    if not (p.path and #p.path > 1) then return p.dst end
    local px, py, pc = self:_PlayerWorld()
    if not px then return p.dst end
    -- Same-continent path nodes (skip node 1, the origin) become candidate vectors; the
    -- pure Vector2D solver finds the nearest within ARRIVE_YARDS. A parallel `names` list
    -- maps the winning index back (nameless nodes are skipped so a nil name can't be
    -- returned and misread as "ported off the path").
    local vectors, names, comparable = {}, {}, false
    for i = 2, #p.path do
        local node = p.path[i]
        if node.world and node.world.c == pc then
            comparable = true
            if node.name then
                vectors[#vectors + 1] = ns.Vector2D:New(node.world.x, node.world.y)
                names[#names + 1] = node.name
            end
        end
    end
    if not comparable then return p.dst end   -- couldn't measure -> assume target
    local _, _, idx = ns.Vector2D:New(px, py):Nearest(vectors, ARRIVE_YARDS)
    return idx and names[idx]                   -- nil => near no node => ported
end

-- Poll once per refresh while flying: track the closest approach to the NEXT path
-- node; once we have clearly moved away from it, stamp that closest-approach time
-- and record the segment from the previous node as a direct flight. Only handles
-- INTERMEDIATE nodes (2 .. last-1) -- you don't fly past the destination, you land
-- on it, so its final leg is timed from the dismount in _RecordFinalLeg instead.
function FlightTimers:_PollCrossing()
    local p = self:_p()
    if not (p.path and p.crossIdx and p.crossIdx <= #p.path - 1) then return end
    local node = p.path[p.crossIdx]
    if not (node and node.world) then          -- can't time this one; skip past it
        p.crossIdx = p.crossIdx + 1
        p.crossMinDist = huge
        return
    end
    local px, py, pc = self:_PlayerWorld()
    if not px or pc ~= node.world.c then return end
    local dx, dy = px - node.world.x, py - node.world.y
    local dist = sqrt(dx * dx + dy * dy)   -- LINEAR yards (squared margin fires too early)
    if dist < (p.crossMinDist or huge) then
        p.crossMinDist = dist
        p.crossMinTime = GetTime()
    elseif p.crossMinTime and dist > p.crossMinDist + CROSS_MARGIN then
        -- We've clearly moved past this node's closest approach. Record it as a
        -- fly-over ONLY if we actually came within FLYOVER_RANGE; otherwise skip it
        -- (the next recorded node's segment then spans from the last node we DID
        -- fly over, e.g. A -> C when B was never within range).
        if p.crossMinDist <= FLYOVER_RANGE then
            self:_RecordCross(p.crossIdx, p.crossMinTime)
        end
        p.crossIdx = p.crossIdx + 1
        p.crossMinDist = huge
        p.crossMinTime = nil
    end
end

-- Index of a node in the booked path by name (nil if absent).
function FlightTimers:_PathIndexOf(name)
    local p = self:_p()
    if not p.path then return nil end
    for i = 1, #p.path do if p.path[i].name == name then return i end end
end

-- Ordered names of the booked nodes strictly BETWEEN path indices i and j (the stops a
-- span skipped over). nil when there are none, or if any name is missing (so a partial
-- span isn't recorded with a hole that would mis-key the subtraction).
function FlightTimers:_PathNamesBetween(i, j)
    local p = self:_p()
    if not (p.path and i and j and j > i + 1) then return nil end
    local via = {}
    for k = i + 1, j - 1 do
        local n = p.path[k] and p.path[k].name
        if not n then return nil end
        via[#via + 1] = n
    end
    return (#via > 0) and via or nil
end

-- Stamp node `idx`'s crossing time and store the segment from the previous
-- stamped node as a direct flight.
function FlightTimers:_RecordCross(idx, when)
    local p = self:_p()
    p.crossTimes = p.crossTimes or {}
    p.crossTimes[idx] = when
    -- Segment from the last node we ACTUALLY flew over (skipped nodes are bypassed),
    -- so when B was never within range this records A -> C as a span over { B }.
    local prevIdx = p.lastCrossIdx or 1
    local prevT = p.crossTimes[prevIdx]
    local a = p.path[prevIdx] and p.path[prevIdx].name
    local b = p.path[idx] and p.path[idx].name
    if prevT and a and b and a ~= b then
        local seg = when - prevT
        if seg > 1 then self:_StoreIfNew(a, b, seg, self:_PathNamesBetween(prevIdx, idx)) end
    end
    p.lastCrossIdx = idx
end

-- The final leg: last node we actually passed (the before-last) -> where we
-- landed. Timed from that node's closest approach to the DISMOUNT (`when`), since
-- you land on the destination rather than flying past it.
function FlightTimers:_RecordFinalLeg(landed, when)
    local p = self:_p()
    if not p.crossTimes then return end
    -- From the last node we ACTUALLY flew over (or the source if none) -- so a
    -- skipped second-to-last node doesn't break the final leg.
    local fromIdx = p.lastCrossIdx or 1
    local fromT = p.crossTimes[fromIdx]
    local fromName = p.path and p.path[fromIdx] and p.path[fromIdx].name
    if fromName and fromT and fromName ~= landed then
        local seg = when - fromT
        local via = self:_PathNamesBetween(fromIdx, self:_PathIndexOf(landed) or #p.path)
        if seg > 1 then self:_StoreIfNew(fromName, landed, seg, via) end
    end
end

function FlightTimers:_Tick()
    local p = self:_p()
    if p.phase == "boarding" then
        if UnitOnTaxi("player") then
            p.phase = "flying"
            p.startTime = GetTime()
            -- crossing state: we're at the source node (1) on lift-off
            p.crossTimes = { [1] = p.startTime }
            p.crossIdx = 2
            p.lastCrossIdx = 1   -- last node actually flown over (source); skips advance past
            p.crossMinDist = huge
            p.crossMinTime = nil
            -- p.known was resolved at take-off (recorded time or multi-hop estimate)
            self:_RefreshDisplay()
        elseif GetTime() - (p.boardStart or 0) > 8 then
            self:_StopTicker()  -- never took off (cancelled)
        end

    elseif p.phase == "flying" then
        if not UnitOnTaxi("player") then
            local now = GetTime()
            local dur = now - (p.startTime or now)
            -- Record against the node we ACTUALLY landed at: the target on a full
            -- flight, or an earlier path node if the flight was stopped. nil means
            -- we were ported off the path, so nothing is recorded.
            local landed = self:_LandedNode()
            if dur > 1 and landed then
                -- full source -> landed, spanning every booked stop in between
                local via = self:_PathNamesBetween(1, self:_PathIndexOf(landed) or #p.path)
                self:_Store(p.src, landed, dur, via)
                self:_RecordFinalLeg(landed, now)                 -- last per-node segment
            end
            if p.frame then p.frame:Hide() end
            self:_StopTicker()
        else
            self:_PollCrossing()       -- closest-approach segment timing
            self:_UpdateEarlyTarget()  -- re-track an early-stop target as we go
            self:_RefreshDisplay()
        end
    end
end

-- ======================= display ===========================================
function FlightTimers:_BuildFrame()
    local p = self:_p()
    if p.frame then return p.frame end
    local f = W.Panel:New(UIParent, "panel", "borderStrong")
    f:SetSize(230, 42)
    f:SetFrameStrata("HIGH")

    local dest = W.Text:New(f, "", "accent", "GameFontNormal")
    dest:SetPoint("TOPLEFT", 12, -8)
    dest:SetPoint("RIGHT", f, "RIGHT", -70, 0)
    dest:SetJustifyH("LEFT")
    dest:SetWordWrap(false)

    local time = W.Text:New(f, "", "text", "GameFontNormal")
    time:SetPoint("TOPRIGHT", -12, -8)

    local bar = W.ProgressBar:New(f, { height = 7, fillKey = "accent", bgKey = "bg0" })
    bar:SetPoint("BOTTOMLEFT", 12, 9)
    bar:SetPoint("BOTTOMRIGHT", -12, 9)

    f.dest, f.time, f.bar = dest, time, bar
    f:Hide()
    p.frame = f

    -- Edit-Mode descriptor; registered/unregistered by _SyncEditMode so the timer is only present
    -- in Edit Mode while the submodule + "in flight" setting are on. onEnter drives the widget children.
    p.editOpts = {
        key = "flightTimer",
        label = "Flight Timer",
        default = { point = "CENTER", x = 0, y = 210 },
        onEnter = function()
            f.dest:SetText("Flight Timer")
            f.time:SetText("1:23")
            f.bar:SetValue(0.5)
        end,
    }
    return f
end

-- Register the flight timer with Edit Mode ONLY while the submodule AND its display setting are on;
-- unregister (and hide) otherwise. Called on load/unload and when the setting changes, so a
-- disabled timer never shows up in Edit Mode or snaps against other frames. Registration is
-- idempotent (Registrable mixin), so repeat calls are cheap.
function FlightTimers:_SyncEditMode()
    local p = self:_p()
    if self:IsEnabled() and self:GetSetting("showInFlight") then
        self:_BuildFrame():RegisterEditMode(p.editOpts)
    elseif p.frame then
        p.frame:UnregisterEditMode()
        p.frame:Hide()
    end
end

-- Display is gated by the submodule + "in flight" checkbox; recording is not.
function FlightTimers:_RefreshDisplay()
    local p = self:_p()
    if not (self:IsEnabled() and self:GetSetting("showInFlight")) then
        if p.frame then p.frame:Hide() end
        return
    end
    local f = self:_BuildFrame()
    -- The ticker runs at 10 Hz but the texts change at most once per second (M:SS) / per flight
    -- (destination), so SetText only when the string actually changed -- a redundant SetText forces a
    -- font-string relayout every tick for nothing. The bar value genuinely moves each tick, so it's
    -- always set. The caches are reset per flight in _OnTakeTaxi.
    local destText = p.dst or "Flight"
    if p.lastDestText ~= destText then p.lastDestText = destText; f.dest:SetText(destText) end
    local elapsed = GetTime() - (p.startTime or GetTime())
    local timeText, fill
    if p.known and p.known > 0 then
        timeText, fill = fmt(p.known - elapsed), math.min(1, elapsed / p.known)
    else
        timeText, fill = "-:--", 0
    end
    if p.lastTimeText ~= timeText then p.lastTimeText = timeText; f.time:SetText(timeText) end
    f.bar:SetValue(fill)
    f:Show()
end

-- The player clicked Request Stop (TaxiRequestEarlyLanding). Commit the early-stop
-- target to the node we're currently flying toward -- crossIdx already IS the next
-- reachable node (it only advances once we pass one), so Request Stop lands there. If the
-- flight can't stop and carries on, _UpdateEarlyTarget bumps the target forward when
-- crossIdx advances. (We do NOT pre-advance for "too close to land": a stop requested
-- while approaching a node lands AT it, so guessing the node after dropped the real one.)
function FlightTimers:_OnEarlyLanding()
    local p = self:_p()
    if not p.path then return end
    p.earlyLanding = true

    -- crossIdx is only set once _Tick flips boarding -> flying; a stop requested in that
    -- gap (right after lift-off) arrives before it exists, so fall back to node 2 -- the
    -- first node after the source. _UpdateEarlyTarget refines it once tracking starts.
    p.earlyIdx = p.crossIdx or 2

    self:_UpdateEarlyTarget()
    self:_RefreshDisplay()
end

-- Re-track the committed early-stop target: if we've flown PAST it (the flight
-- couldn't land there and carried on), advance to the next node. Overwrites the
-- destination + countdown to the current target.
function FlightTimers:_UpdateEarlyTarget()
    local p = self:_p()
    if not (p.earlyLanding and p.path and p.earlyIdx) then return end

    -- past our target? (crossIdx is the next-node-ahead tracker) -> move it forward
    local cross = p.crossIdx
    if cross and cross > p.earlyIdx then p.earlyIdx = cross end

    -- The target node only moves when crossIdx passes it; the names array + SumLegs estimate are a
    -- function of earlyIdx alone, so recompute only when it actually changed -- not on every 10 Hz tick.
    if p.earlyIdx == p.earlyComputedIdx then return end
    p.earlyComputedIdx = p.earlyIdx

    local landNode = p.path[p.earlyIdx]
    if not landNode then return end
    p.dst = landNode.name   -- always update the shown destination, even before tracking starts

    -- Total time from take-off (node 1) to the new finish, via the SAME estimator the rest of
    -- the route timer uses (Flight:SumLegs over the booked path). No per-leg bookkeeping here --
    -- just the whole start -> finish total; the countdown subtracts the elapsed duration from it
    -- in _RefreshDisplay. If any leg on the way is still unmeasured, SumLegs returns nil and the
    -- timer blanks to -:-- -- we do NOT fall back to the full-route time, which is for the further
    -- ORIGINAL destination and would show a misleading countdown for this closer early target.
    local names = {}
    for i = 1, p.earlyIdx do
        local n = p.path[i] and p.path[i].name
        if not n then names = nil; break end
        names[i] = n
    end
    p.known = names and Flight:SumLegs(self:_AtomicLegs(), names) or nil
end

-- ---- map hover tooltip ----------------------------------------------------
function FlightTimers:_HookFlightPins()
    local sub = self
    if not (FlightMapFrame and FlightMapFrame.pinPools) then return end
    local pool = FlightMapFrame.pinPools.FlightMap_FlightPointPinTemplate
    if not pool or not pool.EnumerateActive then return end
    -- pins render just after the map opens
    ns.Scheduler:After(0, function()
        local p = sub:_p()
        p.nodeNames = {}   -- slotIndex -> flight-map node name
        p.nodePos = {}     -- slotIndex -> { x, y } on the flight map
        -- Which pins we've hooked, in a WEAK-KEYED set in our OWN private state -- not a field
        -- stamped onto the pooled Blizzard pin (we don't own it; weak keys let a retired pin GC).
        p.hoverHooked = p.hoverHooked or setmetatable({}, { __mode = "k" })
        p.flightMapID = FlightMapFrame.GetMapID and FlightMapFrame:GetMapID()
        for pin in pool:EnumerateActive() do
            if not p.hoverHooked[pin] then
                p.hoverHooked[pin] = true
                pin:HookScript("OnEnter", function(self2) sub:_OnPinEnter(self2) end)
            end
            local d = pin.taxiNodeData
            if d and d.name and d.slotIndex then
                local nodeName = Flight:NodeName(d.name)
                p.nodeNames[d.slotIndex] = nodeName
                local pos = d.position
                if pos then
                    local x, y
                    if pos.GetXY then x, y = pos:GetXY() else x, y = pos.x, pos.y end
                    if x and y then p.nodePos[d.slotIndex] = { x = x, y = y } end
                end
                if d.state == Enum.FlightPathState.Current then p.src = nodeName end
            end
        end
    end)
end

-- Solve every recorded segment under the CURRENT faction into atomic-leg times (cached
-- until the next recording clears it). Each DB entry is one record for ns.FlightGraph.Solve
-- -- an ordered node sequence (src, via..., dst) with its total time + quality; the solver
-- seeds atomic legs directly and derives the rest by subtraction.
function FlightTimers:_AtomicLegs()
    local p = self:_p()
    if p.legsCache then return p.legsCache end
    p.legsCache = ns.FlightGraph.Solve(self:_FlightRecords(self:_Faction()))
    return p.legsCache
end

-- Estimate a route by summing the atomic legs ALONG THE PATH THE TAXI ACTUALLY FLIES
-- (GetNumRoutes / TaxiGetNodeSlot). Every leg must be known (measured or DERIVED by the
-- solver) or the whole estimate is nil -- we never stitch in a leg from a different
-- routing. This also covers a DIRECT hop (one leg): its time can still be recovered by
-- subtraction (A->B from a span A->C minus B->C), even though A->B was never flown. Uses
-- flight-map names to stay key-consistent.
function FlightTimers:_EstimateRoute(destSlot, destName)
    if not (destSlot and GetNumRoutes and TaxiGetNodeSlot) then return nil end
    local p = self:_p()
    local hops = GetNumRoutes(destSlot)
    if not hops or hops < 1 then return nil end

    -- ordered node names along the route: [1] = source ... [hops+1] = destination
    local nodes = { [1] = p.src, [hops + 1] = destName }
    for h = 2, hops do
        local s = TaxiGetNodeSlot(destSlot, h, true)
        nodes[h] = s and p.nodeNames and p.nodeNames[s]
    end
    for i = 1, hops + 1 do if not nodes[i] then return nil end end

    return Flight:SumLegs(self:_AtomicLegs(), nodes)
end

function FlightTimers:_OnPinEnter(pin)
    if not (self:IsEnabled() and self:GetSetting("showHover")) then return end
    local d = pin.taxiNodeData
    if not d or d.state ~= Enum.FlightPathState.Reachable then return end
    local src = self:_p().src
    if not src then return end

    -- Split the pin name to the flight-master name (e.g. "Rut'theran Village, Teldrassil" ->
    -- "Rut'theran Village") so it keys against the stored masters -- otherwise the reverse/estimate
    -- lookup never matches and the tooltip shows "-:--".
    local dst = Flight:NodeName(d.name)
    local dur, estimated = self:_RouteTime(src, dst, d.slotIndex, dst)

    local r, g, b = Theme.Unpack("accent")
    local prefix = estimated and "Flight: ~" or "Flight: "  -- "~" = summed estimate
    GameTooltip:AddLine(prefix .. fmt(dur), r, g, b)  -- fmt(nil) -> "-:--"
    GameTooltip:Show()
end


-- ---- registration ---------------------------------------------------------
ns.SubmoduleManager:Register(FlightTimers:New("FlightTimers", {
    parent = { module = "Misc" },
    deps = { "EventBus", "Scheduler" },   -- EventBus: the recorder's ns.EventBus:On (TAXIMAP_OPENED); Scheduler: the 10 Hz flight ticker. Both wired in OnInitialize.
    title = "Flight timers",
    settingsWatch = { showInFlight = "_SyncEditMode" },
    onLoad   = function(_, sub) sub:_OnLoad() end,
    onUnload = function(_, sub) sub:_OnUnload() end,
    settings = {
        { type = "toggle", key = "showInFlight", label = "Show timer while in flight", default = true },
        { type = "toggle", key = "showHover", label = "Show flight time on map hover", default = true },
        { type = "note", text = "Routes are recorded the first time you fly them; '-:--' means no recorded time yet." },
    },
}))
