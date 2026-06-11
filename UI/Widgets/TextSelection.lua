local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, claimLevel, adopt = _wb.unwrap, _wb.style, _wb.claimLevel, _wb.adopt

-- UI/Widgets/TextSelection.lua
-- PER-CHARACTER text selection over plain Text widgets, with NORMAL Ctrl+C -- the behaviour a real
-- text surface has, hand-built from what WoW actually offers (fontstrings have no selection or hit
-- testing, and the OS clipboard is only reachable through a FOCUSED EditBox receiving a real
-- Ctrl+C):
--   * CHARACTER HIT TESTING: a hidden measuring fontstring (same font as each line) binary-
--     searches the cursor x over codepoint-prefix widths. Prefixes are measured on the line's
--     PLAIN text -- colour escapes render zero-width, so plain-text widths match the coloured
--     display exactly, and the maths can never cut an escape (or a UTF-8 sequence) in half.
--   * SELECTION: press-drag across any of the registered lines paints translucent accent bars
--     from the anchor character to the cursor character (full rows in between) -- selection spans
--     Text widgets freely.
--   * COPY: a 1px invisible EditBox holds the selected plain text. It takes keyboard FOCUS ONLY
--     WHILE CTRL IS HELD (MODIFIER_STATE_CHANGED), pre-highlighted -- so Ctrl+C copies natively,
--     and the keyboard is completely untouched the rest of the time (no window, no focus theft).
--   local sel = Widgets.TextSelection:New(parent, { onSelect = function(text) end })  -- both optional
--   sel:SetLines({ { region = <Text widget | fontstring>, text = "plain line text" }, ... })
-- Lines must be SINGLE-ROW (no word wrap) -- x maths has no row model. Re-call SetLines whenever
-- the lines re-render; that clears the selection.
local TextSelectionW = ns.Class.new("TextSelection", FrameWidget)

