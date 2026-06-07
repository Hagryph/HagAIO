local addonName, ns = ...
local Class = ns.Class
local Theme = ns.Theme
local W = ns.UI.Widgets

-- Modules/Misc.lua
-- Miscellaneous helpers:
--   * Flight Timers — time each flight path and show a countdown both while in
--     flight and when hovering a flight point on the map. Routes are ALWAYS
--     recorded (even with the module off) so the database keeps building.
--   * Sell Junk — sell grey items at a vendor, automatically or via a button.

local Misc = Class.new("Misc", ns.Module)

local taxiHooked = false       -- TakeTaxiNode hook installed once per session

local function fmt(s)
    if s == nil then return "-:--" end   -- no recorded time
    if s < 0 then s = 0 end
    s = math.floor(s + 0.5)
    return ("%d:%02d"):format(math.floor(s / 60), s % 60)
end

-- DIRECTIONAL route key: a -> b is stored separately from b -> a, because the two
-- directions don't always take the same time (path asymmetry). New recordings use this;
-- the resolver (_RouteTime) prefers same-direction data and falls back to the reverse.
local function dirKey(a, b)
    local faction = UnitFactionGroup("player") or "?"
    return faction .. "|" .. tostring(a) .. " -> " .. tostring(b)
end

local ARRIVE_YARDS = 40    -- within this of a path node = we landed there
local CROSS_MARGIN = 75   -- moved this many (linear) yards past the closest approach = passed it
local FLYOVER_RANGE = 75  -- closest approach must be within this to count as flying OVER a node;
                          -- farther than this and the node is skipped (never recorded)
local LAND_LEAD = 60      -- too close to a node to land there -> an early stop overshoots it

-- A flight DB entry is { t = seconds, q = quality }, keyed per DIRECTION (see dirKey).
-- Only measurements are stored: DIRECT (a real landing) > FLY (a mid-flight closest-
-- approach guess). Estimates are computed fresh and never persisted. Legacy: a plain
-- number = DIRECT; an old { t, est = true } (a saved estimate) is treated as FLY.
local Q_DIRECT, Q_FLY = 2, 1

local function storedTime(e)
    if type(e) == "number" then return e end
    return e and e.t
end
local function entryQ(e)
    if e == nil then return nil end
    if type(e) ~= "table" then return Q_DIRECT end   -- legacy number
    if e.q then return e.q end
    return e.est and Q_FLY or Q_DIRECT               -- legacy saved estimate -> fly
end

-- Best stored time for a sub-leg a -> b, considering BOTH directions as a PRIORITY (not an
-- exclusion -- a reverse-direction segment is still usable, just less preferred):
--   Direct same (0) < Direct other (1) < Fly same (2) < Fly other (3).
-- Returns (seconds, penalty), or nil if neither direction is known.
local function legCost(flights, a, b)
    local fwd, rev = flights[dirKey(a, b)], flights[dirKey(b, a)]
    local t, pen
    if fwd then pen = 2 * (Q_DIRECT - entryQ(fwd)); t = storedTime(fwd) end   -- same direction
    if rev then
        local rp = 2 * (Q_DIRECT - entryQ(rev)) + 1                            -- other direction (+1)
        if not pen or rp < pen then pen, t = rp, storedTime(rev) end
    end
    return t, pen
end

-- Sell every sellable grey (Poor, quality 0) item in the bags. Returns count.
local function sellJunk()
    if not (C_Container and C_Container.GetContainerNumSlots and C_Container.UseContainerItem) then return 0 end
    local count = 0
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.quality == 0 and not info.hasNoValue then
                C_Container.UseContainerItem(bag, slot)
                count = count + 1
            end
        end
    end
    return count
end

-- ---- lifecycle ------------------------------------------------------------
function Misc:OnInitialize()
    local p = self:_p()
    p.tokens = {}       -- enable-gated subscriptions (sell junk)
    p.phase = nil       -- nil / "boarding" / "flying"
    p.src = nil

    -- Flight recording is ALWAYS on (builds the database even while disabled),
    -- so set it up here rather than in OnEnable.
    self:GetDB().flights = self:GetDB().flights or {}
    ns.EventBus:On("TAXIMAP_OPENED", function() self:_OnTaxiMap() end)
    if not taxiHooked and type(TakeTaxiNode) == "function" then
        local module = self
        hooksecurefunc("TakeTaxiNode", function(slot) module:_OnTakeTaxi(slot) end)
        taxiHooked = true
    end
end

