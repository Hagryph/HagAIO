-- Test/flight_sim_spec.lua — END-TO-END flight simulations against the REAL Misc module:
-- the taxi window opens, a route is booked, the 10 Hz ticker polls a simulated player
-- position across the constellation, and the landing writes flight_route/flight_hop rows
-- through the real DAO into the real database. Covers:
--   * simple 2- and 3-node constellations (atomic leg + through-flyover recording),
--   * partial fly-over (an off-path node is skipped; spans bridge it as hops),
--   * Request-Stop early landings (including being carried past the requested node),
--   * an ultra-complex 10-node constellation where the SAME target is reached from
--     different origins through DIFFERENT intermediate nodes, and unflown routes are
--     estimated from the atomic legs the flights actually measured.
-- Geometry: world coords ARE yards (identity map transform), continent 1. Speed is
-- 100 yd/s, so a 1000-yd leg flies in ~10s of simulated clock.

local S = dofile("Test/support.lua")

local DB_FILES = { "Types", "Schema", "RowStore", "IndexManager", "Constraints", "TriggerManager",
                   "Database", "Aggregate", "WhereClause", "ColumnResolver", "QueryPlan",
                   "QueryBuilder", "QueryExecutor", "CoreTables", "DatabaseManager" }

local SPEED = 100      -- yards per simulated second
local DIRECT, FLY = 2, 1