-- Byte offsets of each UTF-8 codepoint START in s (plus #s as the final prefix), so prefix cuts
-- can only land on character boundaries.
local function codepointOffsets(s)
    local offs, i, n = {}, 1, #s
    while i <= n do
        local b = s:byte(i)
        local step = (b < 0x80 and 1) or (b < 0xE0 and 2) or (b < 0xF0 and 3) or 4
        i = i + step
        offs[#offs + 1] = math.min(i - 1, n)   -- prefix length ENDING at this codepoint
    end
    return offs
end

function TextSelectionW:Initialize(parent, opts)
    opts = opts or {}
    local host = unwrap(parent)
    local f = CreateFrame("Frame", nil, host)
    f:SetAllPoints(host)
    f:EnableMouse(true)
    local p = self:_p()
    p.lines, p.marks = {}, {}
    p.onSelect = opts.onSelect

    -- the clipboard surface: invisible, mouse-inert, focused ONLY while Ctrl is held
    local eb = CreateFrame("EditBox", nil, f)
    eb:SetSize(1, 1)
    eb:SetPoint("TOPLEFT")
    eb:SetAlpha(0)
    eb:SetAutoFocus(false)
    eb:EnableMouse(false)
    eb:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
    eb:SetScript("OnEscapePressed", function() eb:ClearFocus() end)
    p.eb = eb

    -- the measuring fontstring: set to a line's font + a PLAIN prefix to learn its pixel width
    local meas = f:CreateFontString(nil, "ARTWORK")
    meas:Hide()
    local function widthOf(l, prefixLen)
        local font, size, flags = l.region:GetFont()
        if font then meas:SetFont(font, size, flags) end
        meas:SetText(prefixLen >= #l.text and l.text or l.text:sub(1, prefixLen))
        return meas:GetStringWidth() or 0
    end

    -- cursor -> (line index, prefix length at the cursor) -- nil when over no line
    local function hit()
        local cx, cy = GetCursorPosition()
        for i, l in ipairs(p.lines) do
            local r = l.region
            if r:IsVisible() and r:GetLeft() then
                local scale = r:GetEffectiveScale()
                local x, y = cx / scale, cy / scale
                if y <= r:GetTop() and y >= r:GetBottom() and x >= r:GetLeft() - 4 and x <= r:GetRight() + 4 then
                    local xRel = x - r:GetLeft()
                    if xRel <= 0 then return i, 0 end
                    l.offs = l.offs or codepointOffsets(l.text)
                    local offs = l.offs
                    if #offs == 0 or xRel >= widthOf(l, #l.text) then return i, #l.text end
                    -- binary search: the largest codepoint prefix not wider than the cursor x
                    local lo, hi = 0, #offs
                    while lo < hi do
                        local mid = math.floor((lo + hi + 1) / 2)
                        if widthOf(l, offs[mid]) <= xRel then lo = mid else hi = mid - 1 end
                    end
                    return i, lo == 0 and 0 or offs[lo]
                end
            end
        end
    end

    local function ordered()
        local a, c = p.anchor, p.cur
        if not (a and c) then return end
        if c.line < a.line or (c.line == a.line and c.ch < a.ch) then a, c = c, a end
        return a, c
    end

    -- paint accent bars from anchor to cursor: partial first/last rows, full rows between
    local function paint()
        local a, c = ordered()
        for i = 1, math.max(#p.lines, #p.marks) do
            local m = p.marks[i]
            local l = p.lines[i]
            if a and l and i >= a.line and i <= c.line then
                local x1 = (i == a.line) and widthOf(l, a.ch) or 0
                local x2 = (i == c.line) and widthOf(l, c.ch) or widthOf(l, #l.text)
                if not m then
                    m = f:CreateTexture(nil, "BACKGROUND")
                    m:SetColorTexture(Theme.Unpack("accent", 0.25))
                    p.marks[i] = m
                end
                m:ClearAllPoints()
                m:SetPoint("TOPLEFT", l.region, "TOPLEFT", x1, 1)
                m:SetPoint("BOTTOMLEFT", l.region, "BOTTOMLEFT", x1, -1)
                m:SetWidth(math.max(1, x2 - x1))
                m:Show()
            elseif m then
                m:Hide()
            end
        end
    end
    p.paint = paint

    local function selectedText()
        local a, c = ordered()
        if not a then return "" end
        if a.line == c.line then return p.lines[a.line].text:sub(a.ch + 1, c.ch) end
        local out = { p.lines[a.line].text:sub(a.ch + 1) }
        for i = a.line + 1, c.line - 1 do out[#out + 1] = p.lines[i].text end
        out[#out + 1] = p.lines[c.line].text:sub(1, c.ch)
        return table.concat(out, "\n")
    end

    f:SetScript("OnMouseDown", function()
        local li, ch = hit()
        p.anchor = li and { line = li, ch = ch } or nil
        p.cur = p.anchor
        p.selected = nil
        paint()
        if p.anchor then
            f:SetScript("OnUpdate", function()
                local i, k = hit()
                if i and (not p.cur or i ~= p.cur.line or k ~= p.cur.ch) then
                    p.cur = { line = i, ch = k }
                    paint()
                end
            end)
        end
    end)
    f:SetScript("OnMouseUp", function()
        f:SetScript("OnUpdate", nil)
        local text = selectedText()
        p.selected = (text ~= "") and text or nil
        if p.selected and p.onSelect then p.onSelect(p.selected) end
    end)

    -- Ctrl down + a live selection -> the invisible EditBox takes focus pre-highlighted, so the
    -- C of Ctrl+C lands there and copies natively. Ctrl up -> focus released immediately.
    f:RegisterEvent("MODIFIER_STATE_CHANGED")
    f:SetScript("OnEvent", function(_, _, key, down)
        if key ~= "LCTRL" and key ~= "RCTRL" then return end
        if down == 1 then
            if p.selected and f:IsVisible() then
                eb:SetText(p.selected)
                eb:SetFocus()
                eb:HighlightText()
            end
        elseif eb:HasFocus() then
            eb:ClearFocus()
        end
    end)
    f:SetScript("OnHide", function()
        f:SetScript("OnUpdate", nil)
        p.anchor, p.cur, p.selected = nil, nil, nil
        paint()
        if eb:HasFocus() then eb:ClearFocus() end
    end)
    self:_attach(f)
end

-- Register the selectable lines: { region = <Text widget | fontstring>, text = "plain line text" }
-- (the text WITHOUT colour escapes -- it drives both the hit maths and what Ctrl+C copies).
-- Call again whenever the lines re-render (regions are pooled/reused); clears any selection.
function TextSelectionW:SetLines(lines)
    local p = self:_p()
    p.lines = {}
    for i, l in ipairs(lines or {}) do
        p.lines[i] = { region = unwrap(l.region), text = tostring(l.text or "") }
    end
    p.anchor, p.cur, p.selected = nil, nil, nil
    p.paint()
    return self
end

function TextSelectionW:ClearSelection()
    local p = self:_p()
    p.anchor, p.cur, p.selected = nil, nil, nil
    p.paint()
    return self
end
Widgets.TextSelection = TextSelectionW
