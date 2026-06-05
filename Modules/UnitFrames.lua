local addonName, ns = ...
local Class = ns.Class

-- Modules/UnitFrames.lua
-- Tints the player & target health bars by remaining health: green at full,
-- through yellow, to bright red when low.
--
-- Approach (matches how unit-frame colour addons do it): hook Blizzard's own
-- per-update handler UnitFrameHealthBar_Update ONCE. It already runs on every
-- health change and sets the bar colour, so we just re-set ours right after —
-- no extra event registration, no polling. Colour comes from the Secret-Values-
-- safe colour curve (the engine evaluates the secret health for us).

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

local function apiAvailable()
    return C_CurveUtil and C_CurveUtil.CreateColorCurve and UnitHealthPercent and CreateColor
end

-- The hook is global and can't be removed, so install it once per session;
-- it stays inert while the module is disabled.
local installed = false

-- ---- lifecycle ------------------------------------------------------------
function UnitFrames:OnInitialize()
    self:_p().curve = nil
end

function UnitFrames:OnEnable()
    if not apiAvailable() then
        self:LogWarn("health-bar colouring isn't supported on this client build")
        return
    end
    self:_BuildCurve()

    if not installed then
        if type(UnitFrameHealthBar_Update) ~= "function" then
            self:LogWarn("couldn't hook the unit-frame health bar update")
            return
        end
        local module = self
        hooksecurefunc("UnitFrameHealthBar_Update", function(statusbar, unit)
            module:_Tint(statusbar, unit)
        end)
        installed = true
    end

    self:_ApplyNow()
end

function UnitFrames:OnDisable()
    self:_RestoreNow()
end

-- ---- colouring ------------------------------------------------------------
function UnitFrames:_BuildCurve()
    local p = self:_p()
    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType((Enum.LuaCurveType and Enum.LuaCurveType.Linear) or Enum.LuaCurveType.Step)
    curve:AddPoint(0.0, colorAt(0.0))
    curve:AddPoint(0.5, colorAt(0.5))
    curve:AddPoint(1.0, colorAt(1.0))
    p.curve = curve
end

-- Paint a bar's fill: desaturate the (green) atlas to greyscale so the vertex
-- colour shows the true hue, then tint. r,g,b may be secret values.
local function paint(statusbar, r, g, b)
    if not (statusbar and statusbar.GetStatusBarTexture) then return end
    local tex = statusbar:GetStatusBarTexture()
    if not tex then return end
    if tex.SetDesaturated then tex:SetDesaturated(true) end
    tex:SetVertexColor(r, g, b)
end

-- Undo the tint: re-saturate and clear the vertex colour, restoring Blizzard's
-- original atlas.
local function unpaint(statusbar)
    if not (statusbar and statusbar.GetStatusBarTexture) then return end
    local tex = statusbar:GetStatusBarTexture()
    if not tex then return end
    if tex.SetDesaturated then tex:SetDesaturated(false) end
    tex:SetVertexColor(1, 1, 1)
end

-- Called by the hook after every Blizzard health-bar update. Acts only on the
-- player/target bars; other frames pass through untouched.
function UnitFrames:_Tint(statusbar, unit)
    if unit ~= "player" and unit ~= "target" then return end
    local p = self:_p()
    p.barOf = p.barOf or {}
    p.barOf[unit] = statusbar  -- remember the REAL bar Blizzard updates
    if not self:IsEnabled() then return end
    if not self:GetSetting(unit) then return end
    local curve = p.curve
    if not curve then return end
    local color = UnitHealthPercent(unit, true, curve)  -- holds secret values
    if color then paint(statusbar, color:GetRGB()) end
end

-- Apply our tint to the bars we already know from the hook. (On first enable
-- the hook hasn't fired yet; it will apply on the next natural update.) We must
-- NOT call Blizzard's update ourselves — that taints its secret comparisons.
function UnitFrames:_ApplyNow()
    local p = self:_p()
    if not p.barOf then return end
    for unit, bar in pairs(p.barOf) do
        self:_Tint(bar, unit)
    end
end

-- Restore Blizzard's original atlas on the bars we tinted.
function UnitFrames:_RestoreNow()
    local p = self:_p()
    if not p.barOf then return end
    for _, bar in pairs(p.barOf) do
        unpaint(bar)
    end
end

function UnitFrames:OnSettingChanged()
    local p = self:_p()
    if not p.barOf then return end
    for unit, bar in pairs(p.barOf) do
        if self:GetSetting(unit) then
            self:_Tint(bar, unit)
        else
            unpaint(bar)
        end
    end
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
