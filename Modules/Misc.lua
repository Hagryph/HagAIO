local addonName, ns = ...
local Class = ns.Class
local Theme = ns.Theme
local W = ns.UI.Widgets

-- Modules/Misc.lua
-- Miscellaneous helpers:
--   * Flight Timers — time each flight path the first time you take it and show
--     a countdown on later trips along the same route.
--   * Sell Junk — sell grey items at a vendor, automatically on open or via a
--     "Sell Junk" button added to the merchant window.

local Misc = Class.new("Misc", ns.Module)

local hooked = false  -- TakeTaxiNode hook installed once per session

local function fmt(s)
    s = math.max(0, math.floor(s + 0.5))
    return ("%d:%02d"):format(math.floor(s / 60), s % 60)
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
    p.tokens = {}
    p.phase = nil       -- nil / "boarding" / "flying"
    p.src = nil
end

function Misc:OnEnable()
    local p = self:_p()
    self:GetDB().flights = self:GetDB().flights or {}
    local bus = ns.EventBus.Get()

    -- flight timers
    p.tokens["TAXIMAP_OPENED"] = bus:On("TAXIMAP_OPENED", function() self:_CaptureSource() end)
    if not hooked and type(TakeTaxiNode) == "function" then
        local module = self
        hooksecurefunc("TakeTaxiNode", function(slot) module:_OnTakeTaxi(slot) end)
        hooked = true
    end

    -- sell junk
    p.tokens["MERCHANT_SHOW"]   = bus:On("MERCHANT_SHOW",   function() self:_OnMerchantShow() end)
    p.tokens["MERCHANT_CLOSED"] = bus:On("MERCHANT_CLOSED", function() self:_OnMerchantClosed() end)
end

function Misc:OnDisable()
    local p = self:_p()
    local bus = ns.EventBus.Get()
    for event, token in pairs(p.tokens) do bus:Off(event, token) end
    wipe(p.tokens)
    self:_StopTicker()
    if p.frame then p.frame:Hide() end
    if p.sellBtn then p.sellBtn:Hide() end
end

-- ======================= FLIGHT TIMERS =====================================
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

local function routeKey(src, dst)
    local faction = UnitFactionGroup("player") or "?"
    return faction .. "|" .. tostring(src) .. " @ " .. tostring(dst)
end

function Misc:_OnTakeTaxi(slot)
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

function Misc:_Tick(dt)
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
            if dur > 1 then self:GetDB().flights[p.route] = dur end
            if p.frame then p.frame:Hide() end
            self:_StopTicker()
        else
            p.acc = (p.acc or 0) + dt
            if p.acc >= 0.1 then p.acc = 0; self:_UpdateTimer() end
        end
    end
end

function Misc:_BuildFrame()
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

function Misc:_ShowTimer()
    if not self:GetSetting("showTimer") then return end
    local p = self:_p()
    self:_BuildFrame()
    p.frame.dest:SetText(p.dst or "Flight")
    p.frame:Show()
    self:_UpdateTimer()
end

function Misc:_UpdateTimer()
    local p = self:_p()
    if not (p.frame and p.frame:IsShown() and p.startTime) then return end
    local elapsed = GetTime() - p.startTime
    if p.known and p.known > 0 then
        p.frame.time:SetText(fmt(p.known - elapsed))
        p.frame.bar:SetValue(math.min(1, elapsed / p.known))
    else
        p.frame.time:SetText(fmt(elapsed) .. "  ...")
        p.frame.bar:SetValue(0)
    end
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
    b:SetPoint("BOTTOMRIGHT", MerchantFrame, "TOPRIGHT", -2, 2)
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
    -- if switching away from Button mode while a vendor is open, hide the button
    if key == "sellJunk" and self:GetSetting("sellJunk") ~= "button" then
        if self:_p().sellBtn then self:_p().sellBtn:Hide() end
    end
end

-- ---- registration ---------------------------------------------------------
ns.ModuleManager.Get():Register(Misc:New("Misc", {
    title = "Miscellaneous",
    description = "Flight-path timers and selling junk.",
    defaultEnabled = false,
    color = ns.Theme.hex.accent,
    settings = {
        { type = "header", text = "Flight timers" },
        { type = "toggle", key = "showTimer", label = "Show flight timer", default = true },
        { type = "note", text = "The first time you fly a route it's timed; after that a countdown is shown for it." },

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
