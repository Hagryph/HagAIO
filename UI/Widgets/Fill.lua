local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, claimLevel, adopt = _wb.unwrap, _wb.style, _wb.claimLevel, _wb.adopt

-- UI/Widgets/Fill.lua
-- A plain SOLID-COLOUR texture region (a tint/overlay/marker). The generic way an overlay gets a
-- coloured rect without a raw :CreateTexture. Inherits TextureWidget (SetColorTexture / SetVertexColor
-- / SetTexCoord / SetDrawLayer) + base layout. opts: layer ("ARTWORK"), sublevel (0).
-- :SetColor accepts a palette key (+ alpha) OR raw r,g,b[,a].
local FillW = ns.Class.new("Fill", TextureWidget)
function FillW:Initialize(parent, opts)
    opts = opts or {}
    self:_attach(unwrap(parent):CreateTexture(nil, opts.layer or "ARTWORK", nil, opts.sublevel or 0))
end
function FillW:SetColor(r, g, b, a)
    if type(r) == "string" then self:_frame():SetColorTexture(Theme.Unpack(r, g))   -- (paletteKey [, alpha])
    else self:_frame():SetColorTexture(r, g, b, a) end
    return self
end
Widgets.Fill = FillW
