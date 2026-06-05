local addonName, ns = ...
local Class = ns.Class
local Theme = ns.Theme
local W = ns.UI.Widgets

-- Modules/Travel.lua
-- Travel helpers. First feature: Flight Timers — times each flight path the
-- first time you take it (between two flight masters) and shows a countdown on
-- every later trip along the same route.
--
-- Approach (as InFlight does it): hook TakeTaxiNode for the destination, read
-- the source from the CURRENT taxi node, then poll UnitOnTaxi to find take-off
-- and landing. Durations are stored per faction + route.

local Travel = Class.new("Travel", ns.Module)

local hooked = false

local function fmt(s)
    s = math.max(0, math.floor(s + 0.5))
    return ("%d:%02d"):format(math.floor(s / 60), s % 60)
end

-- ---- lifecycle ------------------------------------------------------------
function Travel:OnInitialize()
    local p = self:_p()
    p.tokens = {}
    p.phase = nil       -- nil / "boarding" / "flying"
    p.src = nil
end

function Travel:OnEnable()
    local p = self:_p()
    self:GetDB().flights = self:GetDB().flights or {}

    local bus = ns.EventBus.Get()
    -- the source flight point is known while the taxi map is open
    p.tokens["TAXIMAP_OPENED"] = bus:On("TAXIMAP_OPENED", function() self:_CaptureSource() end)

    -- hook the destination pick once per session
    if not hooked and type(TakeTaxiNode) == "function" then
        local module = self
        hooksecurefunc("TakeTaxiNode", function(slot) module:_OnTakeTaxi(slot) end)
        hooked = true
    end
end

function Travel:OnDisable()
    local p = self:_p()
    local bus = ns.EventBus.Get()
    for event, token in pairs(p.tokens) do bus:Off(event, token) end
    wipe(p.tokens)
    self:_StopTicker()
    if p.frame then p.frame:Hide() end
end

-- ---- route capture --------------------------------------------------------
function Travel:_CaptureSource()
    local p = self:_p()
    if not (NumTaxiNodes and TaxiNodeGetType and TaxiNodeName) then return end
    for i = 1, NumTaxiNodes() do
        if TaxiNodeGetType(i) == "CURRENT" then
            p.src = TaxiNodeName(i)
            return
        end
    end
end

local function routeKey(src, dst)
    local faction = UnitFactionGroup("player") or "?"
    return faction .. "|" .. tostring(src) .. " @ " .. tostring(dst)
end

function Travel:_OnTakeTaxi(slot)
    local p = self:_p()
    if not self:IsEnabled() then return end
    if TaxiNodeGetType and TaxiNodeGetType(slot) ~= "REACHABLE" then return end
    local dst = TaxiNodeName and TaxiNodeName(slot)
    if not (p.src and dst) then return end

    p.dst = dst
    p.route = routeKey(p.src, dst)
    p.phase = "boarding"
    p.boardStart = GetTime()
    self:_StartTicker()
end

-- ---- flight tracking (poll UnitOnTaxi) ------------------------------------
function Travel:_StartTicker()
    local p = self:_p()
    if not p.ticker then
        local module = self
        p.ticker = CreateFrame("Frame")
        p.acc = 0
        p.ticker:SetScript("OnUpdate", function(_, dt) module:_Tick(dt) end)
    end
    p.ticker:Show()
end

function Travel:_StopTicker()
    local p = self:_p()
    if p.ticker then p.ticker:Hide() end
    p.phase = nil
end

function Travel:_Tick(dt)
    local p = self:_p()
    if p.phase == "boarding" then
        if UnitOnTaxi("player") then
            p.phase = "flying"
            p.startTime = GetTime()
            p.known = self:GetDB().flights[p.route]
            self:_ShowTimer()
        elseif GetTime() - (p.boardStart or 0) > 8 then
            self:_StopTicker()  -- never took off (cancelled)
        end

    elseif p.phase == "flying" then
        if not UnitOnTaxi("player") then
            local dur = GetTime() - (p.startTime or GetTime())
            if dur > 1 then self:GetDB().flights[p.route] = dur end  -- learn / refine
            if p.frame then p.frame:Hide() end
            self:_StopTicker()
        else
            p.acc = (p.acc or 0) + dt
            if p.acc >= 0.1 then p.acc = 0; self:_UpdateTimer() end
        end
    end
end

-- ---- display --------------------------------------------------------------
function Travel:_BuildFrame()
    local p = self:_p()
    if p.frame then return end
    local f = W.Panel(UIParent, "panel", "borderStrong")
    f:SetSize(230, 42)
    f:SetPoint("TOP", UIParent, "TOP", 0, -140)
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
end

function Travel:_ShowTimer()
    if not self:GetSetting("showTimer") then return end
    local p = self:_p()
    self:_BuildFrame()
    p.frame.dest:SetText(p.dst or "Flight")
    p.frame:Show()
    self:_UpdateTimer()
end

function Travel:_UpdateTimer()
    local p = self:_p()
    if not (p.frame and p.frame:IsShown() and p.startTime) then return end
    local elapsed = GetTime() - p.startTime
    if p.known and p.known > 0 then
        p.frame.time:SetText(fmt(p.known - elapsed))
        p.frame.bar:SetValue(math.min(1, elapsed / p.known))
    else
        p.frame.time:SetText(fmt(elapsed) .. "  ...")  -- first trip: learning
        p.frame.bar:SetValue(0)
    end
end

-- ---- registration ---------------------------------------------------------
ns.ModuleManager.Get():Register(Travel:New("Travel", {
    title = "Travel",
    description = "Travel helpers, including flight-path timers.",
    defaultEnabled = false,
    color = ns.Theme.hex.accent,
    settings = {
        { type = "header", text = "Flight timers" },
        { type = "toggle", key = "showTimer", label = "Show flight timer", default = true },
        { type = "note", text = "The first time you fly a route it's timed; after that a countdown is shown for it." },
    },
}))
