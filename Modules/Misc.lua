local addonName, ns = ...
local Class = ns.Class
local Theme = ns.Theme
local W = ns.UI.Widgets

-- Upvalue the globals this module hits while polling a flight: a local lookup beats a
-- global-table lookup on every tick. (Same-name locals -> no call-site churn.)
local GetTime, C_Map, CreateVector2D = GetTime, C_Map, CreateVector2D
local sqrt, huge = math.sqrt, math.huge

-- Modules/Misc.lua
-- Miscellaneous helpers:
--   * Flight Timers — time each flight path and show a countdown both while in
--     flight and when hovering a flight point on the map. Routes are ALWAYS
--     recorded (even with the module off) so the database keeps building.
--   * Sell Junk — sell grey items at a vendor, automatically or via a button.

local Misc = Class.new("Misc", ns.Module)

local fmt = ns.Format.MMSS   -- pure "M:SS" countdown formatter (Lib/Format.lua)

-- DIRECTIONAL route key: a -> b is stored separately from b -> a, because the two
-- directions don't always take the same time (path asymmetry). New recordings use this;
-- the resolver (_RouteTime) prefers same-direction data and falls back to the reverse.
-- Flight times are recorded PER FACTION (the two factions have different flight masters and
-- routes), so every query is scoped by this tag. "?" when the faction isn't known yet.
function Misc:_Faction()
    return UnitFactionGroup("player") or "?"
end

-- The flight MASTER name only, stripped of the trailing ", <zone>" the taxi API tacks on
-- ("Stormwind, Elwynn" -> "Stormwind"). Both discovery and recording run names through this so a
-- node keys the same whichever path saw it.
function Misc:_NodeName(raw)
    if type(raw) ~= "string" then return raw end
    return (raw:match("^%s*(.-)%s*,") or raw:match("^%s*(.-)%s*$") or raw)
end

-- ---- tunables (flight-path detection distances, yards) --------------------
local ARRIVE_YARDS = 40    -- within this of a path node = we landed there
local CROSS_MARGIN = 75   -- moved this many (linear) yards past the closest approach = passed it
local FLYOVER_RANGE = 75  -- closest approach must be within this to count as flying OVER a node;
                          -- farther than this and the node is skipped (never recorded)

