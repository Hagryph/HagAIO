local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, claimLevel, adopt = _wb.unwrap, _wb.style, _wb.claimLevel, _wb.adopt

-- UI/Widgets/TextSelection.lua
-- SELECTION over PLAIN text. WoW fontstrings cannot be selected natively, so this widget builds
-- it by hand: an invisible capture surface laid over a stack of registered text LINES. Press-drag
-- highlights the spanned lines (LINE granularity -- display strings carry colour escapes, so
-- character maths would lie about what's under the cursor), and releasing hands the selected
-- PLAIN text to onSelect. The default onSelect opens the shared CopyWindow focused +
-- pre-highlighted for Ctrl+C -- the only road to the OS clipboard WoW allows.
--   local sel = Widgets.TextSelection:New(parent, { title = "Log", onSelect = function(text) end })
--   sel:SetLines({ { region = <Text widget | fontstring>, text = "plain copy text" }, ... })
-- The capture frame anchors itself over `parent`; re-call SetLines whenever the lines re-render.
local TextSelectionW = ns.Class.new("TextSelection", FrameWidget)
function TextSelectionW:Initialize(parent, opts)
    opts = opts or {}
    local host = unwrap(parent)
    local f = CreateFrame("Frame", nil, host)
    f:SetAllPoints(host)
    f:EnableMouse(true)
    local p = self:_p()
    p.lines, p.marks = {}, {}
    p.title = opts.title or "Copy"
    p.onSelect = opts.onSelect

    local function lineAt()
        for i, l in ipairs(p.lines) do
            if l.region:IsVisible() and l.region:IsMouseOver() then return i end
        end
    end

    -- paint the [a..b] line range (nil clears); one lazy highlight texture per line slot
    local function paint(a, b)
        local lo = a and math.min(a, b or a)
        local hi = a and math.max(a, b or a)
        for i = 1, math.max(#p.lines, #p.marks) do
            local m = p.marks[i]
            if lo and i >= lo and i <= hi and p.lines[i] then
                if not m then
                    m = f:CreateTexture(nil, "BACKGROUND")
                    m:SetColorTexture(Theme.Unpack("accent", 0.16))
                    p.marks[i] = m
                end
                m:ClearAllPoints()
                m:SetPoint("TOPLEFT", p.lines[i].region, "TOPLEFT", -2, 1)
                m:SetPoint("BOTTOMRIGHT", p.lines[i].region, "BOTTOMRIGHT", 2, -1)
                m:Show()
            elseif m then
                m:Hide()
            end
        end
    end
    p.paint = paint

    f:SetScript("OnMouseDown", function()
        p.anchor = lineAt()
        p.cur = p.anchor
        paint(p.anchor, p.cur)
        if p.anchor then                              -- track the drag only while something's anchored
            f:SetScript("OnUpdate", function()
                local i = lineAt()
                if i and i ~= p.cur then p.cur = i; paint(p.anchor, p.cur) end
            end)
        end
    end)
    f:SetScript("OnMouseUp", function()
        f:SetScript("OnUpdate", nil)
        if not p.anchor then return end
        local lo, hi = math.min(p.anchor, p.cur or p.anchor), math.max(p.anchor, p.cur or p.anchor)
        p.anchor = nil
        local out = {}
        for i = lo, hi do out[#out + 1] = (p.lines[i] and p.lines[i].text) or "" end
        local text = table.concat(out, "\n")
        if text == "" then return end
        if p.onSelect then p.onSelect(text)
        else
            local cw = (ns.UI and ns.UI.CopyWindow) or ns.CopyWindow
            if cw and cw.Show then cw:Show(p.title, text) end
        end
    end)
    self:_attach(f)
end

-- Register the selectable lines: { region = <Text widget | fontstring>, text = "plain text" }.
-- Call again whenever the lines re-render (regions may be pooled/reused); clears any selection.
function TextSelectionW:SetLines(lines)
    local p = self:_p()
    p.lines = {}
    for i, l in ipairs(lines or {}) do
        p.lines[i] = { region = unwrap(l.region), text = l.text }
    end
    p.paint(nil)
    return self
end

function TextSelectionW:ClearSelection()
    self:_p().paint(nil)
    return self
end
Widgets.TextSelection = TextSelectionW
