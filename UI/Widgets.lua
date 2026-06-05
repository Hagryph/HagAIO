local addonName, ns = ...
local Theme = ns.Theme

-- UI/Widgets.lua
-- Static factory of themed building blocks (the LoL "dark + blue" language in
-- WoW frame form). Everything funnels through here so the look stays
-- consistent and the SettingsWindow reads declaratively.

ns.UI = ns.UI or {}
local Widgets = {}

-- Apply a solid themed backdrop + colours to a BackdropTemplate frame.
function Widgets.Style(frame, bgKey, borderKey, edgeSize)
    frame:SetBackdrop(Theme.Backdrop(edgeSize or 1))
    frame:SetBackdropColor(Theme.Unpack(bgKey or "panel"))
    frame:SetBackdropBorderColor(Theme.Unpack(borderKey or "border"))
    return frame
end

function Widgets.Panel(parent, bgKey, borderKey)
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    return Widgets.Style(f, bgKey or "panel", borderKey or "border")
end

-- 1px horizontal hairline (anchor + width set by caller).
function Widgets.Divider(parent)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetColorTexture(Theme.Unpack("border"))
    t:SetHeight(1)
    return t
end

function Widgets.Text(parent, text, key, template)
    local fs = parent:CreateFontString(nil, "ARTWORK", template or "GameFontHighlight")
    fs:SetText(text or "")
    fs:SetTextColor(Theme.Unpack(key or "text"))
    return fs
end

