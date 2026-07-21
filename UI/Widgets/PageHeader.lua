local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, surface = _wb.unwrap, _wb.surface

-- UI/Widgets/PageHeader.lua
-- Application-style page heading: a raised header band with an accent rail, title, concise
-- description and a right-aligned action area. It gives every page the same hierarchy while keeping
-- page-specific buttons out of the title/description flow. Methods: :Actions() :Title() :Description().
local PageHeaderW = ns.Class.new("PageHeader", FrameWidget)

function PageHeaderW:Initialize(parent, titleText, descriptionText, opts)
    opts = opts or {}
    local h = opts.height or 72
    local f = CreateFrame("Frame", nil, unwrap(parent), "BackdropTemplate")
    f:SetHeight(h)
    surface(f, { bgKey = "surfaceRaised", borderKey = "border", accent = true,
        accentKey = opts.accentKey or "accent", shadow = opts.shadow })

    local title = Widgets.Text:New(f, string.upper(titleText or ""), opts.titleKey or "text", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 20, -15)

    local description = Widgets.Text:New(f, descriptionText or "", "textDim", "GameFontHighlightSmall")
    description:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -7)
    local actionsWidth = opts.actionsWidth or 190
    description:SetPoint("RIGHT", f, "RIGHT", -(actionsWidth + 28), 0)
    description:SetJustifyH("LEFT")
    description:SetWordWrap(false)

    local actions = Widgets.Container:New(f)
    actions:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -12)
    actions:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 12)
    actions:SetWidth(actionsWidth)

    self:_p().actions = actions
    self:_Attach(f)
end

function PageHeaderW:Actions() return self:_p().actions end

Widgets.PageHeader = PageHeaderW
