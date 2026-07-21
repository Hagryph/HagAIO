local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, adopt = _wb.unwrap, _wb.style, _wb.adopt

-- UI/Widgets/ProgressBar.lua
-- A themed horizontal progress bar (a StatusBar with an accent fill over a panel2 track). 0..1 value.
-- Methods: :SetValue(frac) :SetColor(key) (accent by default).  opts: height (10), bgKey ("panel2").
local ProgressBarW = ns.Class.new("ProgressBar", FrameWidget)
function ProgressBarW:Initialize(parent, opts)
    opts = opts or {}
    local bar = CreateFrame("StatusBar", nil, unwrap(parent))
    bar:SetHeight(opts.height or 10)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    bar:GetStatusBarTexture():SetVertexColor(Theme.Unpack(opts.fillKey or "accent"))
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(Theme.Unpack(opts.bgKey or "control"))
    local sheen = bar:CreateTexture(nil, "OVERLAY")
    sheen:SetPoint("TOPLEFT"); sheen:SetPoint("TOPRIGHT"); sheen:SetHeight(1)
    sheen:SetColorTexture(Theme.Unpack("highlight"))
    self:_Attach(bar)
end
function ProgressBarW:SetValue(frac) self:_Frame():SetValue(math.max(0, math.min(1, frac or 0))); return self end
function ProgressBarW:SetColor(key)  self:_Frame():GetStatusBarTexture():SetVertexColor(Theme.Unpack(key or "accent")); return self end
Widgets.ProgressBar = ProgressBarW
