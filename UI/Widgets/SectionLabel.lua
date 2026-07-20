local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, adopt = _wb.unwrap, _wb.style, _wb.adopt

-- UI/Widgets/SectionLabel.lua
-- Uppercase, dim, lightly spaced section label (LoL's letter-spaced caps).
local SectionLabelW = ns.Class.new("SectionLabel", TextWidget)
function SectionLabelW:Initialize(parent, text)
    local fs = unwrap(parent):CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    fs:SetText(string.upper(text or ""))
    fs:SetTextColor(Theme.Unpack("textFaint"))
    fs:SetSpacing(2)
    self:_Attach(fs)
end
Widgets.SectionLabel = SectionLabelW
