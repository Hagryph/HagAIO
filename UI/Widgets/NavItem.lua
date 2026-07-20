local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, adopt = _wb.unwrap, _wb.style, _wb.adopt

-- UI/Widgets/NavItem.lua
-- Left-rail navigation item with active accent bar + tint. Methods:
-- :SetActive(bool). Use :SetScript("OnClick", ...) (from FrameWidget) to handle selection.
local NavItemW = ns.Class.new("NavItem", FrameWidget)
function NavItemW:Initialize(parent, text)
    local b = CreateFrame("Button", nil, unwrap(parent), "BackdropTemplate")
    b:SetHeight(34)
    b:SetBackdrop(Theme.Backdrop(1))
    b:SetBackdropColor(0, 0, 0, 0)
    b:SetBackdropBorderColor(0, 0, 0, 0)

    local bar = b:CreateTexture(nil, "OVERLAY")
    bar:SetColorTexture(Theme.Unpack("accent"))
    bar:SetPoint("TOPLEFT")
    bar:SetPoint("BOTTOMLEFT")
    bar:SetWidth(3)
    bar:Hide()

    local fs = b:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fs:SetPoint("LEFT", 14, 0)
    fs:SetText(text)
    fs:SetTextColor(Theme.Unpack("textDim"))

    local p = self:_p()
    p.active = false
    local function render()
        if p.active then
            b:SetBackdropColor(Theme.Unpack("accentSoft"))
            fs:SetTextColor(Theme.Unpack("accent"))
            bar:Show()
        else
            b:SetBackdropColor(0, 0, 0, 0)
            fs:SetTextColor(Theme.Unpack("textDim"))
            bar:Hide()
        end
    end
    p.render = render
    b:SetScript("OnEnter", function()
        if not p.active then
            b:SetBackdropColor(Theme.Unpack("panel2"))
            fs:SetTextColor(Theme.Unpack("text"))
        end
    end)
    b:SetScript("OnLeave", render)

    self:_Attach(b)
    render()
end
function NavItemW:SetActive(v) local p = self:_p(); p.active = v and true or false; p.render(); return self end
Widgets.NavItem = NavItemW
