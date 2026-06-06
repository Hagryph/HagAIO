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

-- Bi-directional route key: the two endpoints are sorted so a flight recorded
-- in one direction also serves the return trip (the timer is symmetric).
local function routeKey(a, b)
    local faction = UnitFactionGroup("player") or "?"
    a, b = tostring(a), tostring(b)
    if a > b then a, b = b, a end
    return faction .. "|" .. a .. " <-> " .. b
end

local ARRIVE_YARDS = 40    -- within this of a path node = we landed there
local CROSS_MARGIN = 75   -- moved this many (linear) yards past the closest approach = passed it

-- A flight DB entry is { t = seconds, q = quality }. Quality ranks the source's
-- precision: DIRECT (a real landing) > EST (an amalgamated estimate) > FLY (a
-- mid-flight closest-approach guess). Legacy entries: a plain number = DIRECT, an
-- old { t, est } = EST if est else DIRECT.
local Q_DIRECT, Q_EST, Q_FLY = 3, 2, 1
local QNAME = { [Q_DIRECT] = "direct", [Q_EST] = "est", [Q_FLY] = "fly" }

local function storedTime(e)
    if type(e) == "number" then return e end
    return e and e.t
end
local function entryQ(e)
    if e == nil then return nil end
    if type(e) ~= "table" then return Q_DIRECT end   -- legacy number
    if e.q then return e.q end
    return e.est and Q_EST or Q_DIRECT               -- migrate old est flag
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

    -- /hag flights -- dump the route DB + last-flight segment-timing diagnostics
    if ns.SlashCommand then
        ns.SlashCommand:Register("flights", function() self:_DumpFlights() end,
            "dump recorded flight times + last-flight debug")
    end
end

function Misc:OnEnable()
    local p = self:_p()
    local bus = ns.EventBus
    p.tokens["MERCHANT_SHOW"]   = bus:On("MERCHANT_SHOW",   function() self:_OnMerchantShow() end)
    p.tokens["MERCHANT_CLOSED"] = bus:On("MERCHANT_CLOSED", function() self:_OnMerchantClosed() end)
    -- build + register the timer so it can be placed in Blizzard's Edit Mode
    self:_BuildFrame()
end

function Misc:OnDisable()
    local p = self:_p()
    local bus = ns.EventBus
    for event, token in pairs(p.tokens) do bus:Off(event, token) end
    wipe(p.tokens)
    if p.frame then p.frame:Hide() end   -- recording keeps running; display stops
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
    p.route = routeKey(p.src, dst)
    -- resolve the expected time NOW, while the flight map (taxi data) is still
    -- open -- GetNumRoutes/TaxiGetNodeSlot stop working once it closes.
    p.known = (self:_RouteTime(p.route, slot, dst))
    p.path = self:_BuildPath(slot, dst)   -- ordered nodes (+world pos) for timing/landing
    -- diagnostics for /hag flights
    local nodes = {}
    for i, n in ipairs(p.path) do nodes[i] = (n.name or "?") .. (n.world and "" or "[noPos]") end
    p.diag = {
        hops = (GetNumRoutes and GetNumRoutes(slot)) or "nil",
        flightMapID = p.flightMapID or "nil",
        nodes = nodes, samples = {}, crossings = {}, moved = false,
    }
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
end

-- Write rules for direct (landing) and estimate writes:
--   a real DIRECT always replaces a lower-quality entry (even < 5s);
--   otherwise (same quality, or estimate vs direct) -> only when the time
--   changed by >= 5s. The entry's quality tracks the new value's source.
function Misc:_Store(key, seconds, est)
    local flights = self:GetDB().flights
    local q = est and Q_EST or Q_DIRECT
    local cur = flights[key]
    if cur == nil then
        flights[key] = { t = seconds, q = q }
        return
    end
    local curQ = entryQ(cur)
    if type(cur) ~= "table" then cur = { t = storedTime(cur), q = curQ }; flights[key] = cur end
    if q == Q_DIRECT and curQ < Q_DIRECT then
        cur.t, cur.q = seconds, q                       -- a real direct beats lower quality
    elseif math.abs(seconds - cur.t) >= 5 then
        cur.t, cur.q = seconds, q                        -- +/-5s rule otherwise
    end
end

-- Fill-only write for fly-over (closest-approach) segment times: the lowest
-- quality tier, so it ONLY populates an empty slot and never overwrites anything.
function Misc:_StoreIfNew(key, seconds)
    local flights = self:GetDB().flights
    if flights[key] == nil then flights[key] = { t = seconds, q = Q_FLY } end
end

-- Best known time for a route as (seconds, isEstimate). A measured direct wins;
-- otherwise compute a multi-hop estimate, persist it, and return it.
function Misc:_RouteTime(key, slot, name)
    local entry = self:GetDB().flights[key]
    if entry and entryQ(entry) == Q_DIRECT then
        return storedTime(entry), false   -- a real direct: exact
    end
    -- otherwise build the best amalgamated estimate (prefers direct sub-segments)
    local est = self:_EstimateRoute(slot, name)
    if est then self:_Store(key, est, true); return est, true end
    return storedTime(entry), entry ~= nil   -- fall back to stored est/fly (or nil)
