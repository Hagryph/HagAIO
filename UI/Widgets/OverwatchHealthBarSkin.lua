local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, adopt = _wb.unwrap, _wb.style, _wb.adopt

-- UI/Widgets/OverwatchHealthBarSkin.lua
-- Visual skin for Blizzard's player health StatusBar. It deliberately leaves the
-- bar's value, min/max, text, heal prediction and absorb layers under Blizzard's
-- control. The widget only desaturates/tints the existing fill and adds percentage
-- segments, a cyan baseline and a short secret-independent health-change flash.
--
-- Overwatch uses one block per 25 HP. WoW health pools scale by orders of
-- magnitude, so ten equal blocks preserve the same glanceable rhythm as deciles.
local OverwatchHealthBarSkinW = ns.Class.new("OverwatchHealthBarSkin", FrameWidget, {
    statics = {
        segmentCount = 10,
        separatorWidth = 2,
    },
})
local S = ns.Class.statics(OverwatchHealthBarSkinW)

function OverwatchHealthBarSkinW:Initialize(bar)
    local controller = CreateFrame("Frame", nil, unwrap(bar))
    controller:SetAllPoints(bar)
    self:_Attach(controller)

    local p = self:_p()
    p.bar = bar
    p.fill = bar.GetStatusBarTexture and bar:GetStatusBarTexture()
    p.applied = false
    p.animated = true
    p.disposed = false
    p.regions = {}
    p.separators = {}

    local track = bar:CreateTexture(nil, "BACKGROUND", nil, 5)
    track:SetAllPoints(bar)
    track:SetColorTexture(0.025, 0.035, 0.050, 0.82)
    p.track = track
    p.regions[#p.regions + 1] = track

    local baseline = bar:CreateTexture(nil, "ARTWORK", nil, 7)
    baseline:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, 1)
    baseline:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", 0, 1)
    baseline:SetHeight(2)
    baseline:SetColorTexture(Theme.Unpack("accent"))
    p.baseline = baseline
    p.regions[#p.regions + 1] = baseline

    for i = 1, S.segmentCount - 1 do
        local separator = bar:CreateTexture(nil, "ARTWORK", nil, 7)
        separator:SetWidth(S.separatorWidth)
        separator:SetColorTexture(0.025, 0.035, 0.050, 0.95)
        p.separators[i] = separator
        p.regions[#p.regions + 1] = separator
    end

    -- The flash is anchored directly to Blizzard's fill texture. The engine moves
    -- that edge from the secret health value; Lua never reads, compares or scales it.
    if p.fill then
        local pulse = bar:CreateTexture(nil, "ARTWORK", nil, 6)
        pulse:SetPoint("TOPLEFT", p.fill, "TOPLEFT", 0, 0)
        pulse:SetPoint("BOTTOMRIGHT", p.fill, "BOTTOMRIGHT", 0, 0)
        pulse:SetColorTexture(Theme.Unpack("accent"))
        pulse:SetBlendMode("ADD")
        pulse:SetAlpha(0)
        p.pulse = pulse
        p.regions[#p.regions + 1] = pulse

        local group = pulse:CreateAnimationGroup()
        local rise = group:CreateAnimation("Alpha")
        rise:SetFromAlpha(0)
        rise:SetToAlpha(0.72)
        rise:SetDuration(0.07)
        rise:SetOrder(1)
        local fall = group:CreateAnimation("Alpha")
        fall:SetFromAlpha(0.72)
        fall:SetToAlpha(0)
        fall:SetDuration(0.28)
        fall:SetOrder(2)
        p.pulseAnimation = group
    end

    controller:HookScript("OnSizeChanged", function(_, width)
        self:_Layout(width)
    end)
    self:_Layout(controller:GetWidth())
    self:_SetRegionsShown(false)
end

function OverwatchHealthBarSkinW:_SetRegionsShown(shown)
    for _, region in ipairs(self:_p().regions) do
        region:SetShown(shown)
    end
end

function OverwatchHealthBarSkinW:_Layout(width)
    if width == nil or (issecretvalue and issecretvalue(width)) then return end
    if width <= 0 then return end
    local p = self:_p()
    for i, separator in ipairs(p.separators) do
        local x = width * i / S.segmentCount
        separator:ClearAllPoints()
        separator:SetPoint("TOP", p.bar, "TOPLEFT", x, 0)
        separator:SetPoint("BOTTOM", p.bar, "BOTTOMLEFT", x, 0)
    end
end

function OverwatchHealthBarSkinW:Apply()
    local p = self:_p()
    if p.applied then return self end
    p.applied = true
    if p.fill and p.fill.SetDesaturated then p.fill:SetDesaturated(true) end
    if p.bar.SetStatusBarColor then p.bar:SetStatusBarColor(1, 1, 1, 1) end
    self:_SetRegionsShown(true)
    if p.pulse then p.pulse:SetAlpha(0) end
    return self
end

function OverwatchHealthBarSkinW:SetAnimated(animated)
    local p = self:_p()
    p.animated = animated and true or false
    if not p.animated and p.pulseAnimation then
        p.pulseAnimation:Stop()
        p.pulse:SetAlpha(0)
    end
    return self
end

function OverwatchHealthBarSkinW:Pulse()
    local p = self:_p()
    if not (p.applied and p.animated and p.pulseAnimation) then return self end
    p.pulseAnimation:Stop()
    p.pulse:SetAlpha(0)
    p.pulseAnimation:Play()
    return self
end

function OverwatchHealthBarSkinW:Restore()
    local p = self:_p()
    if p.pulseAnimation then p.pulseAnimation:Stop() end
    if p.pulse then p.pulse:SetAlpha(0) end
    self:_SetRegionsShown(false)
    if p.fill and p.fill.SetDesaturated then p.fill:SetDesaturated(false) end
    if p.bar.SetStatusBarColor then p.bar:SetStatusBarColor(1, 1, 1, 1) end
    p.applied = false
    return self
end

function OverwatchHealthBarSkinW:Dispose()
    local p = self:_p()
    if p.disposed then return end
    p.disposed = true
    self:Restore()
    OverwatchHealthBarSkinW.super.Dispose(self)
end

Widgets.OverwatchHealthBarSkin = OverwatchHealthBarSkinW
