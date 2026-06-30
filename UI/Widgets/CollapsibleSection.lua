local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, claimLevel, adopt = _wb.unwrap, _wb.style, _wb.claimLevel, _wb.adopt

-- UI/Widgets/CollapsibleSection.lua
-- Collapsible section ("accordion"): a clickable header with a +/- chevron that
-- shows or hides a content frame full of sub-widgets. Lets a long settings page
-- compress to a short stack of category headers; expand only what you need.
-- Parent children into :GetContent(), then call :SetContentHeight(h) so the
-- section knows how tall its expanded body is. :SetOnToggle(fn) fires on every
-- expand/collapse so the page can re-stack the sections below it.
-- Methods: :GetContent() :SetContentHeight(h) :SetExpanded(b) :IsExpanded()
--          :SetOnToggle(fn)   (read current total height with :GetHeight()).
local CollapsibleSectionW = ns.Class.new("CollapsibleSection", FrameWidget)
function CollapsibleSectionW:Initialize(parent, titleText)
    local HEADER, GAP = 26, 4
    local sec = CreateFrame("Frame", nil, unwrap(parent))
    sec:SetHeight(HEADER)

    local header = CreateFrame("Button", nil, sec, "BackdropTemplate")
    header:SetHeight(HEADER)
    header:SetPoint("TOPLEFT")
    header:SetPoint("TOPRIGHT")
    style(header, "panel2", "border")

    local chevron = Widgets.Text:New(header, "+", "accent", "GameFontNormalLarge")
    chevron:SetPoint("LEFT", 10, 0)
    local label = Widgets.Text:New(header, titleText, "text", "GameFontNormal")
    label:SetPoint("LEFT", chevron, "RIGHT", 8, 0)

    local content = Widgets.Container:New(sec)
    content:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -GAP)
    content:SetPoint("RIGHT", sec, "RIGHT", 0, 0)
    content:SetHeight(1)
    content:Hide()

    local p = self:_p()
    p.content, p.contentH, p.expanded = content, 0, false
    local function apply()
        chevron:SetText(p.expanded and "-" or "+")
        content:SetShown(p.expanded)
        sec:SetHeight(p.expanded and (HEADER + GAP + p.contentH) or HEADER)
    end
    p.apply = apply

    header:SetScript("OnEnter", function() header:SetBackdropBorderColor(Theme.Unpack("accent")) end)
    header:SetScript("OnLeave", function() header:SetBackdropBorderColor(Theme.Unpack("border")) end)
    header:SetScript("OnClick", function()
        p.expanded = not p.expanded
        apply()
        if p.onToggle then p.onToggle(p.expanded) end
    end)
    p.label = label
    self:_Attach(sec)
    apply()
end
function CollapsibleSectionW:GetContent()        return self:_p().content end
function CollapsibleSectionW:SetContentHeight(h) local p = self:_p(); p.contentH = math.max(0, h or 0); p.apply(); return self end
function CollapsibleSectionW:SetExpanded(v)      local p = self:_p(); p.expanded = v and true or false; p.apply(); return self end
function CollapsibleSectionW:IsExpanded()        return self:_p().expanded end
function CollapsibleSectionW:SetOnToggle(fn)     self:_p().onToggle = fn; return self end
function CollapsibleSectionW:SetTitle(t)         self:_p().label:SetText(t); return self end
Widgets.CollapsibleSection = CollapsibleSectionW
