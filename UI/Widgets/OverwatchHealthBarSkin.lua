local addonName, ns = ...
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, adopt = _wb.unwrap, _wb.style, _wb.adopt

-- UI/Widgets/OverwatchHealthBarSkin.lua
-- Visual skin for Blizzard's player health StatusBar. It deliberately leaves the
-- bar's value, min/max, color, text, heal prediction and absorb layers under
-- Blizzard's control. Opaque diagonal gaps cut the existing fill into the ten
-- separate parallelogram blocks used by the reference without repainting it.
--
-- Overwatch uses one block per 25 HP. WoW health pools scale by orders of
-- magnitude, so ten equal blocks preserve the same glanceable rhythm as deciles.
local OverwatchHealthBarSkinW = ns.Class.new("OverwatchHealthBarSkin", FrameWidget, {
    statics = {
        segmentCount = 10,
        gapWidth = 3,
        gapAngle = math.rad(-12),
        gapOverdraw = 6,
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
    p.gaps = {}

    for i = 1, S.segmentCount - 1 do
        local gap = bar:CreateTexture(nil, "ARTWORK", nil, 7)
        gap:SetColorTexture(0.018, 0.022, 0.028, 1)
        gap:SetRotation(S.gapAngle)
        p.gaps[i] = gap
        p.regions[#p.regions + 1] = gap
    end

    -- The flash is anchored directly to Blizzard's fill texture. The engine moves
    -- that edge from the secret health value; Lua never reads, compares or scales it.
    if p.fill then
        local pulse = bar:CreateTexture(nil, "ARTWORK", nil, 6)
        pulse:SetPoint("TOPLEFT", p.fill, "TOPLEFT", 0, 0)
        pulse:SetPoint("BOTTOMRIGHT", p.fill, "BOTTOMRIGHT", 0, 0)
        pulse:SetColorTexture(1, 1, 1, 1)
        pulse:SetBlendMode("ADD")
        pulse:SetAlpha(0)
        p.pulse = pulse
        p.regions[#p.regions + 1] = pulse

        local group = pulse:CreateAnimationGroup()
        local rise = group:CreateAnimation("Alpha")
        rise:SetFromAlpha(0)
        rise:SetToAlpha(0.52)
        rise:SetDuration(0.07)
        rise:SetOrder(1)
        local fall = group:CreateAnimation("Alpha")
        fall:SetFromAlpha(0.52)
        fall:SetToAlpha(0)
        fall:SetDuration(0.28)
        fall:SetOrder(2)
        p.pulseAnimation = group
    end

    controller:HookScript("OnSizeChanged", function(_, width, height)
        self:_Layout(width, height)
    end)
    self:_Layout(controller:GetWidth(), controller:GetHeight())
    self:_SetRegionsShown(false)
end

function OverwatchHealthBarSkinW:_SetRegionsShown(shown)
    for _, region in ipairs(self:_p().regions) do
        region:SetShown(shown)
    end
end

function OverwatchHealthBarSkinW:_Layout(width, height)
    if width == nil or height == nil then return end
    if issecretvalue and (issecretvalue(width) or issecretvalue(height)) then return end
    if width <= 0 or height <= 0 then return end
    local p = self:_p()
    for i, gap in ipairs(p.gaps) do
        local x = width * i / S.segmentCount
        gap:ClearAllPoints()
        gap:SetSize(S.gapWidth, height + S.gapOverdraw)
        gap:SetPoint("CENTER", p.bar, "LEFT", x, 0)
    end
end

function OverwatchHealthBarSkinW:Apply()
    local p = self:_p()
    if p.applied then return self end
    p.applied = true
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
