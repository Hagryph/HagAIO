local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, claimLevel, adopt = _wb.unwrap, _wb.style, _wb.claimLevel, _wb.adopt

-- UI/Widgets/Toggle.lua
-- Themed checkbox. Methods: :SetChecked(bool) :GetChecked() :SetOnToggle(fn) :SetEnabled(bool).
local ToggleW = ns.Class.new("Toggle", FrameWidget)
function ToggleW:Initialize(parent, labelText)
    local rawParent = unwrap(parent)
    local btn = CreateFrame("Button", nil, rawParent)
    btn:SetSize(18, 18)

    local box = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    box:SetAllPoints()
    style(box, "panel2", "borderStrong")

    local check = box:CreateTexture(nil, "OVERLAY")
    check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    check:SetPoint("CENTER")
    check:SetSize(20, 20)
    check:Hide()

    local label
    if labelText then
        label = Widgets.Text:New(rawParent, labelText, "text", "GameFontHighlight")
        label:SetPoint("LEFT", btn, "RIGHT", 8, 0)
    end

    local p = self:_p()
    p.state, p.enabled = false, true
    local function render()
        if not p.enabled then  -- greyed out: dim, show state faintly, ignore input
            box:SetBackdropColor(Theme.Unpack("panel2", 0.5))
            box:SetBackdropBorderColor(Theme.Unpack("border"))
            check:SetVertexColor(0.5, 0.5, 0.5)
            check:SetShown(p.state)
            if label then label:SetTextColor(Theme.Unpack("textFaint")) end
            return
        end
        check:SetVertexColor(1, 1, 1)
        if label then label:SetTextColor(Theme.Unpack("text")) end
        if p.state then
            box:SetBackdropColor(Theme.Unpack("accent", 0.85))
            box:SetBackdropBorderColor(Theme.Unpack("accent"))
            check:Show()
        else
            box:SetBackdropColor(Theme.Unpack("panel2"))
            box:SetBackdropBorderColor(Theme.Unpack("borderStrong"))
            check:Hide()
        end
    end
    p.render = render

    btn:SetScript("OnEnter", function()
        if p.enabled and not p.state then box:SetBackdropBorderColor(Theme.Unpack("accent")) end
    end)
    btn:SetScript("OnLeave", render)
    btn:SetScript("OnClick", function()
        if not p.enabled then return end
        p.state = not p.state
        render()
        if p.onToggle then p.onToggle(p.state) end
    end)

    self:_attach(btn)
    render()
end
function ToggleW:SetChecked(v)   local p = self:_p(); p.state = v and true or false; p.render(); return self end
function ToggleW:GetChecked()    return self:_p().state end
function ToggleW:SetOnToggle(fn) self:_p().onToggle = fn; return self end
function ToggleW:SetEnabled(on)  local p = self:_p(); p.enabled = on and true or false; p.render(); return self end
Widgets.Toggle = ToggleW