-- A flight_route row carries { t = seconds, quality = q } per DIRECTION + faction; the booked
-- intermediate nodes it spanned are ordered flight_hop rows (empty for an ATOMIC leg between
-- adjacent stops), which let the solver split a span back into atomic legs by subtraction. Only
-- measurements are stored: DIRECT (a real landing) > FLY (a mid-flight closest-approach guess).
-- Estimates are computed fresh and never persisted.
--
-- The read-side algebra over a solved leg table -- the per-leg quality ranking (LegTime) and the
-- never-fabricate route sum (SumLegs) -- lives in the pure, unit-tested ns.FlightResolver
-- (Lib/FlightResolver.lua), which also owns the quality enum (DIRECT = 2 > FLY = 1; persisted as
-- a row's `quality`).
local Flight  = ns.FlightResolver
local Quality = Flight.Quality

-- The flight tables this module contributes to the ONE shared database (account-wide / GLOBAL
-- scope). A recorded route is one `flight_route` row referencing two `flight_master` nodes by id
-- (src, dst) with its measured time + quality tier -- it carries NO faction of its own; the faction
-- is the masters' (a route is valid for you when both masters are your faction or Neutral). The
-- booked intermediate nodes it spanned live RELATIONALLY as ordered `flight_hop` rows (each an FK to
-- a flight_master, cascade-deleted with the route) -- never a blob. `flight_master` itself is a
-- central CoreTable. The module owns the small query methods (_Flight*/_Master*) over self:DB().
local FLIGHT_TABLES = {
    flight_route = {
        scope = "global",
        columns = {
            { name = "id",  type = "integer", primaryKey = true, autoIncrement = true },
            { name = "src", type = "integer", nullable = false, references = { table = "flight_master" } },
            { name = "dst", type = "integer", nullable = false, references = { table = "flight_master" } },
            { name = "t",       type = "number",  nullable = false },
            { name = "quality", type = "integer", nullable = false },
        },
        unique  = { { "src", "dst" } },
        indices = { { columns = { "src" } } },
    },
    flight_hop = {
        scope = "global",
        columns = {
            { name = "route_id", type = "integer", references = { table = "flight_route", onDelete = "cascade" } },
            { name = "ordinal",  type = "integer" },
            { name = "master",   type = "integer", nullable = false, references = { table = "flight_master" } },
        },
        primaryKey = { "route_id", "ordinal" },
    },
}

-- Sell every sellable grey (Poor, quality 0) item in the bags. Returns the number
-- of stacks sold and a list of { link, count } descriptors of what was sold.
function Misc:_SellJunk()
    local sold = {}
    if not (C_Container and C_Container.GetContainerNumSlots and C_Container.UseContainerItem) then return 0, sold end
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.quality == 0 and not info.hasNoValue then
                C_Container.UseContainerItem(bag, slot)
                sold[#sold + 1] = { link = info.hyperlink, count = info.stackCount or 1 }
            end
        end
    end
    return #sold, sold
end

-- ---- lifecycle ------------------------------------------------------------
function Misc:OnInitialize()
    local p = self:_p()
    p.phase = nil       -- nil / "boarding" / "flying"
    p.src = nil

    -- Flight recording is ALWAYS on (builds the data even while disabled). Routes live in the
    -- shared SQL database as flight_route + flight_hop (contributed by this module; see _Flight* DAO).
    ns.EventBus:On("TAXIMAP_OPENED", function() self:_OnTaxiMap() end)
    -- TakeTaxiNode is a permanent secure hook, so it installs once per SESSION (the
    -- private latch on this singleton). It resolves the live registered Misc instance
    -- each call rather than capturing `self`, so it never points at a stale instance.
    if not p.taxiHooked and type(TakeTaxiNode) == "function" then
        hooksecurefunc("TakeTaxiNode", function(slot)
            local m = ns.ModuleManager:GetModule("Misc")
            if m then m:_OnTakeTaxi(slot) end
        end)
        p.taxiHooked = true
    end
end

function Misc:OnEnable()
    -- Enable-scoped subscriptions + hook are auto-released on disable.
    self:On("MERCHANT_SHOW",   function() self:_OnMerchantShow() end)
    self:On("MERCHANT_CLOSED", function() self:_OnMerchantClosed() end)
    -- register the timer with Edit Mode (only while the "in flight" setting is on)
    self:_SyncEditMode()

    -- Redirect on Request-Stop / early landing: hook the API itself (always
    -- present; fires however it's triggered -- button, keybind, macro) rather than
    -- the fragile button method. Via the removable hook helper so disabling
    -- uninstalls it automatically.
    if type(TaxiRequestEarlyLanding) == "function" then
        local module = self
        self:Hook("TaxiRequestEarlyLanding", function()
            if UnitOnTaxi("player") and module:GetSetting("showInFlight") then
                module:_OnEarlyLanding()
            end
        end)
    end
end

function Misc:OnDisable()
    local p = self:_p()
    -- Subscriptions + the early-landing hook are released by the framework.
    -- Do NOT stop the in-flight ticker: it is the recording engine (it detects the landing
    -- and stores the time), and flight recording must run even while the module is disabled.
    -- _Tick's recording is ungated; the DISPLAY is gated in _RefreshDisplay, so the frame
    -- stays hidden on its own. (Hiding the ticker here used to drop mid-flight recordings.)
    self:_SyncEditMode()  -- module disabled -> unregister the timer from Edit Mode + hide it
    if p.sellBtn then p.sellBtn:Hide() end
end

-- ======================= FLIGHT TIMERS =====================================
function Misc:_OnTaxiMap()
    self:_CaptureSource()
    self:_HookFlightPins()
    self:_DiscoverNodes()   -- seed every flight master on this continent (name + zone)
end

function Misc:_CaptureSource()
    local p = self:_p()
    if not (NumTaxiNodes and TaxiNodeGetType and TaxiNodeName) then return end
    for i = 1, NumTaxiNodes() do
        if TaxiNodeGetType(i) == "CURRENT" then
            p.src = self:_NodeName(TaxiNodeName(i))
            return
        end
    end
end

-- Record (always) when a flight is taken.
function Misc:_OnTakeTaxi(slot)
    local p = self:_p()
    if TaxiNodeGetType and TaxiNodeGetType(slot) ~= "REACHABLE" then return end
    -- Use the FLIGHT-MAP node name (matched by slotIndex) so the recorded key
    -- matches the one the map-hover tooltip builds; TaxiNodeName(slot) can return
    -- a differently-formatted name and would never match on lookup.
    local dst = (p.nodeNames and p.nodeNames[slot]) or (TaxiNodeName and self:_NodeName(TaxiNodeName(slot)))
    if not (p.src and dst) then return end

    p.dst = dst
    p.dstMapID = p.flightMapID
    -- resolve the expected time NOW, while the flight map (taxi data) is still
    -- open -- GetNumRoutes/TaxiGetNodeSlot stop working once it closes.
    p.known = (self:_RouteTime(p.src, dst, slot, dst))
    p.path = self:_BuildPath(slot, dst)   -- ordered nodes (+world pos) for timing/landing
    p.earlyLanding = false                -- reset any prior Request-Stop redirect
    p.phase = "boarding"
    p.boardStart = GetTime()
    self:_StartTicker()
end

-- Poll at 10 Hz, not every rendered frame: take-off / landing detection and the countdown
-- only need ~0.1s granularity, and a C_Timer ticker runs the body 10x/s instead of
-- 60-150x/s. It's a raw C_Timer (NOT self:Every) so it survives the module being disabled
-- -- flight recording is always on (see OnDisable).
function Misc:_StartTicker()
    local p = self:_p()
    if p.ticker then return end
    local module = self
    p.ticker = C_Timer.NewTicker(0.1, function() module:_Tick() end)
end

function Misc:_StopTicker()
    local p = self:_p()
    if p.ticker then p.ticker:Cancel(); p.ticker = nil end
    p.phase = nil
    p.earlyLanding = false
end

-- A measured DIRECT (landing) write for the a -> b direction, spanning the booked
-- intermediates `via` (nil for an atomic leg):
--   always replaces a lower-quality (fly) entry, even < 5s;
--   direct-over-direct only when the time changed by >= 5s.
function Misc:_Store(a, b, seconds, via)
    if self:_FlightStore(self:_Faction(), a, b, seconds, via) then
        self:_p().legsCache = nil   -- recorded data changed -> rebuild atomic legs lazily
    end
end

-- Fill-only write for fly-over (closest-approach) segment times in the a -> b direction,
-- spanning `via`: the lowest quality tier, so it ONLY populates an empty slot.
function Misc:_StoreIfNew(a, b, seconds, via)
    if self:_FlightStoreIfNew(self:_Faction(), a, b, seconds, via) then
        self:_p().legsCache = nil
    end
end

-- ---- Flight database access (the module's own DAO over self:DB()) ---------------------------
-- A flight node is one `flight_master` row (faction + name; its zone is filled later by taxi-map
-- discovery). A `flight_route` references two masters by id (src, dst) and carries no faction --
-- the faction is the masters' (a route is valid for you when both are your faction or Neutral). The
-- rest of the module works in node NAMES; this DAO translates names <-> master ids at the boundary,
-- scoping every lookup to the current faction. Small tables, read only while flying -> query-on-read.

-- The flight_master id for a node name under the current faction. With `create`, inserts the master
-- if missing; otherwise returns nil when unknown. nil if the faction can't be attributed.
function Misc:_MasterId(name, create)
    local db = self:DB(); if not db then return nil end
    local faction = self:_Faction()
    if faction ~= "Alliance" and faction ~= "Horde" and faction ~= "Neutral" then return nil end
    name = tostring(name)
    local rows = db:Select("id"):From("flight_master")
        :Where("faction", "=", faction):AndWhere("name", "=", name):Limit(1):Run()
    if rows[1] then return rows[1].id end
    if not create then return nil end
    return db:Insert("flight_master", { faction = faction, name = name }).id
end

function Misc:_MasterName(id)
    local db = self:DB(); if not db then return nil end
    local rows = db:Select("name"):From("flight_master"):Where("id", "=", id):Limit(1):Run()
    return rows[1] and rows[1].name or nil
end

-- The flight_route row { id, t, quality } for the directed master pair, or nil.
function Misc:_FlightRow(srcId, dstId)
    local db = self:DB(); if not db or not srcId or not dstId then return nil end
    local rows = db:Select("id", "t", "quality"):From("flight_route")
        :Where("src", "=", srcId):AndWhere("dst", "=", dstId):Limit(1):Run()
    return rows[1]
end

-- Ordered intermediate node NAMES for a route (hop master ids resolved back to names), or nil.
function Misc:_FlightHops(routeId)
    local db = self:DB(); if not db then return nil end
    local rows = db:Select("master"):From("flight_hop"):Where("route_id", "=", routeId):OrderBy("ordinal", "asc"):Run()
    if #rows == 0 then return nil end
    local via = {}
    for i, r in ipairs(rows) do via[i] = self:_MasterName(r.master) end
    return via
end

-- The entry { t, q } for the a -> b direction (node names), or nil. Read-only (creates no master).
function Misc:_FlightGet(faction, a, b)
    local srcId, dstId = self:_MasterId(a, false), self:_MasterId(b, false)
    local row = self:_FlightRow(srcId, dstId)
    if not row then return nil end
    return { t = row.t, q = row.quality }
end

-- Replace a route's hops with `via` (node names -> intermediate master ids; nil clears them).
function Misc:_FlightSetHops(routeId, via)
    local db = self:DB(); if not db then return end
    db:Delete("flight_hop", function(h) return h.route_id == routeId end)
    if via then
        for i, n in ipairs(via) do
            local mid = self:_MasterId(n, true)
            if mid then db:Insert("flight_hop", { route_id = routeId, ordinal = i, master = mid }) end
        end
    end
end

-- A measured DIRECT (landing) write: always replaces a lower-quality (fly) entry, even < 5s;
-- direct-over-direct only when the time changed by >= 5s. Returns true if anything changed.
function Misc:_FlightStore(faction, a, b, seconds, via)
    local db = self:DB(); if not db then return false end
    local srcId, dstId = self:_MasterId(a, true), self:_MasterId(b, true)
    if not srcId or not dstId then return false end
    local row = self:_FlightRow(srcId, dstId)
    if not row then
        local r = db:Insert("flight_route", { src = srcId, dst = dstId, t = seconds, quality = Quality.DIRECT })
        self:_FlightSetHops(r.id, via)
        return true
    end
    if row.quality < Quality.DIRECT then
        db:Update("flight_route", { t = seconds, quality = Quality.DIRECT }, function(x) return x.id == row.id end)
        self:_FlightSetHops(row.id, via)
        return true
    elseif math.abs(seconds - row.t) >= 5 then
        db:Update("flight_route", { t = seconds }, function(x) return x.id == row.id end)
        self:_FlightSetHops(row.id, via)
        return true
    end
    return false
end

-- Fill-only FLY write: insert only if the direction has no entry. Returns true if it inserted.
function Misc:_FlightStoreIfNew(faction, a, b, seconds, via)
    local db = self:DB(); if not db then return false end
    local srcId, dstId = self:_MasterId(a, true), self:_MasterId(b, true)
    if not srcId or not dstId then return false end
    if self:_FlightRow(srcId, dstId) then return false end
    local r = db:Insert("flight_route", { src = srcId, dst = dstId, t = seconds, quality = Quality.FLY })
    self:_FlightSetHops(r.id, via)
    return true
end

-- Every recorded segment whose masters belong to `faction`, as a FlightGraph record: an ordered
-- node-name sequence (src, hops..., dst) with its total time + quality. The faction filter is a
-- join to the src master (routes carry no faction of their own).
function Misc:_FlightRecords(faction)
    local db = self:DB(); if not db then return {} end
    local routes = db:Select("flight_route.id", "flight_route.src", "flight_route.dst", "flight_route.t", "flight_route.quality")
        :From("flight_route")
        :InnerJoin("flight_master", { on = { "flight_route.src", "flight_master.id" } })
        :Where("flight_master.faction", "=", faction):Run()
    local out = {}
    for _, row in ipairs(routes) do
        local seq = { self:_MasterName(row.src) }
        local via = self:_FlightHops(row.id)
        if via then for _, n in ipairs(via) do seq[#seq + 1] = n end end
        seq[#seq + 1] = self:_MasterName(row.dst)
        out[#out + 1] = { seq = seq, t = row.t, q = row.quality }
    end
    return out
end

-- ---- taxi-map discovery (seed every flight master on the continent) --------------------------
-- On opening a flight master, C_TaxiMap.GetAllTaxiNodes returns EVERY node on that continent's taxi
-- map (canonical nodeID + name + map position + state). We record them all -- not just ones flown --
-- splitting the name to the flight-master name and resolving each node's ZONE from its position via
-- the world map (seeding the local zone table so flight_master.zone resolves). Faction can't be read
-- per node from the API, so we attribute to the player's faction (you only see your + neutral nodes).

-- The zone NAME at a map position, seeding the local zone table from the world map. nil if unknown.
function Misc:_ZoneAt(mapID, position)
    if not (C_Map and C_Map.GetMapInfoAtPosition and position) then return nil end
    local x, y
    if position.GetXY then x, y = position:GetXY() else x, y = position.x, position.y end
    if not (x and y) then return nil end
    local info = C_Map.GetMapInfoAtPosition(mapID, x, y)
    if not (info and info.name and info.mapID) then return nil end
    local db = self:DB()
    if db and #db:Select("id"):From("zone"):Where("id", "=", info.mapID):Limit(1):Run() == 0 then
        pcall(function() db:Insert("zone", { id = info.mapID, name = info.name }) end)
    end
    return info.name
end

-- Insert or enrich the flight_master for (faction, name): set its canonical nodeID and zone.
function Misc:_DiscoverMaster(faction, name, nodeID, zone)
    local db = self:DB(); if not db then return end
    local row = db:Select("id", "node_id", "zone"):From("flight_master")
        :Where("faction", "=", faction):AndWhere("name", "=", name):Limit(1):Run()[1]
    if not row then
        db:Insert("flight_master", { faction = faction, name = name, node_id = nodeID, zone = zone })
        return
    end
    local changes = {}
    if nodeID and row.node_id ~= nodeID then changes.node_id = nodeID end
    if zone and row.zone ~= zone then changes.zone = zone end
    if next(changes) then db:Update("flight_master", changes, function(x) return x.id == row.id end) end
end

-- Discover every node on the open taxi map (all flight masters on the continent).
function Misc:_DiscoverNodes()
    local db = self:DB(); if not db then return end
    local faction = self:_Faction()
    if faction ~= "Alliance" and faction ~= "Horde" and faction ~= "Neutral" then return end
    if not (C_TaxiMap and C_TaxiMap.GetAllTaxiNodes and GetTaxiMapID) then return end
    local mapID = GetTaxiMapID()
    if not mapID then return end
    local nodes = C_TaxiMap.GetAllTaxiNodes(mapID)
    if not nodes then return end
    for _, n in ipairs(nodes) do
        if n.name and n.nodeID then
            local name = self:_NodeName(n.name)
            local zone = self:_ZoneAt(mapID, n.position)
            pcall(function() self:_DiscoverMaster(faction, name, n.nodeID, zone) end)
        end
    end
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
function Misc:_RouteTime(src, dst, slot, name)
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
function Misc:_BuildPath(destSlot, destName)
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
function Misc:_PlayerWorld()
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
function Misc:_LandedNode()
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
function Misc:_PollCrossing()
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
        p.crossMinDist = math.huge
        p.crossMinTime = nil
    end
end

-- Index of a node in the booked path by name (nil if absent).
function Misc:_PathIndexOf(name)
    local p = self:_p()
    if not p.path then return nil end
    for i = 1, #p.path do if p.path[i].name == name then return i end end
end

-- Ordered names of the booked nodes strictly BETWEEN path indices i and j (the stops a
-- span skipped over). nil when there are none, or if any name is missing (so a partial
-- span isn't recorded with a hole that would mis-key the subtraction).
function Misc:_PathNamesBetween(i, j)
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
function Misc:_RecordCross(idx, when)
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
function Misc:_RecordFinalLeg(landed, when)
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

function Misc:_Tick()
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

function Misc:_BuildFrame()
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
    -- in Edit Mode while the module + "in flight" setting are on. onEnter drives the widget children.
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

-- Register the flight timer with Edit Mode ONLY while the module AND its display setting are on;
-- unregister (and hide) otherwise. Called on enable/disable and when the setting changes, so a
-- disabled timer never shows up in Edit Mode or snaps against other frames. Registration is
-- idempotent (Registrable mixin), so repeat calls are cheap.
function Misc:_SyncEditMode()
    local p = self:_p()
    if self:IsEnabled() and self:GetSetting("showInFlight") then
        self:_BuildFrame():RegisterEditMode(p.editOpts)
    elseif p.frame then
        p.frame:UnregisterEditMode()
        p.frame:Hide()
    end
end

-- Display is gated by the module + "in flight" checkbox; recording is not.
function Misc:_RefreshDisplay()
    local p = self:_p()
    if not (self:IsEnabled() and self:GetSetting("showInFlight")) then
        if p.frame then p.frame:Hide() end
        return
    end
    self:_BuildFrame()
    p.frame.dest:SetText(p.dst or "Flight")
    local elapsed = GetTime() - (p.startTime or GetTime())
    if p.known and p.known > 0 then
        p.frame.time:SetText(fmt(p.known - elapsed))
        p.frame.bar:SetValue(math.min(1, elapsed / p.known))
    else
        p.frame.time:SetText("-:--")
        p.frame.bar:SetValue(0)
    end
    p.frame:Show()
end

-- The player clicked Request Stop (TaxiRequestEarlyLanding). Commit the early-stop
-- target to the node we're currently flying toward -- crossIdx already IS the next
-- reachable node (it only advances once we pass one), so Request Stop lands there. If the
-- flight can't stop and carries on, _UpdateEarlyTarget bumps the target forward when
-- crossIdx advances. (We do NOT pre-advance for "too close to land": a stop requested
-- while approaching a node lands AT it, so guessing the node after dropped the real one.)
function Misc:_OnEarlyLanding()
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
function Misc:_UpdateEarlyTarget()
    local p = self:_p()
    if not (p.earlyLanding and p.path and p.earlyIdx) then return end

    -- past our target? (crossIdx is the next-node-ahead tracker) -> move it forward
    local cross = p.crossIdx
    if cross and cross > p.earlyIdx then p.earlyIdx = cross end

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
function Misc:_HookFlightPins()
    local module = self
    if not (FlightMapFrame and FlightMapFrame.pinPools) then return end
    local pool = FlightMapFrame.pinPools.FlightMap_FlightPointPinTemplate
    if not pool or not pool.EnumerateActive then return end
    -- pins render just after the map opens
    C_Timer.After(0, function()
        local p = module:_p()
        p.nodeNames = {}   -- slotIndex -> flight-map node name
        p.nodePos = {}     -- slotIndex -> { x, y } on the flight map
        p.flightMapID = FlightMapFrame.GetMapID and FlightMapFrame:GetMapID()
        for pin in pool:EnumerateActive() do
            if not pin.__hagHoverHooked then
                pin.__hagHoverHooked = true
                pin:HookScript("OnEnter", function(self2) module:_OnPinEnter(self2) end)
            end
            local d = pin.taxiNodeData
            if d and d.name and d.slotIndex then
                local nodeName = module:_NodeName(d.name)
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
-- until the next recording clears it). Each DB entry is one record for ns.FlightGraph:Solve
-- -- an ordered node sequence (src, via..., dst) with its total time + quality; the solver
-- seeds atomic legs directly and derives the rest by subtraction.
function Misc:_AtomicLegs()
    local p = self:_p()
    if p.legsCache then return p.legsCache end
    p.legsCache = ns.FlightGraph:Solve(self:_FlightRecords(self:_Faction()))
    return p.legsCache
end

-- Estimate a route by summing the atomic legs ALONG THE PATH THE TAXI ACTUALLY FLIES
-- (GetNumRoutes / TaxiGetNodeSlot). Every leg must be known (measured or DERIVED by the
-- solver) or the whole estimate is nil -- we never stitch in a leg from a different
-- routing. This also covers a DIRECT hop (one leg): its time can still be recovered by
-- subtraction (A->B from a span A->C minus B->C), even though A->B was never flown. Uses
-- flight-map names to stay key-consistent.
function Misc:_EstimateRoute(destSlot, destName)
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

function Misc:_OnPinEnter(pin)
    if not (self:IsEnabled() and self:GetSetting("showHover")) then return end
    local d = pin.taxiNodeData
    if not d or d.state ~= Enum.FlightPathState.Reachable then return end
    local src = self:_p().src
    if not src then return end

    local dur, estimated = self:_RouteTime(src, d.name, d.slotIndex, d.name)

    local r, g, b = Theme.Unpack("accent")
    local prefix = estimated and "Flight: ~" or "Flight: "  -- "~" = summed estimate
    GameTooltip:AddLine(prefix .. fmt(dur), r, g, b)  -- fmt(nil) -> "-:--"
    GameTooltip:Show()
end

-- ======================= SELL JUNK =========================================
function Misc:_OnMerchantShow()
    local mode = self:GetSetting("sellJunk")
    if mode == "auto" then
        self:_Sell()
    elseif mode == "button" then
        self:_BuildSellButton()
        if self:_p().sellBtn then self:_p().sellBtn:Show() end
    end
end

function Misc:_OnMerchantClosed()
    if self:_p().sellBtn then self:_p().sellBtn:Hide() end
end

function Misc:_Sell()
    local count, sold = self:_SellJunk()
    if count == 0 then return end
    local parts = {}
    for _, it in ipairs(sold) do
        local link = it.link or "item"
        parts[#parts + 1] = it.count > 1 and (link .. " x" .. it.count) or link
    end
    -- Echo the items sold to chat (when "Echo to Chat" is on); also recorded to the log.
    self:LogEchoInfo(("sold %d junk item%s: %s")
        :format(count, count == 1 and "" or "s", table.concat(parts, ", ")))
end

function Misc:_BuildSellButton()
    local p = self:_p()
    if p.sellBtn or not MerchantFrame then return end
    -- just below the merchant window (its bottom-right), clear of the buyback slot and money area
    local b = W.Button:New(MerchantFrame, "Sell Junk", { width = 86, height = 22 })
    b:SetPoint("TOPRIGHT", MerchantFrame, "BOTTOMRIGHT", -4, -2)
    b:SetFrameStrata("HIGH")
    b:SetOnClick(function() self:_Sell() end)
    p.sellBtn = b
end

-- Hide the vendor Sell Junk button when that mode is switched off (settingsWatch).
function Misc:_OnSellJunkChanged()
    if self:GetSetting("sellJunk") ~= "button" and self:_p().sellBtn then
        self:_p().sellBtn:Hide()
    end
end

-- ---- registration ---------------------------------------------------------
ns.ModuleManager:Register(Misc:New("Misc", {
    title = "Miscellaneous",
    description = "Flight-path timers and selling junk.",
    defaultEnabled = false,
    color = ns.Theme.hex.grey,  -- distinct tag (accent=Core, green=UnitFrames, purple=Class, gold=Questing, red=CVars)
    deps = { "EventBus" },  -- recording/timer; Edit Mode is mediated by the Panel widget (Registrable mixin), route solver (ns.FlightGraph Lib) + proximity (ns.Vector2D class) are always available
    tables = FLIGHT_TABLES,   -- flight_route + flight_hop contributed to the shared database (GLOBAL)
    settingsWatch = { sellJunk = "_OnSellJunkChanged", showInFlight = "_SyncEditMode" },
    settings = {
        { type = "header", text = "Flight timers" },
        { type = "toggle", key = "showInFlight", label = "Show timer while in flight", default = true },
        { type = "toggle", key = "showHover", label = "Show flight time on map hover", default = true },
        { type = "note", text = "Routes are recorded the first time you fly them; '-:--' means no recorded time yet." },

        { type = "header", text = "Sell Junk" },
        { type = "select", key = "sellJunk", label = "Sell grey items", default = "off",
          options = {
              { value = "off",    text = "Off" },
              { value = "button", text = "Button" },
              { value = "auto",   text = "Auto" },
          } },
        { type = "note", text = "Auto sells grey items when you open a vendor. Button adds a Sell Junk button to the vendor window." },
    },
}))
