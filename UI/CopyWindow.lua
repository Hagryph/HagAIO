local addonName, ns = ...
local Class = ns.Class
local Theme = ns.Theme
local W = ns.UI.Widgets

-- UI/CopyWindow.lua
-- A themed, reusable "copy this text out of the game" window. WoW gives addons
-- no clipboard write access, so the established pattern (used by the
-- SimulationCraft addon and others) is to drop the text into a focused,
-- multi-line EditBox with everything pre-selected, so the user just hits Ctrl+C.
--
-- A single multi-line EditBox silently renders BLANK past a certain size (tens
-- of KB), so large bodies are PAGINATED: the text is split on line boundaries
-- into pages small enough to render, with Prev/Next controls. Copying every
-- page in order and concatenating them reproduces the exact original text, so
-- callers don't have to know or care how big their text is.
--
-- It's a shared service, not tied to any one caller: Show(title, text) fills it
-- and pops it up; the title labels what's inside. Styled to match the
-- SettingsWindow (LoL dark+blue), movable, ESC-closable, single instance reused
-- across calls.
--
--   ns.UI.CopyWindow:Show("CVars (1234)", text)

local CopyWindow = Class.new("CopyWindow", ns.Service)

-- Max characters per page. A multi-line EditBox silently renders BLANK once a
-- page's text crosses an internal ceiling (~10 KB: pages packed to that size
-- blanked out intermittently). ~100 lines (≈5.5 KB) is confirmed-good, so we sit
-- safely under that. Smaller = more pages but every page reliably renders.
local PAGE_CHARS = 5000

function CopyWindow:OnInitialize()
    local p = self:_p()
    p.built = false
    p.pages = {}
    p.page = 1
end

-- ---- construction ---------------------------------------------------------
function CopyWindow:Build()
    local p = self:_p()
    if p.built then return end

    local f = CreateFrame("Frame", "HagAIOCopyWindow", UIParent, "BackdropTemplate")
    f:SetSize(560, 440)
    f:SetPoint("CENTER")
    W.Style(f, "bg1", "borderStrong")
    f:SetFrameStrata("DIALOG")  -- above the settings window, which is HIGH
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:Hide()
    tinsert(UISpecialFrames, "HagAIOCopyWindow")  -- ESC closes
    p.frame = f

    -- title bar (draggable)
    local bar = W.Panel(f, "bg0", "border")
    bar:SetHeight(38)
    bar:SetPoint("TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", -1, -1)
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", function() f:StartMoving() end)
    bar:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

    local title = W.Text(bar, "Copy", "accent", "GameFontNormalLarge")
    title:SetPoint("LEFT", 16, 0)
    p.title = title

    local close = CreateFrame("Button", nil, bar)
    close:SetSize(38, 38)
    close:SetPoint("RIGHT", 0, 0)
    local x = W.Text(close, "X", "textDim", "GameFontNormalLarge")
    x:SetPoint("CENTER")
    close:SetScript("OnEnter", function() x:SetTextColor(Theme.Unpack("red")) end)
    close:SetScript("OnLeave", function() x:SetTextColor(Theme.Unpack("textDim")) end)
    close:SetScript("OnClick", function() self:Hide() end)

    -- hint line
    local hint = W.Text(f, "Press Ctrl+C to copy, then Esc to close.", "textDim", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 16, -10)

    -- a "Select all" convenience (text is auto-selected on Show, but a click can
    -- lose the highlight). Re-focuses and re-highlights.
    local selectAll = W.TextButton(f, "Select all")
    selectAll:SetPoint("RIGHT", f, "RIGHT", -32, 0)
    selectAll:SetPoint("TOP", hint, "TOP", 0, 3)
    selectAll:SetScript("OnClick", function() self:_SelectAll() end)

    local div = W.Divider(f)
    div:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -10)
    div:SetPoint("RIGHT", f, "RIGHT", -16, 0)

    -- footer with page navigation (only shown when there's more than one page)
    local footer = CreateFrame("Frame", nil, f)
    footer:SetHeight(22)
    footer:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 12)
    footer:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 12)
    p.footer = footer

    local prev = W.TextButton(footer, "< Prev")
    prev:SetPoint("LEFT", footer, "LEFT", 0, 0)
    prev:SetScript("OnClick", function() self:_Goto(p.page - 1) end)
    p.prev = prev

    local nextBtn = W.TextButton(footer, "Next >")
    nextBtn:SetPoint("RIGHT", footer, "RIGHT", 0, 0)
    nextBtn:SetScript("OnClick", function() self:_Goto(p.page + 1) end)
    p.next = nextBtn

    local pageLabel = W.Text(footer, "", "textDim", "GameFontHighlightSmall")
    pageLabel:SetPoint("CENTER", footer, "CENTER", 0, 0)
    p.pageLabel = pageLabel

    -- bordered panel housing the scrollable edit box (bottom anchors above footer)
    local box = W.Panel(f, "panel", "border")
    box:SetPoint("TOPLEFT", div, "BOTTOMLEFT", 0, -8)
    box:SetPoint("BOTTOMRIGHT", footer, "TOPRIGHT", 0, 6)

    local sf = CreateFrame("ScrollFrame", "HagAIOCopyWindowScroll", box, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 6, -6)
    sf:SetPoint("BOTTOMRIGHT", -28, 6)  -- leave room for the scrollbar

    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)              -- don't steal focus until Show() asks
    eb:SetMaxLetters(0)                 -- 0 = unlimited; never truncate the body
    eb:SetMaxBytes(0)                   -- 0 = unlimited; same for the byte cap
    eb:SetFontObject("ChatFontNormal")
    eb:SetTextColor(Theme.Unpack("text"))
    eb:SetWidth(1)                      -- real width set when the scroll frame sizes
    eb:SetScript("OnEscapePressed", function() self:Hide() end)
    -- keep the caret/highlight from collapsing when the box is clicked: re-select all
    eb:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    eb:SetScript("OnTextChanged", function() sf:UpdateScrollChildRect() end)
    sf:SetScrollChild(eb)
    p.editBox = eb
    p.scroll = sf

    sf:SetScript("OnSizeChanged", function(_, w) eb:SetWidth(w) end)

    p.built = true
