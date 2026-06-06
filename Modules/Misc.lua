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

-- A flight DB entry is { t = seconds, est = bool }; legacy entries are a plain
-- number, always read as a measured direct time.
local ARRIVE_YARDS = 40   -- within this of the target = "we made it" (else dropped)

local function storedTime(e)
    if type(e) == "number" then return e end
    return e and e.t
end
local function isEstimate(e)
    return type(e) == "table" and e.est == true
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
    p.dstSlot = slot          -- kept for a multi-hop estimate if unrecorded
    p.dstPos = p.nodePos and p.nodePos[slot]   -- target position, for arrival check
    p.dstMapID = p.flightMapID
    p.route = routeKey(p.src, dst)
    -- resolve the expected time NOW, while the flight map (taxi data) is still
    -- open -- GetNumRoutes/TaxiGetNodeSlot stop working once it closes.
    p.known = (self:_RouteTime(p.route, slot, dst))
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

-- Write rules for the flight DB:
--   direct measurement  -> always replaces a stored ESTIMATE (even < 5s);
--                          once a direct time exists, only a >=5s change updates it.
--   estimate            -> fills an empty slot / refreshes another estimate (>=5s),
--                          but NEVER overwrites a measured direct time.
function Misc:_Store(key, seconds, est)
    local flights = self:GetDB().flights
    local cur = flights[key]
    if type(cur) == "number" then cur = { t = cur, est = false }; flights[key] = cur end
    if not cur then
        flights[key] = { t = seconds, est = est and true or false }
    elseif est then
        if cur.est and math.abs(seconds - cur.t) >= 5 then cur.t = seconds end
    else
        if cur.est then
            cur.t, cur.est = seconds, false           -- direct always beats an estimate
        elseif math.abs(seconds - cur.t) >= 5 then
            cur.t = seconds                            -- +/-5s rule, direct over direct
        end
    end
end

-- Best known time for a route as (seconds, isEstimate). A measured direct wins;
-- otherwise compute a multi-hop estimate, persist it, and return it.
function Misc:_RouteTime(key, slot, name)
    local entry = self:GetDB().flights[key]
    if entry and not isEstimate(entry) then
        return storedTime(entry), false
    end
    local est = self:_EstimateRoute(slot, name)
    if est then self:_Store(key, est, true); return est, true end
    return storedTime(entry), entry ~= nil   -- stored estimate (or nil -> "-:--")
end

-- Did we actually reach the target? Compare the player's world position to the
-- destination flight point's: different continent, or > ARRIVE_YARDS away, means
-- the flight was cut short (hearth / port). Undeterminable -> assume arrived so
-- good data isn't dropped.
function Misc:_Arrived()
    local p = self:_p()
    if not (p.dstPos and p.dstMapID and C_Map and C_Map.GetWorldPosFromMapPos
        and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition and CreateVector2D) then
        return true
    end
    local destC, destW = C_Map.GetWorldPosFromMapPos(p.dstMapID, CreateVector2D(p.dstPos.x, p.dstPos.y))
    local pmap = C_Map.GetBestMapForUnit("player")
    local ppos = pmap and C_Map.GetPlayerMapPosition(pmap, "player")
    if not (destC and destW and ppos) then return true end
    local playerC, playerW = C_Map.GetWorldPosFromMapPos(pmap, ppos)
    if not (playerC and playerW) then return true end
    if playerC ~= destC then return false end          -- different continent
    local dx, dy = playerW.x - destW.x, playerW.y - destW.y
    return (dx * dx + dy * dy) <= (ARRIVE_YARDS * ARRIVE_YARDS)
end

function Misc:_Tick(dt)
    local p = self:_p()
    if p.phase == "boarding" then
        if UnitOnTaxi("player") then
            p.phase = "flying"
            p.startTime = GetTime()
            -- p.known was resolved at take-off (recorded time or multi-hop estimate)
            self:_RefreshDisplay()
        elseif GetTime() - (p.boardStart or 0) > 8 then
            self:_StopTicker()  -- never took off (cancelled)
        end

    elseif p.phase == "flying" then
        if not UnitOnTaxi("player") then
            local dur = GetTime() - (p.startTime or GetTime())
            -- Record the measured total only if we actually arrived at the target
            -- (else it was an interrupted flight: hearthed / ported mid-air).
            if dur > 1 and self:_Arrived() then
                self:_Store(p.route, dur, false)
            end
            if p.frame then p.frame:Hide() end
            self:_StopTicker()
        else
            p.acc = (p.acc or 0) + dt
            if p.acc >= 0.1 then p.acc = 0; self:_RefreshDisplay() end
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

    -- DP over the ordered path: cheapest known sum from node 1 to each node,
    -- using any MEASURED DIRECT sub-segment (never another estimate, so errors
    -- don't compound).
    local flights = self:GetDB().flights
    local best = { [1] = 0 }
    for j = 2, hops + 1 do
        for i = 1, j - 1 do
            local e = flights[routeKey(nodes[i], nodes[j])]
            local seg = best[i] and not isEstimate(e) and storedTime(e)
            if seg then
                local t = best[i] + seg
                if not best[j] or t < best[j] then best[j] = t end
            end
        end
    end
    return best[hops + 1]
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