-- Uppercase, dim, lightly spaced section label (LoL's letter-spaced caps).
function Widgets.SectionLabel(parent, text)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    fs:SetText(string.upper(text or ""))
    fs:SetTextColor(Theme.Unpack("textFaint"))
    fs:SetSpacing(2)
    return fs
end

-- Inline accent text button (Clear / links). Returns the Button; its label is
-- at `.text`.
function Widgets.TextButton(parent, text)
    local b = CreateFrame("Button", nil, parent)
    local fs = Widgets.Text(b, text, "accent", "GameFontNormalSmall")
    fs:SetPoint("CENTER")
    b:SetSize(math.max(40, fs:GetStringWidth() + 12), 20)
    b:SetScript("OnEnter", function() fs:SetTextColor(Theme.Unpack("text")) end)
    b:SetScript("OnLeave", function() fs:SetTextColor(Theme.Unpack("accent")) end)
    b.text = fs
    return b
end

-- Themed checkbox. Methods: :SetChecked(bool) :GetChecked() :SetOnToggle(fn).
function Widgets.Toggle(parent, labelText)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(18, 18)

    local box = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    box:SetAllPoints()
    Widgets.Style(box, "panel2", "borderStrong")

    local check = box:CreateTexture(nil, "OVERLAY")
    check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    check:SetPoint("CENTER")
    check:SetSize(20, 20)
    check:Hide()

    local label
    if labelText then
        label = Widgets.Text(parent, labelText, "text", "GameFontHighlight")
        label:SetPoint("LEFT", btn, "RIGHT", 8, 0)
    end

    local state, onToggle = false, nil
    local function render()
        if state then
            box:SetBackdropColor(Theme.Unpack("accent", 0.85))
            box:SetBackdropBorderColor(Theme.Unpack("accent"))
            check:Show()
        else
            box:SetBackdropColor(Theme.Unpack("panel2"))
            box:SetBackdropBorderColor(Theme.Unpack("borderStrong"))
            check:Hide()
        end
    end

    btn:SetScript("OnEnter", function()
        if not state then box:SetBackdropBorderColor(Theme.Unpack("accent")) end
    end)
    btn:SetScript("OnLeave", render)
    btn:SetScript("OnClick", function()
        state = not state
        render()
        if onToggle then onToggle(state) end
    end)

    btn.SetChecked   = function(_, v) state = v and true or false; render() end
    btn.GetChecked   = function() return state end
    btn.SetOnToggle  = function(_, fn) onToggle = fn end
    btn.label = label
    render()
    return btn
end

-- Left-rail navigation item with active accent bar + tint. Methods:
-- :SetActive(bool). Use :SetScript("OnClick", ...) to handle selection.
function Widgets.NavItem(parent, text)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
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

    local active = false
    local function render()
        if active then
            b:SetBackdropColor(Theme.Unpack("accentSoft"))
            fs:SetTextColor(Theme.Unpack("accent"))
            bar:Show()
        else
            b:SetBackdropColor(0, 0, 0, 0)
            fs:SetTextColor(Theme.Unpack("textDim"))
            bar:Hide()
        end
    end
    b:SetScript("OnEnter", function()
        if not active then
            b:SetBackdropColor(Theme.Unpack("panel2"))
            fs:SetTextColor(Theme.Unpack("text"))
        end
    end)
    b:SetScript("OnLeave", render)

    b.SetActive = function(_, v) active = v and true or false; render() end
    render()
    return b
end

-- Segmented selector (LoL "view-switch"): a row of option buttons, active one
-- accent-highlighted. options = { { value = v, text = "..." }, ... }.
-- Methods: :SetValue(v) :GetValue() :SetOnChange(fn).
function Widgets.Segmented(parent, options)
    local c = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    Widgets.Style(c, "panel2", "border")
    c:SetHeight(24)

    local btns, value, onChange = {}, nil, nil
    local function render()
        for _, e in ipairs(btns) do
            if e.value == value then
                e.bg:Show(); e.fs:SetTextColor(Theme.Unpack("accent"))
            else
                e.bg:Hide(); e.fs:SetTextColor(Theme.Unpack("textDim"))
            end
        end
    end

    local x = 2
    for _, opt in ipairs(options) do
        local b = CreateFrame("Button", nil, c)
        local fs = Widgets.Text(b, opt.text, "textDim", "GameFontNormalSmall")
        fs:SetPoint("CENTER")
        local w = math.max(46, fs:GetStringWidth() + 18)
        b:SetSize(w, 20)
        b:SetPoint("LEFT", x, 0)

        local bg = b:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(Theme.Unpack("accentSoft"))
        bg:Hide()

        b.bg, b.fs, b.value = bg, fs, opt.value
        b:SetScript("OnClick", function()
            value = opt.value; render()
            if onChange then onChange(value) end
        end)
        b:SetScript("OnEnter", function() if opt.value ~= value then fs:SetTextColor(Theme.Unpack("text")) end end)
        b:SetScript("OnLeave", render)

        btns[#btns + 1] = b
        x = x + w + 2
    end
    c:SetWidth(x)

    c.SetValue    = function(_, v) value = v; render() end
    c.GetValue    = function() return value end
    c.SetOnChange = function(_, fn) onChange = fn end
    render()
    return c
end

-- Colour swatch button: shows the current colour, opens the Blizzard colour
-- picker on click. Methods: :SetColor(r,g,b) :GetColor() :SetOnChange(fn).
function Widgets.ColorSwatch(parent)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(26, 16)
    Widgets.Style(btn, "panel2", "borderStrong")

    local sw = btn:CreateTexture(nil, "ARTWORK")
    sw:SetPoint("TOPLEFT", 2, -2)
    sw:SetPoint("BOTTOMRIGHT", -2, 2)
    sw:SetColorTexture(1, 1, 1)

    local cr, cg, cb, onChange = 1, 1, 1, nil
    local function set(r, g, b) cr, cg, cb = r, g, b; sw:SetColorTexture(r, g, b) end

    btn:SetScript("OnEnter", function() btn:SetBackdropBorderColor(Theme.Unpack("accent")) end)
    btn:SetScript("OnLeave", function() btn:SetBackdropBorderColor(Theme.Unpack("borderStrong")) end)
    btn:SetScript("OnClick", function()
        local prevR, prevG, prevB = cr, cg, cb
        local info = {
            hasOpacity = false,
            r = cr, g = cg, b = cb,
            swatchFunc = function()
                local r, g, b = ColorPickerFrame:GetColorRGB()
                set(r, g, b)
                if onChange then onChange(r, g, b) end
            end,
            cancelFunc = function()
                set(prevR, prevG, prevB)
                if onChange then onChange(prevR, prevG, prevB) end
            end,
        }
        if ColorPickerFrame.SetupColorPickerAndShow then
            ColorPickerFrame:SetupColorPickerAndShow(info)
        else  -- legacy fallback
            ColorPickerFrame.func = info.swatchFunc
            ColorPickerFrame.cancelFunc = info.cancelFunc
            ColorPickerFrame.hasOpacity = false
            ColorPickerFrame:SetColorRGB(cr, cg, cb)
            ColorPickerFrame:Show()
        end
    end)

    btn.SetColor    = function(_, r, g, b) set(r, g, b) end
    btn.GetColor    = function() return cr, cg, cb end
    btn.SetOnChange = function(_, fn) onChange = fn end
    return btn
end

-- Named scroll frame (template needs a name for its $parentScrollBar).
function Widgets.ScrollFrame(parent, name)
    local sf = CreateFrame("ScrollFrame", name, parent, "UIPanelScrollFrameTemplate")
    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(1, 1)
    sf:SetScrollChild(content)
    sf.content = content
    return sf
end

ns.UI.Widgets = Widgets
