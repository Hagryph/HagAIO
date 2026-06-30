local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, claimLevel, adopt = _wb.unwrap, _wb.style, _wb.claimLevel, _wb.adopt

-- UI/Widgets/TextButton.lua
-- Inline accent text button (Clear / links). :SetText / :SetTextColor recolour the label,
-- :SetOnClick wires the click (:SetScript is also available from FrameWidget).
local TextButtonW = ns.Class.new("TextButton", FrameWidget)
function TextButtonW:Initialize(parent, text)
    local b = CreateFrame("Button", nil, unwrap(parent))
    local fs = Widgets.Text:New(b, text, "accent", "GameFontNormalSmall")
    fs:SetPoint("CENTER")
    b:SetSize(math.max(40, fs:GetStringWidth() + 12), 20)
    b:SetScript("OnEnter", function() fs:SetTextColor(Theme.Unpack("text")) end)
    b:SetScript("OnLeave", function() fs:SetTextColor(Theme.Unpack("accent")) end)
    self:_Attach(b)
    self:_p().label = fs
end
function TextButtonW:SetText(s)        self:_p().label:SetText(s);        return self end
function TextButtonW:SetTextColor(...) self:_p().label:SetTextColor(...); return self end
function TextButtonW:SetOnClick(fn)    self:_Frame():SetScript("OnClick", fn); return self end
Widgets.TextButton = TextButtonW
