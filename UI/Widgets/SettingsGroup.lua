local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, adopt = _wb.unwrap, _wb.style, _wb.adopt

-- UI/Widgets/SettingsGroup.lua
-- A titled settings GROUP: a bordered panel with a clickable header strip (chevron + `title`) and a
-- content area below it that callers fill. COLLAPSIBLE -- clicking the header toggles the body (the
-- group shrinks to just its header when collapsed). Returns the container Frame; anchor it like any
-- widget. Methods: :GetContent() (parent your controls into it), :SetContentHeight(h) (the expanded
-- body height), :SetExpanded(bool), :IsExpanded(), :SetOnToggle(fn) fn(expanded), :SetTitle(s).
local SettingsGroupW = ns.Class.new("SettingsGroup", FrameWidget)
function SettingsGroupW:Initialize(parent, title)
    local HEADER, PAD = 24, 10
    local g = CreateFrame("Frame", nil, unwrap(parent), "BackdropTemplate")
    style(g, "panel2", "border")

    local header = CreateFrame("Button", nil, g)
    header:SetPoint("TOPLEFT", 1, -1); header:SetPoint("TOPRIGHT", -1, -1); header:SetHeight(HEADER)
    local strip = header:CreateTexture(nil, "ARTWORK"); strip:SetAllPoints(); strip:SetColorTexture(Theme.Unpack("bg1"))
    local chevron = Widgets.Text:New(header, "-", "accent", "GameFontNormal")
    chevron:SetPoint("LEFT", 8, 0)
    local label = Widgets.Text:New(header, title, "text", "GameFontNormal")
    label:SetPoint("LEFT", chevron, "RIGHT", 6, 0)

    local content = Widgets.Container:New(g)
    content:SetPoint("TOPLEFT", g, "TOPLEFT", PAD, -(HEADER + PAD))
    content:SetPoint("TOPRIGHT", g, "TOPRIGHT", -PAD, -(HEADER + PAD))
    content:SetHeight(1)

    local p = self:_p()
    p.content, p.contentH, p.expanded, p.label = content, 0, true, label
    local function apply()
        chevron:SetText(p.expanded and "-" or "+")
        content:SetShown(p.expanded)
        g:SetHeight(p.expanded and (HEADER + PAD + math.max(0, p.contentH) + PAD) or HEADER)
    end
    p.apply = apply
    header:SetScript("OnEnter", function() g:SetBackdropBorderColor(Theme.Unpack("accent")) end)
    header:SetScript("OnLeave", function() g:SetBackdropBorderColor(Theme.Unpack("border")) end)
    header:SetScript("OnClick", function()
        p.expanded = not p.expanded; apply()
        if p.onToggle then p.onToggle(p.expanded) end
    end)
    self:_Attach(g)
    apply()
end
function SettingsGroupW:GetContent()        return self:_p().content end
function SettingsGroupW:SetContentHeight(h) local p = self:_p(); p.contentH = math.max(0, h or 0); p.apply(); return self end
function SettingsGroupW:SetTitle(t)         self:_p().label:SetText(t); return self end
function SettingsGroupW:SetExpanded(v)      local p = self:_p(); p.expanded = v and true or false; p.apply(); return self end
function SettingsGroupW:IsExpanded()        return self:_p().expanded end
function SettingsGroupW:SetOnToggle(fn)     self:_p().onToggle = fn; return self end
Widgets.SettingsGroup = SettingsGroupW
