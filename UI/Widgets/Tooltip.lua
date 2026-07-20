local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, adopt = _wb.unwrap, _wb.style, _wb.adopt

-- UI/Widgets/Tooltip.lua
-- The shared HagAIO icon tooltip (addon-compartment + minimap buttons). UNLIKE the other widgets it
-- owns no frame of its own: it ADOPTS the game's single shared GameTooltip, so all access to that
-- global goes through one place (the icon services no longer poke GameTooltip directly). Exposed as a
-- SINGLETON instance Widgets.Tooltip; :Show(owner, lines) populates it, :Hide() (from the base) hides
-- it. lines = { { text, key }, ... } coloured from the Theme palette (key defaults to "textDim").
local TooltipW = ns.Class.new("Tooltip", FrameWidget)
function TooltipW:Initialize() self:_Attach(GameTooltip) end   -- adopt the shared Blizzard tooltip
function TooltipW:Show(owner, lines)
    local tt = self:_Frame()
    tt:SetOwner(unwrap(owner), "ANCHOR_LEFT")
    tt:AddLine(Theme.Colorize("accent", "HagAIO"))
    for _, ln in ipairs(lines or {}) do
        local r, g, b = Theme.Unpack(ln.key or "textDim")
        tt:AddLine(ln.text, r, g, b)
    end
    tt:Show()
    return self
end
-- :Hide is inherited from the base (GameTooltip:Hide()).
Widgets.Tooltip = TooltipW:New()   -- one instance over the one shared GameTooltip