end

-- Split a body into pages on line boundaries, each at most PAGE_CHARS long.
-- Lines stay intact (a single over-long line gets its own page) so concatenating
-- the pages back-to-back reproduces the original byte-for-byte.
local function paginate(text)
    local pages, buf, len = {}, {}, 0
    for line in (text .. "\n"):gmatch("(.-)\n") do
        local add = #line + 1  -- +1 for the newline we'll rejoin with
        if len > 0 and len + add > PAGE_CHARS then
            pages[#pages + 1] = table.concat(buf, "\n")
            buf, len = {}, 0
        end
        buf[#buf + 1] = line
        len = len + add
    end
    pages[#pages + 1] = table.concat(buf, "\n")
    return pages
end

-- ---- navigation -----------------------------------------------------------
function CopyWindow:_Goto(index)
    local p = self:_p()
    local total = #p.pages
    if total == 0 then return end
    index = math.max(1, math.min(total, index))
    p.page = index
    p.editBox:SetText(p.pages[index] or "")
    p.scroll:SetVerticalScroll(0)

    local multi = total > 1
    p.footer:SetShown(multi)
    if multi then
        local base = p.titleText or "Copy"
        p.title:SetText(("%s  -  part %d/%d"):format(base, index, total))
        p.pageLabel:SetText(("Page %d of %d"):format(index, total))
        p.prev.text:SetTextColor(Theme.Unpack(index > 1 and "accent" or "textFaint"))
        p.next.text:SetTextColor(Theme.Unpack(index < total and "accent" or "textFaint"))
    else
        p.title:SetText(p.titleText or "Copy")
    end

    C_Timer.After(0, function() self:_SelectAll() end)
end

-- Re-focus the edit box and select everything in it.
function CopyWindow:_SelectAll()
    local p = self:_p()
    if not p.editBox then return end
    p.editBox:SetFocus()
    p.editBox:HighlightText()
    p.editBox:SetCursorPosition(0)
end

-- ---- show / hide ----------------------------------------------------------
-- title labels the contents; text is the body to copy. Large bodies are split
-- into pages automatically; copy each page in order and concatenate to rebuild.
function CopyWindow:Show(title, text)
    self:Build()
    local p = self:_p()
    if p.acceptBtn then p.acceptBtn:Hide() end   -- copy-out mode: no Import button
    p.titleText = title or "Copy"
    p.pages = paginate(text or "")
    p.frame:Show()
    self:_Goto(1)
end

-- Paste-IN mode: an empty, editable box + an "Import" button that hands the pasted
-- text to onAccept and closes. Reuses the same multi-line edit box.
function CopyWindow:Prompt(title, onAccept)
    self:Build()
    local p = self:_p()
    if not p.acceptBtn then
        local b = W.TextButton(p.frame, "Import")
        b:SetPoint("CENTER", p.footer, "CENTER", 0, 0)
        p.acceptBtn = b
    end
    p.titleText = title or "Import"
    p.title:SetText(p.titleText)
    p.footer:Show()
    p.prev:Hide(); p.next:Hide(); p.pageLabel:Hide()
    p.acceptBtn:Show()
    p.acceptBtn:SetScript("OnClick", function()
        local text = p.editBox:GetText()
        self:Hide()
        p.prev:Show(); p.next:Show(); p.pageLabel:Show()  -- restore for copy-out
        if onAccept then onAccept(text) end
    end)
    p.frame:Show()
    p.editBox:SetText("")
    p.editBox:SetFocus()
end

function CopyWindow:Hide()
    local p = self:_p()
    if p.frame then p.frame:Hide() end
end

ns.ServiceManager:Register(CopyWindow:New("CopyWindow", { ui = true }))
