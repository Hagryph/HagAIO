local addonName, ns = ...
local Class = ns.Class

-- Modules/UnitFrames.lua
-- Tints the player & target health bars by remaining health: the bar's normal
-- green at full HP grading down to bright red when low.
--
-- Midnight 12.0 "Secret Values": an addon may NOT read health and branch on it
-- (no math/compare/conditionals on secrets). The sanctioned route is a Color
-- Curve — the gradient thresholds live in the curve, and the engine evaluates
-- the (secret) health through it and hands back a colour we pass straight into
-- a Blizzard widget method. We never "know" the number. See [[project-wow-patch-api]].

local UnitFrames = Class.new("UnitFrames", ns.Module)

-- normal-health green -> bright red endpoints (direct RGB blend)
local GREEN = { 0.10, 0.85, 0.10 }
local RED   = { 0.95, 0.13, 0.13 }

local function colorAt(t)  -- t = health fraction (0 = empty -> red, 1 = full -> green)
    return CreateColor(
        RED[1] + (GREEN[1] - RED[1]) * t,
        RED[2] + (GREEN[2] - RED[2]) * t,
        RED[3] + (GREEN[3] - RED[3]) * t, 1)
end

-- Resolve a unit's health StatusBar across retail frame layouts (with fallbacks
-- for the 10.0 unit-frame rewrite and older globals).
local function resolveBar(unit)
    if unit == "player" then
        local f = PlayerFrame
        return (f and f.healthbar)
            or (f and f.PlayerFrameContent and f.PlayerFrameContent.PlayerFrameContentMain
                and f.PlayerFrameContent.PlayerFrameContentMain.HealthBarsContainer
                and f.PlayerFrameContent.PlayerFrameContentMain.HealthBarsContainer.HealthBar)
            or _G.PlayerFrameHealthBar
    elseif unit == "target" then
        local f = TargetFrame
        return (f and f.healthbar)
            or (f and f.TargetFrameContent and f.TargetFrameContent.TargetFrameContentMain
                and f.TargetFrameContent.TargetFrameContentMain.HealthBarsContainer
                and f.TargetFrameContent.TargetFrameContentMain.HealthBarsContainer.HealthBar)
            or _G.TargetFrameHealthBar
    end
end

local function apiAvailable()
    return C_CurveUtil and C_CurveUtil.CreateColorCurve and UnitHealthPercent and CreateColor
end

-- ---- lifecycle ------------------------------------------------------------
function UnitFrames:OnInitialize()
    local p = self:_p()
    p.curve = nil
    p.tokens = {}
    p.hooked = false
end

function UnitFrames:OnEnable()
    local p = self:_p()
    if not apiAvailable() then
        self:LogWarn("colour-curve / UnitHealthPercent API unavailable; cannot tint health bars")
        return
    end

    self:_BuildCurve()

    -- Reapply right after Blizzard's own health-bar update (the robust path).
    if not p.hooked and type(UnitFrameHealthBar_Update) == "function" then
        hooksecurefunc("UnitFrameHealthBar_Update", function(bar, unit)
            if unit == "player" or unit == "target" then self:_Apply(unit) end
        end)
        p.hooked = true
    end

    -- Backup triggers (some updates don't route through the hook).
    local bus = ns.EventBus.Get()
    p.tokens["UNIT_HEALTH"]            = bus:On("UNIT_HEALTH",            function(_, unit) self:_Apply(unit) end)
    p.tokens["UNIT_MAXHEALTH"]        = bus:On("UNIT_MAXHEALTH",         function(_, unit) self:_Apply(unit) end)
    p.tokens["PLAYER_TARGET_CHANGED"] = bus:On("PLAYER_TARGET_CHANGED",  function() self:_Apply("target") end)
    p.tokens["PLAYER_ENTERING_WORLD"] = bus:On("PLAYER_ENTERING_WORLD",  function() self:_ApplyAll() end)

    self:_ApplyAll()
end

function UnitFrames:OnDisable()
    local p = self:_p()
    local bus = ns.EventBus.Get()
    for event, token in pairs(p.tokens) do bus:Off(event, token) end
    wipe(p.tokens)
    -- hand the bars back to Blizzard's colouring
    self:_Restore("player")
    self:_Restore("target")
end

-- ---- curve + apply --------------------------------------------------------
function UnitFrames:_BuildCurve()
    local p = self:_p()
    local curve = C_CurveUtil.CreateColorCurve()
    local style = self:GetSetting("style") or "steps"

    if style == "smooth" then
        curve:SetType((Enum.LuaCurveType and Enum.LuaCurveType.Linear) or Enum.LuaCurveType.Step)
        curve:AddPoint(0.0, colorAt(0.0))
        curve:AddPoint(1.0, colorAt(1.0))
    else
        -- 5% bands: a flat colour per 5% of health, green at the top -> red low.
        curve:SetType(Enum.LuaCurveType.Step)
        for i = 0, 20 do
            local t = i / 20
            curve:AddPoint(t, colorAt(t))
        end
    end
    p.curve = curve
end

function UnitFrames:_Apply(unit)
    local p = self:_p()
    if not (p.curve and self:IsEnabled()) then return end
    if unit == "player" and not self:GetSetting("player") then return end
    if unit == "target" and not self:GetSetting("target") then return end
    if unit == "target" and not UnitExists("target") then return end

    local bar = resolveBar(unit)
    if not bar or not bar.SetStatusBarColor then return end

    -- color holds secret values; pass straight into the widget (never inspected)
    local color = UnitHealthPercent(unit, false, p.curve)
    if color then
        bar:SetStatusBarColor(color:GetRGB())
    end
end

function UnitFrames:_ApplyAll()
    self:_Apply("player")
    self:_Apply("target")
end

function UnitFrames:_Restore(unit)
    local bar = resolveBar(unit)
    if bar and type(UnitFrameHealthBar_Update) == "function" then
        pcall(UnitFrameHealthBar_Update, bar, unit)  -- let Blizzard recolour now
    end
end

-- React to settings changes from the auto-generated settings page.
function UnitFrames:OnSettingChanged(key, value)
    if key == "style" then self:_BuildCurve() end
    if (key == "player" or key == "target") and value == false then
        self:_Restore(key)
    end
    self:_ApplyAll()
end

-- ---- registration ---------------------------------------------------------
ns.ModuleManager.Get():Register(UnitFrames:New("UnitFrames", {
    title = "Unit Frames",
    description = "Tints the player and target health bars by remaining health (green → red).",
    defaultEnabled = true,
    color = ns.Theme.hex.win,
    settings = {
        { type = "header", text = "Health bar tint" },
        { type = "toggle", key = "player", label = "Tint player health bar", default = true },
        { type = "toggle", key = "target", label = "Tint target health bar", default = true },
        { type = "select", key = "style", label = "Gradient", default = "steps",
          options = {
              { value = "steps",  text = "5% steps" },
              { value = "smooth", text = "Smooth" },
          } },
        { type = "note", text = "Colour runs from the bar's normal green at full health to bright red when low. Uses Midnight's sanctioned colour-curve API (Secret-Values safe — no health values are read)." },
    },
}))