end

-- Ordered nodes the taxi flies through (source ... destination), each tagged with
-- its WORLD position (continent + yards). Built at take-off while the taxi data
-- is still live; used both to detect where a stopped flight ended and to time the
-- closest approach to each node mid-flight.
function Misc:_BuildPath(destSlot, destName)
    local p = self:_p()
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
function Misc:_LandedNode()
    local p = self:_p()
    if not (p.path and #p.path > 0) then return p.dst end
    local px, py, pc = self:_PlayerWorld()
    if not px then return p.dst end
    local bestName, bestD2, comparable = nil, ARRIVE_YARDS * ARRIVE_YARDS, false
    for _, node in ipairs(p.path) do
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
-- and record the segment from the previous node as a direct flight.
function Misc:_PollCrossing()
    local p = self:_p()
    if not (p.path and p.crossIdx and p.crossIdx <= #p.path) then return end
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
        self:_RecordCross(p.crossIdx, p.crossMinTime)
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
    local prevT = p.crossTimes[idx - 1]
    local a = p.path[idx - 1] and p.path[idx - 1].name
    local b = p.path[idx] and p.path[idx].name
    if prevT and a and b then
        local seg = when - prevT
        if seg > 1 then self:_StoreIfNew(routeKey(a, b), seg) end  -- fill-only
        if p.diag then
            p.diag.crossings[#p.diag.crossings + 1] =
                ("%s -> %s = %s"):format(tostring(a), tostring(b), fmt(seg))
        end
    end
end

-- The final leg (last node passed -> where we landed), which _PollCrossing can't
-- catch because you stop on the landing node instead of flying past it.
function Misc:_RecordFinalLeg(landed, when)
    local p = self:_p()
    if not p.crossTimes then return end
    local maxIdx, maxTime = 1, p.crossTimes[1]
    for i, t in pairs(p.crossTimes) do
        if i > maxIdx then maxIdx, maxTime = i, t end
    end
    local fromName = p.path and p.path[maxIdx] and p.path[maxIdx].name
    if fromName and maxTime and fromName ~= landed then
        local seg = when - maxTime
        if seg > 1 then self:_StoreIfNew(routeKey(fromName, landed), seg) end  -- fill-only
        if p.diag then
            p.diag.finalLeg = ("%s -> %s = %s"):format(tostring(fromName), tostring(landed), fmt(seg))
        end
    end
end

-- Diagnostic sample (~1/sec while flying): player world position, current node
-- being timed, and distance to it. Reveals whether GetPlayerMapPosition updates
-- mid-flight, whether continents match, and whether we close on each node.
function Misc:_DiagSample()
    local p = self:_p()
    if not p.diag then return end
    p.diagAcc = (p.diagAcc or 0) + 0.1
    if p.diagAcc < 1 then return end
    p.diagAcc = 0
    if #p.diag.samples >= 90 then return end

    local px, py, pc = self:_PlayerWorld()
    if px and p.diag.lastPx and (math.abs(px - p.diag.lastPx) > 1 or math.abs(py - p.diag.lastPy) > 1) then
        p.diag.moved = true
    end
    p.diag.lastPx, p.diag.lastPy = px, py

    local idx = p.crossIdx
    local node = p.path and idx and p.path[idx]
    local dist, why = "?", ""
    if not px then why = "(playerpos nil)"
    elseif not (node and node.world) then why = "(node noPos)"
    elseif pc ~= node.world.c then why = "(diff continent)"
    else
        local dx, dy = px - node.world.x, py - node.world.y
        dist = ("%.0f"):format(math.sqrt(dx * dx + dy * dy))
    end
    local elapsed = GetTime() - (p.diag.t0 or GetTime())
    local pstr = px and ("(%.0f,%.0f)@%s"):format(px, py, tostring(pc)) or "nil"
    p.diag.samples[#p.diag.samples + 1] =
        ("%4.0fs idx=%s p=%s d=%s %s"):format(elapsed, tostring(idx), pstr, dist, why)
end

function Misc:_DumpFlights()
    local p = self:_p()
    local out = {}
    local function add(s) out[#out + 1] = s end

    local flights = self:GetDB().flights or {}
    add("=== flights DB ===")
    local n = 0
    for key, e in pairs(flights) do
        n = n + 1
        add(("  %s = %s (%s)"):format(key, fmt(storedTime(e)), QNAME[entryQ(e)] or "?"))
    end
    add(("  %d route(s)"):format(n))

    local d = p.diag
    add("=== last flight ===")
    if not d then
        add("  (none this session)")
    else
        add(("  GetNumRoutes=%s  flightMapID=%s  positionMoved=%s")
            :format(tostring(d.hops), tostring(d.flightMapID), tostring(d.moved)))
        add("  path: " .. table.concat(d.nodes, " -> "))
        add(("  crossings recorded: %d"):format(#d.crossings))
        for _, c in ipairs(d.crossings) do add("    " .. c) end
        if d.finalLeg then add("  finalLeg: " .. d.finalLeg) end
        add(("  samples (%d):"):format(#d.samples))
        for _, s in ipairs(d.samples) do add("    " .. s) end
    end

    -- route keys contain a literal "|" (faction separator) which the EditBox eats
    -- as a colour code (e.g. "|R" swallowed the R) -- show it as "/" instead.
    local text = table.concat(out, "\n"):gsub("|", "/")
    self:_ShowCopyText(text)
end

-- Show a selectable text box (WoW has no clipboard API) -- focused + select-all,
-- so the user just presses Ctrl+C. Reused frame.
function Misc:_ShowCopyText(text)
    local p = self:_p()
    local f = p.copyFrame
    if not f then
        f = CreateFrame("Frame", "HagAIOCopyFrame", UIParent, "BackdropTemplate")
        W.Style(f, "bg1", "borderStrong")
        f:SetSize(560, 420)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        f:EnableMouse(true)
        f:SetMovable(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        tinsert(UISpecialFrames, "HagAIOCopyFrame")  -- ESC closes

        local title = W.Text(f, "Flights debug -- Ctrl+C to copy", "accent", "GameFontNormal")
        title:SetPoint("TOPLEFT", 14, -12)
        local close = W.TextButton(f, "Close")
        close:SetPoint("TOPRIGHT", -12, -10)
        close:SetScript("OnClick", function() f:Hide() end)

        local scroll = CreateFrame("ScrollFrame", "HagAIOCopyScroll", f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 14, -40)
        scroll:SetPoint("BOTTOMRIGHT", -32, 14)

        local eb = CreateFrame("EditBox", nil, scroll)
        eb:SetMultiLine(true)
        eb:SetFontObject("ChatFontNormal")
        eb:SetWidth(500)
        eb:SetAutoFocus(false)
        eb:SetScript("OnEscapePressed", function() f:Hide() end)
        scroll:SetScrollChild(eb)
        f.eb = eb
        p.copyFrame = f
    end
    f.eb:SetText(text)
    f.eb:SetCursorPosition(0)
    f.eb:HighlightText()
    f.eb:SetFocus()
    f:Show()
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
            p.crossMinDist = math.huge
            p.crossMinTime = nil
            p.diagAcc = 0
            if p.diag then p.diag.t0 = p.startTime end
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
                self:_Store(routeKey(p.src, landed), dur, false)  -- full source -> landed
                self:_RecordFinalLeg(landed, now)                 -- last per-node segment
            end
            if p.frame then p.frame:Hide() end
            self:_StopTicker()
        else
            p.acc = (p.acc or 0) + dt
            if p.acc >= 0.1 then
                p.acc = 0
                self:_PollCrossing()     -- closest-approach segment timing
                self:_DiagSample()
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

    -- register with the shared Edit Mode framework (drag, snap, persistence).
    -- The default spot is the boss-mod "critical" position (centre, above mid).
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
        p.frame.time:SetText("-:--")  -- not recorded yet
        p.frame.bar:SetValue(0)
    end
    p.frame:Show()
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

-- Estimate an unrecorded multi-hop route by summing known stop-to-stop segment
-- times along the path the taxi actually flies (GetNumRoutes / TaxiGetNodeSlot),
-- the way InFlight does it. Returns seconds, or nil if the chain can't be
-- completed from known segments. Uses flight-map names to stay key-consistent.
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

    -- DP over the ordered path: reach node 1 -> each node using whatever known
    -- sub-segments exist, but MINIMISE total imprecision (penalty per segment:
    -- direct 0, estimate 1, fly-over 2). This takes the most precise parts where
    -- they exist and fills the gaps with lower-quality data -- so a single
    -- fly-over spanning the whole route loses to a chain of directs covering it.
    local flights = self:GetDB().flights
    local pen, time = { [1] = 0 }, { [1] = 0 }
    for j = 2, hops + 1 do
        for i = 1, j - 1 do
            if pen[i] ~= nil then
                local e = flights[routeKey(nodes[i], nodes[j])]
                local q = entryQ(e)
                if q then
                    local cand = pen[i] + (Q_DIRECT - q)   -- 0 / 1 / 2 per segment
                    if pen[j] == nil or cand < pen[j] then
                        pen[j] = cand
                        time[j] = time[i] + storedTime(e)
                    end
                end
            end
        end
    end
    return time[hops + 1]   -- nil if the chain can't be completed
end

function Misc:_OnPinEnter(pin)
    if not (self:IsEnabled() and self:GetSetting("showHover")) then return end
    local d = pin.taxiNodeData
    if not d or d.state ~= Enum.FlightPathState.Reachable then return end
    local src = self:_p().src
    if not src then return end

    local dur, estimated = self:_RouteTime(routeKey(src, d.name), d.slotIndex, d.name)

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
    color = ns.Theme.hex.accent,
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
