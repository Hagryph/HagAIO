local addonName, ns = ...
local Class = ns.Class

-- Modules/Skins.lua
-- Skins retains the shared abstract lifecycle for future skin surfaces. The
-- only live feature today is the player's existing health-bar colour.
local Skin = Class.new("Skin", nil, { abstract = true })

function Skin:Initialize(owner)
    local p = self:_p()
    p.owner = owner
    p.loaded = false
end

function Skin:Owner() return self:_p().owner end
function Skin:IsLoaded() return self:_p().loaded end

function Skin:Load()
    local p = self:_p()
    if p.loaded then return false end
    p.loaded = true
    local ok, err = pcall(self.OnLoad, self)
    if not ok then
        pcall(self.OnUnload, self)
        p.loaded = false
        error(err, 0)
    end
    return true
end

function Skin:Unload()
    local p = self:_p()
    if not p.loaded then return false end
    local ok, err = pcall(self.OnUnload, self)
    p.loaded = false
    if not ok then error(err, 0) end
    return true
end

Skin.OnLoad = Class.abstract("OnLoad")
Skin.OnUnload = Class.abstract("OnUnload")
ns.Skin = Skin

local Skins = Class.new("Skins", ns.Module, {
    statics = {
        observing = false,
        active = nil,
    },
})
local S = Class.statics(Skins)

function Skins:Initialize(name, opts)
    Skins.super.Initialize(self, name, opts)
    local p = self:_p()
    p.playerBar = nil
    p.healthColorCurve = nil
end

function Skins:_BuildHealthColorCurve()
    local low = self:GetSetting("startColor")
    local mid = self:GetSetting("midColor")
    local full = self:GetSetting("endColor")
    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve and UnitHealthPercent and CreateColor
        and low and mid and full) then
        return nil
    end

    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Linear)
    local points = ns.ColorCurve.HealthPoints(
        { low:R(), low:G(), low:B() },
        { mid:R(), mid:G(), mid:B() },
        { full:R(), full:G(), full:B() })
    for _, point in ipairs(points) do
        curve:AddPoint(point.pos, CreateColor(point[1], point[2], point[3]))
    end
    return curve
end

-- UnitHealthPercent evaluates the curve inside the client, so its secret color
-- can be passed directly to the StatusBar color sink without Lua inspecting it.
function Skins:_UpdatePlayerHealthColor()
    local p = self:_p()
    if not (self:IsEnabled() and self:GetSetting("healthBarPlayer")
        and p.playerBar and p.healthColorCurve) then
        if p.playerBar then
            p.playerBar:SetStatusBarDesaturated(false)
            p.playerBar:SetStatusBarColor(1, 1, 1, 1)
        end
        return
    end
    local color = UnitHealthPercent("player", true, p.healthColorCurve)
    if color then
        -- Blizzard's health atlas has a baked green tint. Desaturating the
        -- existing StatusBar removes that tint without replacing its texture.
        p.playerBar:SetStatusBarDesaturated(true)
        p.playerBar:SetStatusBarColor(color:GetRGB())
    end
end

function Skins:_ObservePlayerBar(bar, unit)
    if unit == "player" and bar and bar.unitFrame == _G.PlayerFrame then
        self:_p().playerBar = bar
        self:_UpdatePlayerHealthColor()
    end
end

function Skins:OnInitialize()
    if S.observing or type(UnitFrameHealthBar_Update) ~= "function" then return end
    S.observing = true
    hooksecurefunc("UnitFrameHealthBar_Update", function(bar, unit)
        if S.active then S.active:_ObservePlayerBar(bar, unit) end
    end)
end

function Skins:OnEnable()
    S.active = self
    self:_p().healthColorCurve = self:_BuildHealthColorCurve()
    self:On("UNIT_HEALTH", function(_, unit)
        if unit == "player" then self:_UpdatePlayerHealthColor() end
    end, "player-health-color")
    self:On("UNIT_MAXHEALTH", function(_, unit)
        if unit == "player" then self:_UpdatePlayerHealthColor() end
    end, "player-health-color")
    self:_UpdatePlayerHealthColor()
end

function Skins:OnDisable()
    self:ReleaseScope("player-health-color")
    local bar = self:_p().playerBar
    if bar then
        bar:SetStatusBarDesaturated(false)
        bar:SetStatusBarColor(1, 1, 1, 1)
    end
    if S.active == self then S.active = nil end
end

function Skins:OnSettingChanged(key)
    if key == "startColor" or key == "midColor" or key == "endColor" then
        self:_p().healthColorCurve = self:_BuildHealthColorCurve()
    end
    self:_UpdatePlayerHealthColor()
end

ns.ModuleManager:Register(Skins:New("Skins", {
    title = "Skins",
    description = "Colors the player health bar.",
    defaultEnabled = true,
    color = ns.Theme.hex.accent,
    -- hag-lint-disable depcheck: DatabaseManager, EventBus
    deps = { "DatabaseManager", "EventBus" },
    settings = {
        { type = "header", text = "Health Bar" },
        { type = "toggle", key = "healthBarPlayer", label = "Player frame", default = true },
        { type = "header", text = "Health Colors" },
        { type = "color", key = "endColor", label = "Full health",
          default = ns.Color:New(0.20, 0.80, 0.20) },
        { type = "color", key = "midColor", label = "Mid health",
          default = ns.Color:New(0.95, 0.82, 0.15) },
        { type = "color", key = "startColor", label = "Low health",
          default = ns.Color:New(0.90, 0.15, 0.15) },
        { type = "note", text = "Health fades from Full at 100% through Mid to Low at 30% and below." },
    },
}))
