local addonName, ns = ...
local Theme = ns.Theme

-- UI/Widgets.lua
-- Static factory of themed building blocks (the LoL "dark + blue" language in
-- WoW frame form). Everything funnels through here so the look stays
-- consistent and the SettingsWindow reads declaratively.

ns.UI = ns.UI or {}
local Widgets = {}

-- Shared "needs a /reload to apply" flag, appended to an option's label so the
-- marker looks the same everywhere it's used.
Widgets.RELOAD_FLAG = "  |cff" .. Theme.hex.amber .. "(reload)|r"
function Widgets.FlagReload(label) return label .. Widgets.RELOAD_FLAG end

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

    local state, onToggle, enabled = false, nil, true
    local function render()
        if not enabled then  -- greyed out: dim, show state faintly, ignore input
            box:SetBackdropColor(Theme.Unpack("panel2", 0.5))
            box:SetBackdropBorderColor(Theme.Unpack("border"))
            check:SetVertexColor(0.5, 0.5, 0.5)
            check:SetShown(state)
            if label then label:SetTextColor(Theme.Unpack("textFaint")) end
            return
        end
        check:SetVertexColor(1, 1, 1)
        if label then label:SetTextColor(Theme.Unpack("text")) end
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
        if enabled and not state then box:SetBackdropBorderColor(Theme.Unpack("accent")) end
    end)
    btn:SetScript("OnLeave", render)
    btn:SetScript("OnClick", function()
        if not enabled then return end
        state = not state
        render()
        if onToggle then onToggle(state) end
    end)

    btn.SetChecked   = function(_, v) state = v and true or false; render() end
    btn.GetChecked   = function() return state end
    btn.SetOnToggle  = function(_, fn) onToggle = fn end
    btn.SetEnabled   = function(_, on) enabled = on and true or false; render() end
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

    local btns, value, onChange, enabled = {}, nil, nil, true
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
            if not enabled then return end
            value = opt.value; render()
            if onChange then onChange(value) end
        end)
        b:SetScript("OnEnter", function() if enabled and opt.value ~= value then fs:SetTextColor(Theme.Unpack("text")) end end)
        b:SetScript("OnLeave", render)

        btns[#btns + 1] = b
        x = x + w + 2
    end
    c:SetWidth(x)

    c.SetValue    = function(_, v) value = v; render() end
    c.GetValue    = function() return value end
    c.SetOnChange = function(_, fn) onChange = fn end
    c.SetEnabled  = function(_, on) enabled = on and true or false; c:SetAlpha(enabled and 1 or 0.4); render() end
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

    local cr, cg, cb, onChange, enabled = 1, 1, 1, nil, true
    local function set(r, g, b) cr, cg, cb = r, g, b; sw:SetColorTexture(r, g, b) end

    btn:SetScript("OnEnter", function() if enabled then btn:SetBackdropBorderColor(Theme.Unpack("accent")) end end)
    btn:SetScript("OnLeave", function() btn:SetBackdropBorderColor(Theme.Unpack("borderStrong")) end)
    btn:SetScript("OnClick", function()
        if not enabled then return end
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

    -- Inline reset: a small button left of the swatch that restores the default colour.
    -- Hidden until SetDefault gives it one. Fires onChange so the setting persists + applies.
    local dr, dg, db
    local reset = Widgets.TextButton(btn, "Reset")
    reset:SetPoint("RIGHT", btn, "LEFT", -8, 0)
    reset:Hide()
    reset:SetScript("OnClick", function()
        if not enabled or not dr then return end
        set(dr, dg, db)
        if onChange then onChange(dr, dg, db) end
    end)

    btn.SetColor    = function(_, r, g, b) set(r, g, b) end
    btn.GetColor    = function() return cr, cg, cb end
    btn.SetOnChange = function(_, fn) onChange = fn end
    btn.SetDefault  = function(_, r, g, b) dr, dg, db = r, g, b; reset:SetShown(enabled and r ~= nil) end
    btn.SetEnabled  = function(_, on)
        enabled = on and true or false
        btn:SetAlpha(enabled and 1 or 0.4)     -- dims the swatch + its Reset child
        reset:SetShown(enabled and dr ~= nil)  -- and hides Reset while greyed out
    end
    return btn
end

-- Dependency group: lets a settings page grey out controls whose parent option is off.
-- Add(control, predicate) registers any widget that supports :SetEnabled(bool); Refresh()
-- re-evaluates every predicate and enables/disables accordingly. Call Refresh() after a
-- parent control changes (and once after building). Controls without :SetEnabled are
-- ignored, so notes/labels can be skipped safely.
function Widgets.DependencyGroup()
    local entries = {}
    local group = {}
    function group:Add(control, predicate)
        if control and control.SetEnabled and type(predicate) == "function" then
            entries[#entries + 1] = { control = control, predicate = predicate }
        end
    end
    function group:Refresh()
        for _, e in ipairs(entries) do
            e.control:SetEnabled(e.predicate() and true or false)
        end
    end
    return group
end

-- Collapsible section ("accordion"): a clickable header with a +/- chevron that
-- shows or hides a content frame full of sub-widgets. Lets a long settings page
-- compress to a short stack of category headers; expand only what you need.
-- Parent children into :GetContent(), then call :SetContentHeight(h) so the
-- section knows how tall its expanded body is. :SetOnToggle(fn) fires on every
-- expand/collapse so the page can re-stack the sections below it.
-- Methods: :GetContent() :SetContentHeight(h) :SetExpanded(b) :IsExpanded()
--          :SetOnToggle(fn)   (read current total height with :GetHeight()).
function Widgets.CollapsibleSection(parent, titleText)
    local HEADER, GAP = 26, 4
    local sec = CreateFrame("Frame", nil, parent)
    sec:SetHeight(HEADER)

    local header = CreateFrame("Button", nil, sec, "BackdropTemplate")
    header:SetHeight(HEADER)
    header:SetPoint("TOPLEFT")
    header:SetPoint("TOPRIGHT")
    Widgets.Style(header, "panel2", "border")

    local chevron = Widgets.Text(header, "+", "accent", "GameFontNormalLarge")
    chevron:SetPoint("LEFT", 10, 0)
    local label = Widgets.Text(header, titleText, "text", "GameFontNormal")
    label:SetPoint("LEFT", chevron, "RIGHT", 8, 0)

    local content = CreateFrame("Frame", nil, sec)
    content:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -GAP)
    content:SetPoint("RIGHT", sec, "RIGHT", 0, 0)
    content:SetHeight(1)
    content:Hide()

    local expanded, contentH, onToggle = false, 0, nil
    local function apply()
        chevron:SetText(expanded and "-" or "+")
        content:SetShown(expanded)
        sec:SetHeight(expanded and (HEADER + GAP + contentH) or HEADER)
    end

    header:SetScript("OnEnter", function() header:SetBackdropBorderColor(Theme.Unpack("accent")) end)
    header:SetScript("OnLeave", function() header:SetBackdropBorderColor(Theme.Unpack("border")) end)
    header:SetScript("OnClick", function()
        expanded = not expanded
        apply()
        if onToggle then onToggle(expanded) end
    end)

    sec.GetContent       = function() return content end
    sec.SetContentHeight = function(_, h) contentH = math.max(0, h or 0); apply() end
    sec.SetExpanded      = function(_, v) expanded = v and true or false; apply() end
    sec.IsExpanded       = function() return expanded end
    sec.SetOnToggle      = function(_, fn) onToggle = fn end
    sec.SetTitle         = function(_, t) label:SetText(t) end
    apply()
    return sec
end

-- Themed single-line EditBox. `numeric` only affects which characters look valid
-- to us; we never SetNumeric (that would block decimals/negatives many CVars
-- need) -- callers validate on change. Commits on Enter or focus-loss; Esc
-- reverts. Methods: :SetValue(v) :GetValue() :SetOnChange(fn) :SetEnabled(b).
function Widgets.Input(parent, width)
    local box = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    box:SetAutoFocus(false)
    box:SetHeight(20)
    box:SetWidth(width or 90)
    Widgets.Style(box, "panel2", "borderStrong")
    box:SetFontObject("GameFontHighlightSmall")
    box:SetTextInsets(6, 6, 0, 0)
    box:SetTextColor(Theme.Unpack("text"))
    box:SetMaxLetters(0)

    local value, onChange, enabled = "", nil, true
    local function commit()
        local v = box:GetText()
        if v == value then return end
        value = v
        if onChange then onChange(v) end
    end
    box:SetScript("OnEnterPressed",    function(self) self:ClearFocus() end)  -- triggers focus-lost commit
    box:SetScript("OnEscapePressed",   function(self) self:SetText(value); self:ClearFocus() end)
    box:SetScript("OnEditFocusGained", function() box:SetBackdropBorderColor(Theme.Unpack("accent")) end)
    box:SetScript("OnEditFocusLost",   function() box:SetBackdropBorderColor(Theme.Unpack("borderStrong")); commit() end)

    box.SetValue    = function(_, v) value = tostring(v == nil and "" or v); box:SetText(value) end
    box.GetValue    = function() return box:GetText() end
    box.SetOnChange = function(_, fn) onChange = fn end
    box.SetEnabled  = function(_, on)
        enabled = on and true or false
        box:EnableMouse(enabled)
        box:EnableKeyboard(enabled)
        box:SetAlpha(enabled and 1 or 0.4)
    end
    return box
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
