local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, surface, adopt = _wb.unwrap, _wb.style, _wb.surface, _wb.adopt
local Changeable = _wb.Changeable

-- UI/Widgets/Dropdown.lua
-- HagAIO-themed dropdown with a dark popout, restrained accent state, and no
-- Blizzard visual template. Options are { { value = value, text = "Label" }, ... }.
local DropdownW = ns.Class.new("Dropdown", FrameWidget, { mixins = { Changeable } })

-- Menus are parented to UIParent so they can escape clipped/scaled settings content. Match the
-- control's effective strata and then step above its inherited level: a fixed DIALOG level renders
-- behind DIALOG-strata popups.
function DropdownW:_RaiseMenu()
    local p = self:_p()
    local strata = p.dropdown:GetFrameStrata()
    local level = p.dropdown:GetFrameLevel() + 20
    p.blocker:SetFrameStrata(strata)
    p.blocker:SetFrameLevel(level)
    p.menu:SetFrameLevel(level + 10)
end

function DropdownW:Initialize(parent, options, defaultText)
    local dropdown = CreateFrame("Button", nil, unwrap(parent), "BackdropTemplate")
    dropdown:SetSize(220, 30)
    style(dropdown, "control", "borderStrong")

    local selectedText = Widgets.Text:New(dropdown, defaultText or "Select", "textDim", "GameFontNormalSmall")
    selectedText:SetPoint("LEFT", dropdown, "LEFT", 10, 0)
    selectedText:SetPoint("RIGHT", dropdown, "RIGHT", -30, 0)
    selectedText:SetJustifyH("LEFT")

    local arrow = Widgets.Text:New(dropdown, "v", "accent", "GameFontNormalSmall")
    arrow:SetPoint("RIGHT", dropdown, "RIGHT", -10, 1)

    -- Keep the popup root on UIParent for its whole interactive lifetime. Reparenting
    -- it from this scaled settings subtree during OnClick could invalidate its
    -- effective scale/layering before the menu was drawn. Dispose reparents the
    -- hidden tree once, so the normal widget teardown can still own every child.
    local blocker = CreateFrame("Button", nil, UIParent)
    blocker:SetAllPoints(UIParent)
    blocker:EnableMouse(true)
    blocker:Hide()

    local menu = CreateFrame("Frame", nil, blocker, "BackdropTemplate")
    surface(menu, { bgKey = "surfaceRaised", borderKey = "borderStrong", shadow = true })
    menu:SetPoint("TOPLEFT", dropdown, "BOTTOMLEFT", 0, -2)
    menu:SetFrameLevel(blocker:GetFrameLevel() + 10)
    menu:SetClampedToScreen(true)
    menu:Hide()

    local p = self:_p()
    p.options = options or {}
    p.defaultText = defaultText or "Select"
    p.enabled = true
    p.open = false
    p.hovered = false
    p.selectedText = selectedText
    p.arrow = arrow
    p.dropdown = dropdown
    p.blocker = blocker
    p.menu = menu
    p.rows = {}

    local function labelFor(value)
        for _, option in ipairs(p.options) do
            if option.value == value then return option.text end
        end
        return p.defaultText
    end

    local function renderButton()
        selectedText:SetText(labelFor(p.value))
        if not p.enabled then
            dropdown:SetBackdropColor(Theme.Unpack("control", 0.5))
            dropdown:SetBackdropBorderColor(Theme.Unpack("border"))
            selectedText:SetTextColor(Theme.Unpack("textFaint"))
            arrow:SetTextColor(Theme.Unpack("textFaint"))
        elseif p.open or p.hovered then
            dropdown:SetBackdropColor(Theme.Unpack("controlHover"))
            dropdown:SetBackdropBorderColor(Theme.Unpack("accent"))
            selectedText:SetTextColor(Theme.Unpack("text"))
            arrow:SetTextColor(Theme.Unpack("accent"))
        else
            dropdown:SetBackdropColor(Theme.Unpack("control"))
            dropdown:SetBackdropBorderColor(Theme.Unpack("borderStrong"))
            selectedText:SetTextColor(Theme.Unpack("text"))
            arrow:SetTextColor(Theme.Unpack("accent"))
        end
    end

    local function renderRows()
        for _, row in ipairs(p.rows) do
            if row.value == p.value then
                row.background:SetColorTexture(Theme.Unpack("accentSoft"))
                row.background:Show()
                row.text:SetTextColor(Theme.Unpack("accent"))
            else
                row.background:Hide()
                row.text:SetTextColor(Theme.Unpack("textDim"))
            end
        end
    end
    p.renderButton = renderButton
    p.renderRows = renderRows

    local function close()
        p.open = false
        p.hovered = false
        menu:Hide()
        blocker:Hide()
        renderButton()
    end
    p.close = close

    blocker:SetScript("OnClick", close)
    for i, option in ipairs(p.options) do
        local row = CreateFrame("Button", nil, menu)
        row:SetPoint("TOPLEFT", menu, "TOPLEFT", 3, -3 - ((i - 1) * 28))
        row:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -3, -3 - ((i - 1) * 28))
        row:SetHeight(28)

        local background = row:CreateTexture(nil, "BACKGROUND")
        background:SetAllPoints()
        background:SetColorTexture(Theme.Unpack("accentSoft"))
        background:Hide()

        local text = Widgets.Text:New(row, option.text, "textDim", "GameFontNormalSmall")
        text:SetPoint("LEFT", row, "LEFT", 8, 0)
        text:SetPoint("RIGHT", row, "RIGHT", -8, 0)
        text:SetJustifyH("LEFT")

        p.rows[#p.rows + 1] = {
            button = row, background = background, text = text, value = option.value,
        }
        row:SetScript("OnEnter", function()
            background:SetColorTexture(Theme.Unpack("controlHover"))
            background:Show()
            text:SetTextColor(Theme.Unpack("text"))
        end)
        row:SetScript("OnLeave", renderRows)
        row:SetScript("OnClick", function()
            if not p.enabled then return end
            p.value = option.value
            close()
            renderRows()
            if p.onChange then p.onChange(p.value) end
            self:_FireChange(p.value)
        end)
    end

    menu:SetSize(220, (#p.options * 28) + 6)
    dropdown:SetScript("OnEnter", function() p.hovered = true; renderButton() end)
    dropdown:SetScript("OnLeave", function() p.hovered = false; renderButton() end)
    dropdown:SetScript("OnClick", function()
        if not p.enabled then return end
        if p.open then
            close()
        else
            p.open = true
            self:_RaiseMenu()
            blocker:Show()
            menu:Show()
            renderRows()
            renderButton()
        end
    end)

    self:_Attach(dropdown)
    renderRows()
    renderButton()
end

function DropdownW:SetWidth(width)
    local p = self:_p()
    self:_Frame():SetWidth(width)
    p.menu:SetWidth(width)
    return self
end

function DropdownW:SetValue(value)
    local p = self:_p()
    p.value = value
    p.renderRows()
    p.renderButton()
    self:_FireChange(value)
    return self
end

function DropdownW:GetValue() return self:_p().value end
function DropdownW:SetOnChange(fn) self:_p().onChange = fn; return self end

function DropdownW:SetEnabled(on)
    local p = self:_p()
    p.enabled = on and true or false
    if not p.enabled then p.close() end
    self:_Frame():SetAlpha(p.enabled and 1 or 0.65)
    p.renderButton()
    return self
end

function DropdownW:Dispose()
    local p = self:_p()
    if p.close then p.close() end
    if p.blocker then p.blocker:SetParent(self:_Frame()) end
    DropdownW.super.Dispose(self)
end

Widgets.Dropdown = DropdownW