-- ---- the rig: real EventBus + DB engine + flight libs + the real Misc module ----------
local function rig()
    S.stubFrames()
    local ns = S.newNs()
    local clock = S.newClock()
    local sim = {
        clock = clock,
        px = 0, py = 0,        -- the simulated player's world position (yards)
        onTaxi = false,
        nodes = {},            -- name -> { slot, x, y }
        slots = {},            -- slot -> name (slot doubles as the master's node_id)
        current = nil,         -- where the taxi window is open ("CURRENT" node)
        route = {},            -- destSlot -> ordered slot list of the booked stops ([1] = src)
    }

    -- WoW API stubs. These MUST exist before Misc.lua loads -- it upvalues several at file scope.
    _G.GetTime = clock.GetTime
    _G.C_Timer = clock.C_Timer
    _G.UnitFactionGroup = function() return "Horde" end
    _G.UnitOnTaxi = function() return sim.onTaxi end
    _G.CreateVector2D = function(x, y) return { x = x, y = y } end
    _G.C_Map = {   -- identity transform: map coords are world yards, everything on continent 1
        GetBestMapForUnit     = function() return 1 end,
        GetPlayerMapPosition  = function() return { x = sim.px, y = sim.py } end,
        GetWorldPosFromMapPos = function(_, pos) return 1, { x = pos.x, y = pos.y } end,
    }
    _G.NumTaxiNodes = function() return #sim.slots end
    _G.TaxiNodeGetType = function(slot)
        local name = sim.slots[slot]
        if not name then return "NONE" end
        return (name == sim.current) and "CURRENT" or "REACHABLE"
    end
    _G.TaxiNodeName = function(slot) return sim.slots[slot] end
    _G.GetNumRoutes = function(destSlot) local r = sim.route[destSlot]; return r and #r or 0 end
    _G.TaxiGetNodeSlot = function(destSlot, h) local r = sim.route[destSlot]; return r and r[h] end

    S.load(ns, "Services/EventBus.lua")
    ns._captured["EventBus"]:OnInitialize()
    S.load(ns, "Services/Scheduler.lua")           -- the 10 Hz flight ticker goes through ns.Scheduler:Every
    for _, f in ipairs(DB_FILES) do S.load(ns, "Core/DB/" .. f .. ".lua") end
    ns.SavedVars = { IsLoaded = function() return true end, DataSlot = function() return {} end }
    local mgr = ns._captured["DatabaseManager"]; mgr:OnInitialize()
    S.load(ns, "Lib/Format.lua")
    S.load(ns, "Lib/Vector2D.lua")
    S.load(ns, "Lib/FlightGraph.lua")
    S.load(ns, "Lib/FlightResolver.lua")
    S.load(ns, "Lib/FlightCrossing.lua")   -- pure crossing arithmetic FlightTimers upvalues
    S.load(ns, "Core/Module.lua")
    S.load(ns, "Core/Submodule.lua")
    ns.ModuleManager = {     -- capture stub (the thin parent module contributes the flight tables)
        Register  = function(_, m) ns._captured[m:GetName()] = m; return m end,
        GetModule = function(_, n) return ns._captured[n] end,
    }
    ns.SubmoduleManager = {  -- capture stub (the taxi hook resolves the live FlightTimers sub via Get)
        Register = function(_, s) ns._captured[s:GetName()] = s; return s end,
        Get      = function(_, n) return ns._captured[n] end,
    }
    S.load(ns, "Modules/Misc.lua")                 -- thin parent: registers the Misc module (flight tables)
    S.load(ns, "Modules/Misc/FlightTimers.lua")    -- the FlightTimers submodule (its own file)
    local misc = ns._captured["Misc"]
    misc:_Init()                                   -- parent: logger + flight-table contribution
    local flight = ns._captured["FlightTimers"]
    flight:_Init()                                 -- submodule: OnInitialize installs the always-on recorder
    local db = mgr:Build()
    db:Insert("zone", { name = "Z" })

    -- ---- sim verbs ---------------------------------------------------------
    -- Place a flight master in the constellation (also discovers it in flight_master).
    function sim.addNode(name, x, y)
        local slot = #sim.slots + 1
        sim.nodes[name] = { slot = slot, x = x, y = y }
        sim.slots[slot] = name
        db:Insert("flight_master", { node_id = slot, faction = "Horde", name = name, zone = "Z" })
    end

    -- Open the taxi window at `name`: the module captures the source, and the pin data
    -- _HookFlightPins would have scraped in-game (names/positions/map) is filled in.
    function sim.openTaxi(name)
        sim.current = name
        flight:_OnTaxiMap()
        local p = flight:_p()
        p.flightMapID = 1
        p.nodeNames, p.nodePos = {}, {}
        for slot, n in pairs(sim.slots) do
            p.nodeNames[slot] = n
            p.nodePos[slot] = { x = sim.nodes[n].x, y = sim.nodes[n].y }
        end
    end

    -- Book a flight along `stops` (ordered, [1] = the source we're standing at) to `dest`
    -- and lift off; the first tick flips boarding -> flying.
    function sim.takeOff(stops, dest)
        local destSlot = sim.nodes[dest].slot
        local r = {}
        for i, n in ipairs(stops) do r[i] = sim.nodes[n].slot end
        sim.route[destSlot] = r
        sim.px, sim.py = sim.nodes[stops[1]].x, sim.nodes[stops[1]].y
        flight:_OnTakeTaxi(destSlot)
        sim.onTaxi = true
        clock.advance(0.1)
    end

    -- Fly a straight line to (x, y) at SPEED, ticking the 10 Hz recorder along the way.
    function sim.flyTo(x, y)
        local x0, y0 = sim.px, sim.py
        local dx, dy = x - x0, y - y0
        local steps = math.max(1, math.floor(math.sqrt(dx * dx + dy * dy) / (SPEED * 0.1) + 0.5))
        for s = 1, steps do
            sim.px = x0 + dx * s / steps
            sim.py = y0 + dy * s / steps
            clock.advance(0.1)
        end
    end

    -- Fly node to node along the named stops.
    function sim.flyVia(names)
        for _, n in ipairs(names) do sim.flyTo(sim.nodes[n].x, sim.nodes[n].y) end
    end

    -- Dismount where we are; the landing tick records the flight and stops the ticker.
    function sim.land()
        sim.onTaxi = false
        clock.advance(0.1)
    end

    -- ---- assertions over what got recorded ---------------------------------
    function sim.routeRow(a, b)
        return db:Select("id", "t", "quality"):From("flight_route")
            :Where("src", "=", sim.nodes[a].slot):AndWhere("dst", "=", sim.nodes[b].slot):Limit(1):Run()[1]
    end
    function sim.hopsOf(routeId)
        local rows = db:Select("master"):From("flight_hop")
            :Where("route_id", "=", routeId):OrderBy("ordinal", "asc"):Run()
        local out = {}
        for i, r in ipairs(rows) do out[i] = sim.slots[r.master] end
        return table.concat(out, ",")
    end
    function sim.touches(name)   -- any recorded route with `name` as an endpoint?
        local id = sim.nodes[name].slot
        for _, r in ipairs(db:Select("src", "dst"):From("flight_route"):Run()) do
            if r.src == id or r.dst == id then return true end
        end
        return false
    end

    return sim, flight, db, ns
end

local function near(got, want, tol)
    return got ~= nil and math.abs(got - want) <= (tol or 1)
end

describe("flight simulation: simple constellations", function()
    it("a 2-node hop records one DIRECT atomic leg with no hops", function()
        local sim, flight = rig()
        sim.addNode("A", 0, 0); sim.addNode("B", 1000, 0)
        sim.openTaxi("A")
        sim.takeOff({ "A" }, "B")
        sim.flyVia({ "B" })
        sim.land()
        local r = sim.routeRow("A", "B")
        assert.are.equal(DIRECT, r.quality)
        assert.is_true(near(r.t, 10))              -- 1000 yd at 100 yd/s
        assert.are.equal("", sim.hopsOf(r.id))     -- atomic: no intermediate stops
        assert.is_nil(sim.routeRow("B", "A"))      -- directional: the reverse was never flown
    end)

    it("a 3-node line records the span as DIRECT and each through-flyover leg as FLY", function()
        local sim, flight, _, ns = rig()
        sim.addNode("A", 0, 0); sim.addNode("B", 1000, 0); sim.addNode("C", 2000, 0)
        sim.openTaxi("A")
        sim.takeOff({ "A", "B" }, "C")
        sim.flyVia({ "B", "C" })
        sim.land()
        local span = sim.routeRow("A", "C")
        assert.are.equal(DIRECT, span.quality)
        assert.is_true(near(span.t, 20, 1.5))
        assert.are.equal("B", sim.hopsOf(span.id))            -- the booked stop it spanned
        local ab, bc = sim.routeRow("A", "B"), sim.routeRow("B", "C")
        assert.are.equal(FLY, ab.quality); assert.is_true(near(ab.t, 10))   -- closest-approach legs
        assert.are.equal(FLY, bc.quality); assert.is_true(near(bc.t, 10))
        -- the solver reassembles the whole route from the atomic legs the flight measured
        assert.is_true(near(ns.FlightResolver:SumLegs(flight:_AtomicLegs(), { "A", "B", "C" }), 20, 1.5))
    end)
end)

describe("flight simulation: partial fly-over", function()
    it("a node the flight never comes near is skipped; spans bridge it as a hop", function()
        local sim, flight = rig()
        sim.addNode("A", 0, 0); sim.addNode("B", 1000, 0)
        sim.addNode("C", 2000, 0); sim.addNode("D", 3000, 0)
        sim.openTaxi("A")
        sim.takeOff({ "A", "B", "C" }, "D")
        sim.flyTo(1000, 0)        -- straight over B (within fly-over range)
        sim.flyTo(2000, -400)     -- swing wide of C: closest approach ~372 yd > FLYOVER_RANGE
        sim.flyTo(3000, 0)        -- on to D
        sim.land()
        assert.are.equal(FLY, sim.routeRow("A", "B").quality)
        local bd = sim.routeRow("B", "D")                -- the final leg bridges the skipped C
        assert.are.equal(FLY, bd.quality)
        assert.are.equal("C", sim.hopsOf(bd.id))         -- recorded as a span OVER C, not to it
        local span = sim.routeRow("A", "D")
        assert.are.equal(DIRECT, span.quality)
        assert.are.equal("B,C", sim.hopsOf(span.id))
        assert.is_nil(sim.routeRow("B", "C"))            -- no leg ever ENDS at the skipped node
        assert.is_nil(sim.routeRow("C", "D"))
    end)
end)

describe("flight simulation: Request-Stop early landing", function()
    it("an early stop lands at the next node and records the partial route", function()
        local sim, flight = rig()
        sim.addNode("A", 0, 0); sim.addNode("B", 1000, 0); sim.addNode("C", 2000, 0)
        sim.addNode("D", 3000, 0); sim.addNode("E", 4000, 0)
        sim.openTaxi("A")
        sim.takeOff({ "A", "B", "C", "D" }, "E")
        sim.flyVia({ "B" })
        sim.flyTo(1300, 0)                       -- well past B, heading for C
        flight:_OnEarlyLanding()                  -- the player clicks Request Stop
        assert.are.equal("C", flight:_p().dst)      -- the display retargets the next node
        sim.flyVia({ "C" })
        sim.land()                                -- the taxi drops us at C
        local r = sim.routeRow("A", "C")
        assert.are.equal(DIRECT, r.quality)
        assert.is_true(near(r.t, 20, 1.5))
        assert.are.equal("B", sim.hopsOf(r.id))   -- only the stops actually flown
        assert.is_nil(sim.routeRow("A", "E"))     -- the original destination was never reached
    end)

    it("a stop the flight carries past retargets the following node", function()
        local sim, flight = rig()
        sim.addNode("A", 0, 0); sim.addNode("B", 1000, 0); sim.addNode("C", 2000, 0)
        sim.addNode("D", 3000, 0); sim.addNode("E", 4000, 0)
        sim.openTaxi("A")
        sim.takeOff({ "A", "B", "C", "D" }, "E")
        sim.flyVia({ "B" })
        sim.flyTo(1300, 0)
        flight:_OnEarlyLanding()
        assert.are.equal("C", flight:_p().dst)      -- requested: stop at C...
        sim.flyVia({ "C" })                       -- ...but the flight flies on through C
        sim.flyTo(2300, 0)
        assert.are.equal("D", flight:_p().dst)      -- target bumped to the next node
        sim.flyVia({ "D" })
        sim.land()                                -- and we land there
        local r = sim.routeRow("A", "D")
        assert.are.equal(DIRECT, r.quality)
        assert.are.equal("B,C", sim.hopsOf(r.id))
        assert.is_nil(sim.routeRow("A", "E"))
    end)
end)

describe("flight simulation: a 10-node constellation", function()
    -- A--B--C--D--E along y=0; F,G a northern spur over C; H,I a southern shelf; J far NE.
    local function constellation(sim)
        sim.addNode("A", 0, 0);       sim.addNode("B", 1000, 0)
        sim.addNode("C", 2000, 0);    sim.addNode("D", 3000, 0)
        sim.addNode("E", 4000, 0)
        sim.addNode("F", 2000, 1000); sim.addNode("G", 2000, 2000)
        sim.addNode("H", 1000, -1000); sim.addNode("I", 3000, -1000)
        sim.addNode("J", 4000, 2000)
    end

    it("the same target gets DIFFERENT intermediates depending on the origin", function()
        local sim, flight, db, ns = rig()
        constellation(sim)

        -- Flight 1: A -> G routed over B, C, F.
        sim.openTaxi("A")
        sim.takeOff({ "A", "B", "C", "F" }, "G")
        sim.flyVia({ "B", "C", "F", "G" })
        sim.land()
        -- Flight 2: E -> G routed over D, F (same target, different way in).
        sim.openTaxi("E")
        sim.takeOff({ "E", "D", "F" }, "G")
        sim.flyVia({ "D", "F", "G" })
        sim.land()
        -- Flight 3: H -> J across the southern shelf (brings all ten nodes into play).
        sim.openTaxi("H")
        sim.takeOff({ "H", "I", "E" }, "J")
        sim.flyVia({ "I", "E", "J" })
        sim.land()

        local ag, eg, hj = sim.routeRow("A", "G"), sim.routeRow("E", "G"), sim.routeRow("H", "J")
        assert.are.equal("B,C,F", sim.hopsOf(ag.id))   -- origin A's way to G
        assert.are.equal("D,F",   sim.hopsOf(eg.id))   -- origin E's way to G differs
        assert.are.equal("I,E",   sim.hopsOf(hj.id))
        assert.are.equal(DIRECT, ag.quality)
        assert.are.equal(DIRECT, eg.quality)
        assert.is_true(near(ag.t, 40, 2))              -- 4 x 1000 yd legs
        assert.is_true(near(eg.t, 34.1, 2))            -- 1000 + 1414 + 1000 yd
        assert.is_true(near(hj.t, 54.1, 2.5))          -- 2000 + 1414 + 2000 yd

        -- The atomic legs each flight measured compose route times -- including for pairs
        -- that were NEVER booked: D -> G is derivable from flight 2's D->F + F->G legs.
        local F = ns.FlightResolver
        local legs = flight:_AtomicLegs()
        assert.is_true(near(F:SumLegs(legs, { "A", "B", "C", "F", "G" }), 40, 2))
        assert.is_true(near(F:SumLegs(legs, { "C", "F", "G" }), 20, 1.5))
        assert.is_true(near(F:SumLegs(legs, { "D", "F", "G" }), 24.1, 1.5))   -- unflown as a booking
        assert.is_nil(F:SumLegs(legs, { "A", "H" }))   -- never measured, never fabricated
    end)
end)
