local addonName, ns = ...
local Class = ns.Class

-- Modules/UnitFrames.lua
-- Tints the player & target health bars by remaining health: the bar's normal
-- green at full HP grading through yellow to bright red when low.
--
-- Midnight 12.0 "Secret Values": an addon may NOT read health and branch on it.
-- The sanctioned route is a Color Curve — the gradient lives in the curve, the
-- engine evaluates the (secret) health through it and hands back a colour we
-- pass straight into the widget. We re-assert our colour whenever Blizzard
-- recolours the bar (hooking SetStatusBarColor) so our tint always wins.

local UnitFrames = Class.new("UnitFrames", ns.Module)

-- green (full) -> yellow (half) -> bright red (low)
local GREEN  = { 0.10, 0.85, 0.10 }
local YELLOW = { 0.95, 0.82, 0.15 }
local RED    = { 0.95, 0.13, 0.13 }

local function mix(a, b, u)
    return a[1] + (b[1] - a[1]) * u,
           a[2] + (b[2] - a[2]) * u,
           a[3] + (b[3] - a[3]) * u
end

local function colorAt(t)  -- t: 1 -> green, 0.5 -> yellow, 0 -> red
    local r, g, b
    if t >= 0.5 then
        r, g, b = mix(YELLOW, GREEN, (t - 0.5) / 0.5)
    else
        r, g, b = mix(RED, YELLOW, t / 0.5)
    end
    return CreateColor(r, g, b, 1)
end

-- Resolve a unit's health StatusBar across retail frame layouts.
local function resolveBar(unit)
    local f = (unit == "player") and PlayerFrame or (unit == "target") and TargetFrame
    if not f then return nil end
    if f.healthbar then return f.healthbar end   -- alias set by UnitFrame_Initialize
    if f.healthBar then return f.healthBar end
    local content = f.PlayerFrameContent or f.TargetFrameContent
    local main = content and (content.PlayerFrameContentMain or content.TargetFrameContentMain)
    if main then
        if main.HealthBarsContainer and main.HealthBarsContainer.HealthBar then
            return main.HealthBarsContainer.HealthBar
        end
        if main.HealthBar then return main.HealthBar end
    end
    return _G[(unit == "player") and "PlayerFrameHealthBar" or "TargetFrameHealthBar"]
end

local function apiAvailable()
    return C_CurveUtil and C_CurveUtil.CreateColorCurve and UnitHealthPercent and CreateColor
end

-- reentrancy guard: bars we're currently colouring (so our own SetStatusBarColor
-- doesn't re-trigger the hook)
local applying = {}

-- ---- lifecycle ------------------------------------------------------------
function UnitFrames:OnInitialize()
    local p = self:_p()
    p.curve = nil
    p.tokens = {}
end

function UnitFrames:OnEnable()
    local p = self:_p()
    if not apiAvailable() then
        self:LogWarn("health-bar colouring isn't supported on this client build")
        return
    end

    self:_BuildCurve()

    local foundPlayer = self:_HookBar("player")
    local foundTarget = self:_HookBar("target")

    local bus = ns.EventBus.Get()
    p.tokens["UNIT_HEALTH"]            = bus:On("UNIT_HEALTH",            function(_, u) self:_Tint(u) end)
    p.tokens["UNIT_HEALTH_FREQUENT"]  = bus:On("UNIT_HEALTH_FREQUENT",   function(_, u) self:_Tint(u) end)
    p.tokens["UNIT_MAXHEALTH"]        = bus:On("UNIT_MAXHEALTH",         function(_, u) self:_Tint(u) end)
    p.tokens["PLAYER_TARGET_CHANGED"] = bus:On("PLAYER_TARGET_CHANGED",  function() self:_HookBar("target"); self:_Tint("target") end)
    p.tokens["PLAYER_ENTERING_WORLD"] = bus:On("PLAYER_ENTERING_WORLD",  function()
        self:_HookBar("player"); self:_HookBar("target"); self:_TintAll()
    end)

    self:_TintAll()

    if not (foundPlayer or foundTarget) then
        self:LogWarn("couldn't find the player/target health bar frames to tint")
    end
end

function UnitFrames:OnDisable()
    local p = self:_p()
    local bus = ns.EventBus.Get()
    for event, token in pairs(p.tokens) do bus:Off(event, token) end
    wipe(p.tokens)
    self:_Restore("player")
    self:_Restore("target")
end

-- ---- curve + apply --------------------------------------------------------
function UnitFrames:_BuildCurve()
    local p = self:_p()
    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType((Enum.LuaCurveType and Enum.LuaCurveType.Linear) or Enum.LuaCurveType.Step)
    curve:AddPoint(0.0, colorAt(0.0))
    curve:AddPoint(0.5, colorAt(0.5))
    curve:AddPoint(1.0, colorAt(1.0))
    p.curve = curve
end

-- Hook a bar so any recolour (by Blizzard) is overridden with our HP tint.
-- Returns true if the bar was found.
function UnitFrames:_HookBar(unit)
    local bar = resolveBar(unit)
    if not bar then return false end
    if not bar.__hagUFHooked then
        bar.__hagUFHooked = true
        local module = self
        hooksecurefunc(bar, "SetStatusBarColor", function(b)
            if applying[b] then return end
            module:_Tint(unit, b)
        end)
    end
    return true
end

function UnitFrames:_Tint(unit, bar)
    if unit ~= "player" and unit ~= "target" then return end
    local p = self:_p()
    if not (p.curve and self:IsEnabled()) then return end
    if not self:GetSetting(unit) then return end
    if unit == "target" and not UnitExists("target") then return end

    bar = bar or resolveBar(unit)
    if not bar or not bar.SetStatusBarColor then return end

    local color = UnitHealthPercent(unit, false, p.curve)  -- colour holds secrets
    if not color then return end

    applying[bar] = true
    bar:SetStatusBarColor(color:GetRGB())
    applying[bar] = false
end

function UnitFrames:_TintAll()
    self:_Tint("player")
    self:_Tint("target")
end

function UnitFrames:_Restore(unit)
    local bar = resolveBar(unit)
    if bar and type(UnitFrameHealthBar_Update) == "function" then
        pcall(UnitFrameHealthBar_Update, bar, unit)  -- let Blizzard recolour now
    end
end

-- React to settings changes from the auto-generated settings page.
function UnitFrames:OnSettingChanged(key, value)
    if (key == "player" or key == "target") and value == false then
        self:_Restore(key)
    end
    self:_TintAll()
end

-- ---- registration ---------------------------------------------------------
ns.ModuleManager.Get():Register(UnitFrames:New("UnitFrames", {
    title = "Unit Frames",
    description = "Colours the player and target health bars by how much health is left.",
    defaultEnabled = true,
    color = ns.Theme.hex.win,
    settings = {
        { type = "header", text = "Health bar tint" },
        { type = "toggle", key = "player", label = "Tint player health bar", default = true },
        { type = "toggle", key = "target", label = "Tint target health bar", default = true },
        { type = "note", text = "Full health is green, fading through yellow to bright red as health drops." },
    },
}))