function Misc:OnEnable()
    local p = self:_p()
    local bus = ns.EventBus
    p.tokens["MERCHANT_SHOW"]   = bus:On("MERCHANT_SHOW",   function() self:_OnMerchantShow() end)
    p.tokens["MERCHANT_CLOSED"] = bus:On("MERCHANT_CLOSED", function() self:_OnMerchantClosed() end)
    -- build + register the timer so it can be placed in Blizzard's Edit Mode
    self:_BuildFrame()

    -- Redirect on Request-Stop / early landing: hook the API itself (always
    -- present; fires however it's triggered -- button, keybind, macro) rather than
    -- the fragile button method. Via the removable hook service so OnDisable
    -- uninstalls it.
    if type(TaxiRequestEarlyLanding) == "function" then
        local module = self
        ns.Hooks:Secure("TaxiRequestEarlyLanding", function()
            if UnitOnTaxi("player") and module:GetSetting("showInFlight") then
                module:_OnEarlyLanding()
            end
        end, self)
    end
end

function Misc:OnDisable()
    local p = self:_p()
    local bus = ns.EventBus
    for event, token in pairs(p.tokens) do bus:Off(event, token) end
    wipe(p.tokens)
    ns.Hooks:UnhookAll(self)              -- remove the early-landing redirect
    -- Do NOT stop the in-flight ticker: it is the recording engine (it detects the landing
    -- and stores the time), and flight recording must run even while the module is disabled.
    -- _Tick's recording is ungated; the DISPLAY is gated in _RefreshDisplay, so the frame
    -- stays hidden on its own. (Hiding the ticker here used to drop mid-flight recordings.)
    if p.frame then p.frame:Hide() end
    if p.sellBtn then p.sellBtn:Hide() end
end

-- ======================= FLIGHT TIMERS =====================================
function Misc:_OnTaxiMap()
    self:_CaptureSource()
    self:_HookFlightPins()
end

function Misc:_CaptureSource()
    local p = self:_p()
    if not (NumTaxiNodes and TaxiNodeGetType and TaxiNodeName) then return end
    for i = 1, NumTaxiNodes() do
        if TaxiNodeGetType(i) == "CURRENT" then
            p.src = TaxiNodeName(i)
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
    local dst = (p.nodeNames and p.nodeNames[slot]) or (TaxiNodeName and TaxiNodeName(slot))
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

function Misc:_StartTicker()
    local p = self:_p()
    if not p.ticker then
        local module = self
        p.ticker = CreateFrame("Frame")
        p.acc = 0
        p.ticker:SetScript("OnUpdate", function(_, dt) module:_Tick(dt) end)
    end
    p.ticker:Show()
end

function Misc:_StopTicker()
    local p = self:_p()
    if p.ticker then p.ticker:Hide() end
    p.phase = nil
    p.earlyLanding = false
end

-- A measured DIRECT (landing) write for the a -> b direction:
--   always replaces a lower-quality (fly) entry, even < 5s;
--   direct-over-direct only when the time changed by >= 5s.
function Misc:_Store(a, b, seconds)
    local flights = self:GetDB().flights
    local key = dirKey(a, b)
    local cur = flights[key]
    if cur == nil then
        flights[key] = { t = seconds, q = Q_DIRECT }
        return
    end
    local curQ = entryQ(cur)
    if type(cur) ~= "table" then cur = { t = storedTime(cur), q = curQ }; flights[key] = cur end
    if curQ < Q_DIRECT then
        cur.t, cur.q = seconds, Q_DIRECT                  -- direct beats a fly entry
    elseif math.abs(seconds - cur.t) >= 5 then
        cur.t = seconds                                   -- +/-5s, direct over direct
    end
end

-- Fill-only write for fly-over (closest-approach) segment times in the a -> b direction:
-- the lowest quality tier, so it ONLY populates an empty slot and never overwrites.
function Misc:_StoreIfNew(a, b, seconds)
    local flights = self:GetDB().flights
    local key = dirKey(a, b)
    if flights[key] == nil then flights[key] = { t = seconds, q = Q_FLY } end
end

-- Best known time for a current flight src -> dst as (seconds, isEstimate). Resolved in
-- priority order (the two directions can differ, so same-direction wins within each tier):
--   1. DIRECT same direction   -- a real landing on this exact trip            (exact)
--   2. DIRECT other direction  -- a real landing on the return trip            (~)
--   3. FLY  same direction     -- a same-direction fly-over closest approach   (~)
--   4. FLY  other direction    -- a reverse fly-over guess                     (~)
--   5. an assembled multi-hop estimate from sub-segments along the booked route  (~)
--   6. a composed estimate through ANY learned legs (graph) -- covers a direct
--      hop never flown, e.g. A->B as A->C + C->B                                 (~)
-- Only a same-direction DIRECT is reported as exact; everything else is flagged an
-- estimate, which the UI prefixes with "~".
function Misc:_RouteTime(src, dst, slot, name)
    local f = self:GetDB().flights
    local fwd, rev = f[dirKey(src, dst)], f[dirKey(dst, src)]
    if fwd and entryQ(fwd) == Q_DIRECT then return storedTime(fwd), false end  -- 1
    if rev and entryQ(rev) == Q_DIRECT then return storedTime(rev), true  end  -- 2
    if fwd then return storedTime(fwd), true end                              -- 3 (fwd is FLY here)
    if rev then return storedTime(rev), true end                              -- 4 (rev is FLY here)
    local est = self:_EstimateRoute(slot, name)                               -- 5 (booked-path sum)
    if est then return est, true end
    local graph = self:_EstimateGraph(src, dst)                               -- 6 (compose via any legs)
    if graph then return graph, true end
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
    local bestName, bestD2, comparable = nil, ARRIVE_YARDS * ARRIVE_YARDS, false
    for i = 2, #p.path do                       -- skip node 1 (origin)
        local node = p.path[i]
        if node.world and node.world.c == pc then
            comparable = true
            local dx, dy = px - node.world.x, py - node.world.y
            local d2 = dx * dx + dy * dy
            if d2 <= bestD2 then bestD2, bestName = d2, node.name end
        end
    end
    if not comparable then return p.dst end   -- couldn't measure -> assume target
    return bestName                            -- nil => near no node => ported
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
        p.crossMinDist = math.huge
        return
    end
    local px, py, pc = self:_PlayerWorld()
    if not px or pc ~= node.world.c then return end
    local dx, dy = px - node.world.x, py - node.world.y
    local dist = math.sqrt(dx * dx + dy * dy)   -- LINEAR yards (squared margin fires too early)
    if dist < (p.crossMinDist or math.huge) then
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

-- Stamp node `idx`'s crossing time and store the segment from the previous
-- stamped node as a direct flight.
function Misc:_RecordCross(idx, when)
    local p = self:_p()
    p.crossTimes = p.crossTimes or {}
    p.crossTimes[idx] = when
    -- Segment from the last node we ACTUALLY flew over (skipped nodes are bypassed),
    -- so when B was never within range this records A -> C directly.
    local prevIdx = p.lastCrossIdx or 1
    local prevT = p.crossTimes[prevIdx]
    local a = p.path[prevIdx] and p.path[prevIdx].name
    local b = p.path[idx] and p.path[idx].name
    if prevT and a and b and a ~= b then
        local seg = when - prevT
        if seg > 1 then self:_StoreIfNew(a, b, seg) end  -- fill-only, a -> b direction
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
        if seg > 1 then self:_StoreIfNew(fromName, landed, seg) end  -- fill-only, fromName -> landed
    end
end

function Misc:_Tick(dt)
    local p = self:_p()
    if p.phase == "boarding" then
        if UnitOnTaxi("player") then
            p.phase = "flying"
            p.startTime = GetTime()
            -- crossing state: we're at the source node (1) on lift-off
            p.crossTimes = { [1] = p.startTime }
            p.crossIdx = 2
            p.lastCrossIdx = 1   -- last node actually flown over (source); skips advance past
            p.crossMinDist = math.huge
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
                self:_Store(p.src, landed, dur)  -- full source -> landed
                self:_RecordFinalLeg(landed, now)                 -- last per-node segment
            end
            if p.frame then p.frame:Hide() end
            self:_StopTicker()
        else
            p.acc = (p.acc or 0) + dt
            if p.acc >= 0.1 then
                p.acc = 0
                self:_PollCrossing()       -- closest-approach segment timing
                self:_UpdateEarlyTarget()  -- re-track an early-stop target as we go
                self:_RefreshDisplay()
            end
        end
    end
end

function Misc:_BuildFrame()
    local p = self:_p()
    if p.frame then return end
    local f = W.Panel(UIParent, "panel", "borderStrong")
    f:SetSize(230, 42)
    f:SetFrameStrata("HIGH")

    local dest = W.Text(f, "", "accent", "GameFontNormal")
    dest:SetPoint("TOPLEFT", 12, -8)
    dest:SetPoint("RIGHT", f, "RIGHT", -70, 0)
    dest:SetJustifyH("LEFT")
    dest:SetWordWrap(false)

    local time = W.Text(f, "", "text", "GameFontNormal")
    time:SetPoint("TOPRIGHT", -12, -8)

    local bar = CreateFrame("StatusBar", nil, f)
    bar:SetPoint("BOTTOMLEFT", 12, 9)
    bar:SetPoint("BOTTOMRIGHT", -12, 9)
    bar:SetHeight(7)
    bar:SetStatusBarTexture(Theme.WHITE)
    bar:SetStatusBarColor(Theme.Unpack("accent"))
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(Theme.Unpack("bg0"))

    f.dest, f.time, f.bar = dest, time, bar
    f:Hide()
    p.frame = f

    ns.EditMode:Register(f, {
        key = "flightTimer",
        label = "Flight Timer",
        default = { point = "CENTER", x = 0, y = 210 },
        active = function() return self:IsEnabled() and self:GetSetting("showInFlight") end,
        onEnter = function(frame)
            frame.dest:SetText("Flight Timer")
            frame.time:SetText("1:23")
            frame.bar:SetValue(0.5)
        end,
    })
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

-- The player clicked Request Stop (TaxiRequestEarlyLanding). Commit an early-stop
-- target: the next node ahead, or the one after if we're too close to it to
-- decelerate and land (on top of a node). It then re-tracks every tick.
function Misc:_OnEarlyLanding()
    local p = self:_p()
    if not p.path then return end
    p.earlyLanding = true

    -- crossIdx is only set once _Tick flips boarding -> flying; a stop requested in that
    -- gap (right after lift-off) arrives before it exists, so fall back to node 2 -- the
    -- first node after the source. _UpdateEarlyTarget refines it once tracking starts.
    local idx = p.crossIdx or 2
    local node = p.path[idx]
    if node and node.world and p.path[idx + 1] then
        local px, py, pc = self:_PlayerWorld()
        if px and pc == node.world.c then
            local dx, dy = px - node.world.x, py - node.world.y
            if math.sqrt(dx * dx + dy * dy) < LAND_LEAD then idx = idx + 1 end
        end
    end
    p.earlyIdx = idx

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

    -- The countdown needs crossing data; until _Tick begins tracking (crossIdx/crossTimes),
    -- leave it unknown. From the last node we passed to the stop, estimate the same way the
    -- full route does -- both directions, fly-over fallback -- so an early stop shows a time
    -- whenever the whole-route hover would have.
    local segTotal, lastPassT
    if cross then
        lastPassT = p.crossTimes and p.crossTimes[cross - 1]
        local names = {}
        for i = cross - 1, p.earlyIdx do names[#names + 1] = p.path[i] and p.path[i].name end
        local complete = true
        for _, nm in ipairs(names) do if not nm then complete = false; break end end
        segTotal = complete and self:_EstimatePathNames(names) or nil
    end
    if segTotal and lastPassT then
        p.known = (lastPassT - (p.startTime or lastPassT)) + segTotal
    else
        p.known = nil
    end
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
            if not pin.__hagHover then
                pin.__hagHover = true
                pin:HookScript("OnEnter", function(self2) module:_OnPinEnter(self2) end)
            end
            local d = pin.taxiNodeData
            if d and d.name and d.slotIndex then
                p.nodeNames[d.slotIndex] = d.name
                local pos = d.position
                if pos then
                    local x, y
                    if pos.GetXY then x, y = pos:GetXY() else x, y = pos.x, pos.y end
                    if x and y then p.nodePos[d.slotIndex] = { x = x, y = y } end
                end
                if d.state == Enum.FlightPathState.Current then p.src = d.name end
            end
        end
    end)
end

-- Estimate the time along an ordered list of node names by assembling known sub-segments.
-- DP over the path: reach name 1 -> each name using whatever segments exist (EITHER
-- direction, via legCost), MINIMISING total imprecision -- so the most precise + same-
-- direction parts win where they exist, gaps fall back to reverse / fly-over, and a long
-- single fly-over loses to a chain of directs covering it. Returns seconds, or nil if the
-- chain can't be completed. Shared by the full-route estimate and the early-stop estimate.
function Misc:_EstimatePathNames(names)
    local n = names and #names or 0
    if n < 2 then return 0 end   -- nothing to sum (stop is where we already are)
    local flights = self:GetDB().flights
    local pen, time = { [1] = 0 }, { [1] = 0 }
    for j = 2, n do
        for i = 1, j - 1 do
            if pen[i] ~= nil then
                local t, segPen = legCost(flights, names[i], names[j])
                if segPen ~= nil then
                    local cand = pen[i] + segPen
                    if pen[j] == nil or cand < pen[j] then
                        pen[j] = cand
                        time[j] = time[i] + t
                    end
                end
            end
        end
    end
    return time[n]   -- nil if the chain can't be completed
end

-- Estimate an unrecorded multi-hop route by summing known segments along the path the taxi
-- actually flies (GetNumRoutes / TaxiGetNodeSlot). Returns seconds, or nil. Uses flight-map
-- names to stay key-consistent.
function Misc:_EstimateRoute(destSlot, destName)
    if not (destSlot and GetNumRoutes and TaxiGetNodeSlot) then return nil end
    local p = self:_p()
    local hops = GetNumRoutes(destSlot)
    if not hops or hops < 2 then return nil end  -- a direct hop has nothing to sum

    -- ordered node names along the route: [1] = source ... [hops+1] = destination
    local nodes = { [1] = p.src, [hops + 1] = destName }
    for h = 2, hops do
        local s = TaxiGetNodeSlot(destSlot, h, true)
        nodes[h] = s and p.nodeNames and p.nodeNames[s]
    end
    for i = 1, hops + 1 do if not nodes[i] then return nil end end

    return self:_EstimatePathNames(nodes)
end

-- Last-resort estimate: the least-imprecise chain of LEARNED segments from src to
-- dst through ANY intermediate nodes (not just the booked route). Lets a never-flown
-- direct hop A->B be estimated as A->C + C->B when those legs exist. Dijkstra over the
-- segment graph, minimising accumulated legCost penalty and summing the times.
function Misc:_EstimateGraph(src, dst)
    if not (src and dst) or src == dst then return nil end
    local flights = self:GetDB().flights

    -- every node name recorded under the CURRENT faction (legCost only uses those).
    local prefix = (UnitFactionGroup("player") or "?") .. "|"
    local nodes = { [src] = true, [dst] = true }
    for key in pairs(flights) do
        if key:sub(1, #prefix) == prefix then
            local a, b = key:sub(#prefix + 1):match("^(.-) %-> (.+)$")
            if a and b then nodes[a] = true; nodes[b] = true end
        end
    end

    local pen, time, done = { [src] = 0 }, { [src] = 0 }, {}
    while true do
        local cur, curPen = nil, math.huge
        for nm, pn in pairs(pen) do
            if not done[nm] and pn < curPen then cur, curPen = nm, pn end
        end
        if not cur then return nil end
        if cur == dst then return time[dst] end
        done[cur] = true
        for nm in pairs(nodes) do
            if not done[nm] and nm ~= cur then
                local t, segPen = legCost(flights, cur, nm)
                if segPen ~= nil then
                    local cand = curPen + segPen
                    if pen[nm] == nil or cand < pen[nm] then
                        pen[nm] = cand
                        time[nm] = time[cur] + t
                    end
                end
            end
        end
    end
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
    local n = sellJunk()
    if n > 0 then self:LogInfo(("sold %d junk item%s"):format(n, n == 1 and "" or "s")) end
end

function Misc:_BuildSellButton()
    local p = self:_p()
    if p.sellBtn or not MerchantFrame then return end
    local b = CreateFrame("Button", nil, MerchantFrame, "BackdropTemplate")
    W.Style(b, "panel2", "borderStrong")
    b:SetSize(86, 22)
    -- just below the merchant window (its bottom-right), clear of the buyback
    -- slot and money area
    b:SetPoint("TOPRIGHT", MerchantFrame, "BOTTOMRIGHT", -4, -2)
    b:SetFrameStrata("HIGH")
    local fs = W.Text(b, "Sell Junk", "accent", "GameFontNormalSmall")
    fs:SetPoint("CENTER")
    b:SetScript("OnEnter", function()
        b:SetBackdropColor(Theme.Unpack("panelHover")); fs:SetTextColor(Theme.Unpack("text"))
    end)
    b:SetScript("OnLeave", function()
        b:SetBackdropColor(Theme.Unpack("panel2")); fs:SetTextColor(Theme.Unpack("accent"))
    end)
    b:SetScript("OnClick", function() self:_Sell() end)
    p.sellBtn = b
end

function Misc:OnSettingChanged(key)
    if key == "sellJunk" and self:GetSetting("sellJunk") ~= "button" then
        if self:_p().sellBtn then self:_p().sellBtn:Hide() end
    end
end

-- ---- registration ---------------------------------------------------------
ns.ModuleManager:Register(Misc:New("Misc", {
    title = "Miscellaneous",
    description = "Flight-path timers and selling junk.",
    defaultEnabled = false,
    color = ns.Theme.hex.grey,  -- distinct tag (accent=Core, green=UnitFrames, purple=Class, gold=Questing, red=CVars)
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
