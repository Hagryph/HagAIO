local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, claimLevel, adopt = _wb.unwrap, _wb.style, _wb.claimLevel, _wb.adopt

-- UI/Widgets/HitButton.lua
-- A bare, transparent CLICK target with a centred label -- the building block for pooled in-world
-- hit areas (the task tracker's remove "x" and manual-toggle rows) where a themed Button would be
-- too heavy. No backdrop, no hover chrome of its own: you wire :OnEnter/:OnLeave/:OnClick (each
-- handler is called with THIS widget) and recolour :Label() yourself. :SetData / :Data carry a small
-- payload (e.g. the owning list + a task key) so pooled instances need no per-use closures.
local HitButtonW = ns.Class.new("HitButton", FrameWidget)
function HitButtonW:Initialize(parent)
    self:_attach(CreateFrame("Button", nil, unwrap(parent)))
    local label = Widgets.Text:New(self, "", "textFaint", "GameFontHighlightSmall")
    label:SetPoint("CENTER")
    self:_p().label = label
end
function HitButtonW:Label()       return self:_p().label end
function HitButtonW:SetData(a, b)  local p = self:_p(); p.dataA, p.dataB = a, b; return self end
function HitButtonW:Data()         local p = self:_p(); return p.dataA, p.dataB end
local function bind(self, fn) return fn and function() fn(self) end or nil end
function HitButtonW:OnEnter(fn) self:_frame():SetScript("OnEnter", bind(self, fn)); return self end
function HitButtonW:OnLeave(fn) self:_frame():SetScript("OnLeave", bind(self, fn)); return self end
function HitButtonW:OnClick(fn) self:_frame():SetScript("OnClick", bind(self, fn)); return self end
function HitButtonW:ClearScripts()
    local f = self:_frame()
    f:SetScript("OnEnter", nil); f:SetScript("OnLeave", nil); f:SetScript("OnClick", nil)
    return self
end
Widgets.HitButton = HitButtonW
