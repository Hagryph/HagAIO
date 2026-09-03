local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, adopt = _wb.unwrap, _wb.style, _wb.adopt

-- UI/Widgets/ActionButtonGlow.lua
-- One colour-accurate action-button outline with three presentation effects. The root frame's alpha
-- is deliberately never animated: ActionBars can feed a SECRET alpha directly into that sanctioned
-- visual sink while the ordinary child-frame animations provide the pulse/flash treatment.
local ActionButtonGlowW = ns.Class.new("ActionButtonGlow", FrameWidget)

function ActionButtonGlowW:_CreateEdges(parent, thickness)
    local edges = {}
    local function edge()
        local texture = parent:CreateTexture(nil, "OVERLAY", nil, 7)
        texture:SetBlendMode("ADD")
        edges[#edges + 1] = texture
        return texture
    end

    local top = edge()
    top:SetPoint("TOPLEFT")
    top:SetPoint("TOPRIGHT")
    top:SetHeight(thickness)

    local bottom = edge()
    bottom:SetPoint("BOTTOMLEFT")
    bottom:SetPoint("BOTTOMRIGHT")
    bottom:SetHeight(thickness)

    local left = edge()
    left:SetPoint("TOPLEFT", 0, -thickness)
    left:SetPoint("BOTTOMLEFT", 0, thickness)
    left:SetWidth(thickness)

    local right = edge()
    right:SetPoint("TOPRIGHT", 0, -thickness)
    right:SetPoint("BOTTOMRIGHT", 0, thickness)
    right:SetWidth(thickness)

    return edges
end

function ActionButtonGlowW:_CreatePulse(target)
    local group = target:CreateAnimationGroup()
    group:SetLooping("BOUNCE")
    local alpha = group:CreateAnimation("Alpha")
    alpha:SetOrder(1)
    return group, alpha
end

function ActionButtonGlowW:Initialize(parent, target)
    parent, target = unwrap(parent), unwrap(target or parent)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetPoint("TOPLEFT", target, "TOPLEFT", -4, 4)
    frame:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", 4, -4)
    if parent.GetFrameLevel then frame:SetFrameLevel(parent:GetFrameLevel() + 8) end
    frame:EnableMouse(false)
    frame:Hide()
    self:_Attach(frame)

    local halo = CreateFrame("Frame", nil, frame)
    halo:SetAllPoints()
    local core = CreateFrame("Frame", nil, frame)
    core:SetPoint("TOPLEFT", 3, -3)
    core:SetPoint("BOTTOMRIGHT", -3, 3)

    local p = self:_p()
    p.halo = halo
    p.core = core
    p.haloEdges = self:_CreateEdges(halo, 3)
    p.coreEdges = self:_CreateEdges(core, 2)
    p.haloPulse, p.haloAlpha = self:_CreatePulse(halo)
    p.corePulse, p.coreAlpha = self:_CreatePulse(core)
    p.effect = ns.ActionButtonGlowEffect.PULSE
    self:SetColor(Theme.rgb.accent)
end

function ActionButtonGlowW:_StopEffect()
    local p = self:_p()
    p.haloPulse:Stop()
    p.corePulse:Stop()
end

function ActionButtonGlowW:_Play(group, alpha, fromAlpha, toAlpha, duration)
    alpha:SetFromAlpha(fromAlpha)
    alpha:SetToAlpha(toAlpha)
    alpha:SetDuration(duration)
    group:Play()
end

function ActionButtonGlowW:_ApplyEffect()
    local p = self:_p()
    self:_StopEffect()
    if p.effect == ns.ActionButtonGlowEffect.STEADY then
        p.core:SetAlpha(1)
        p.halo:SetAlpha(0.28)
    elseif p.effect == ns.ActionButtonGlowEffect.FLASH then
        p.core:SetAlpha(0.30)
        p.halo:SetAlpha(0)
        self:_Play(p.corePulse, p.coreAlpha, 0.30, 1.00, 0.22)
        self:_Play(p.haloPulse, p.haloAlpha, 0.00, 0.90, 0.22)
    else
        p.core:SetAlpha(1)
        p.halo:SetAlpha(0.12)
        self:_Play(p.haloPulse, p.haloAlpha, 0.12, 0.78, 0.65)
    end
end

function ActionButtonGlowW:SetEffect(effect)
    assert(ns.Enum.has(ns.ActionButtonGlowEffect, effect), "ActionButtonGlow:SetEffect: unknown effect")
    local p = self:_p()
    if p.effect == effect then return self end
    p.effect = effect
    if self:_Frame():IsShown() then self:_ApplyEffect() end
    return self
end

function ActionButtonGlowW:SetColor(color)
    assert(ns.Color.Is(color), "ActionButtonGlow:SetColor: color must be an ns.Color")
    local r, g, b, a = color:Unpack()
    local p = self:_p()
    for _, edge in ipairs(p.haloEdges) do edge:SetColorTexture(r, g, b, a) end
    for _, edge in ipairs(p.coreEdges) do edge:SetColorTexture(r, g, b, a) end
    return self
end

function ActionButtonGlowW:Show()
    local frame = self:_Frame()
    if frame:IsShown() then return self end
    frame:Show()
    self:_ApplyEffect()
    return self
end

function ActionButtonGlowW:Hide()
    local frame = self:_Frame()
    if not frame:IsShown() then return self end
    self:_StopEffect()
    frame:Hide()
    return self
end

Widgets.ActionButtonGlow = ActionButtonGlowW
