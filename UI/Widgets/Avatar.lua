local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, claimLevel, adopt = _wb.unwrap, _wb.style, _wb.claimLevel, _wb.adopt

-- UI/Widgets/Avatar.lua
-- A framed portrait/avatar: a themed bordered box whose texture fills it (inset by the border),
-- with the portrait's baked-in ring trimmed. The single place unit/character portraits are built,
-- so no surface hand-rolls its own frame+texture. Sized square to `size` if given; anchor like any
-- widget. Methods: :SetPortrait(unit) (live unit portrait) :SetTexture(file) (an explicit image).
local AvatarW = ns.Class.new("Avatar", FrameWidget)
function AvatarW:Initialize(parent, size)
    local f = CreateFrame("Frame", nil, unwrap(parent), "BackdropTemplate")
    style(f, "panel2", "borderStrong")
    if size then f:SetSize(size, size) end
    local tex = f:CreateTexture(nil, "ARTWORK")   -- above the backdrop fill so it's never hidden
    tex:SetPoint("TOPLEFT", 2, -2)
    tex:SetPoint("BOTTOMRIGHT", -2, 2)
    tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)        -- trim the portrait's baked-in ring
    self:_attach(f)
    self:_p().tex = tex
end
function AvatarW:SetPortrait(unit) if SetPortraitTexture then SetPortraitTexture(self:_p().tex, unit) end; return self end
function AvatarW:SetTexture(file)  self:_p().tex:SetTexture(file); return self end
Widgets.Avatar = AvatarW
