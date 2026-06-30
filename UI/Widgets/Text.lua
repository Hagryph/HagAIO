local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, claimLevel, adopt = _wb.unwrap, _wb.style, _wb.claimLevel, _wb.adopt

-- UI/Widgets/Text.lua
local TextW = ns.Class.new("Text", TextWidget)
function TextW:Initialize(parent, text, key, template)
    local fs = unwrap(parent):CreateFontString(nil, "ARTWORK", template or "GameFontHighlight")
    fs:SetText(text or "")
    fs:SetTextColor(Theme.Unpack(key or "text"))
    self:_Attach(fs)
end
Widgets.Text = TextW
