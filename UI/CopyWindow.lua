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
-- Internal, idempotent lazy build (the `_` prefix marks it private); Show/Prompt call it.
function CopyWindow:_Build()
    local p = self:_p()
    if p.built then return end

    -- shared chrome: movable DIALOG-strata frame + draggable bar + close X (Widgets.Window).
    local f = W.Window:New(100, { name = "HagAIOCopyWindow", width = 560, height = 440,
        strata = "DIALOG", title = "Copy", onClose = function() self:Hide() end })
    local bar = f:Bar()
    p.frame = f
    p.title = f:Title()

    -- hint line
    local hint = W.Text:New(f, "Press Ctrl+C to copy, then Esc to close.", "textDim", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 16, -10)

    -- a "Select all" convenience (text is auto-selected on Show, but a click can
    -- lose the highlight). Re-focuses and re-highlights.
    local selectAll = W.TextButton:New(f, "Select all")
    selectAll:SetPoint("RIGHT", f, "RIGHT", -32, 0)
    selectAll:SetPoint("TOP", hint, "TOP", 0, 3)
    selectAll:SetScript("OnClick", function() self:_SelectAll() end)

    local div = W.Divider:New(f)
    div:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -10)
    div:SetPoint("RIGHT", f, "RIGHT", -16, 0)

    -- footer with page navigation (only shown when there's more than one page)
    local footer = W.Container:New(f)
    footer:SetHeight(22)
    footer:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 12)
    footer:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 12)
    p.footer = footer

    local prev = W.TextButton:New(footer, "< Prev")
    prev:SetPoint("LEFT", footer, "LEFT", 0, 0)
    prev:SetScript("OnClick", function() self:_Goto(p.page - 1) end)
    p.prev = prev

    local nextBtn = W.TextButton:New(footer, "Next >")
    nextBtn:SetPoint("RIGHT", footer, "RIGHT", 0, 0)
    nextBtn:SetScript("OnClick", function() self:_Goto(p.page + 1) end)
    p.next = nextBtn

    local pageLabel = W.Text:New(footer, "", "textDim", "GameFontHighlightSmall")
    pageLabel:SetPoint("CENTER", footer, "CENTER", 0, 0)
    p.pageLabel = pageLabel

    -- bordered panel housing the scrollable edit box (bottom anchors above footer)
    local box = W.Panel:New(f, "panel", "border")
    box:SetPoint("TOPLEFT", div, "BOTTOMLEFT", 0, -8)
    box:SetPoint("BOTTOMRIGHT", footer, "TOPRIGHT", 0, 6)

    local edit = W.MultilineEdit:New(box, "HagAIOCopyWindowScroll")
    edit:SetPoint("TOPLEFT", 6, -6)
    edit:SetPoint("BOTTOMRIGHT", -28, 6)  -- leave room for the scrollbar
    edit:SetOnEscape(function() self:Hide() end)
    p.edit = edit

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
    p.edit:SetText(p.pages[index] or "")
    p.edit:ScrollTop()

    local multi = total > 1
    p.footer:SetShown(multi)
    if multi then
        local base = p.titleText or "Copy"
        p.title:SetText(("%s  -  part %d/%d"):format(base, index, total))
        p.pageLabel:SetText(("Page %d of %d"):format(index, total))
        p.prev:SetTextColor(Theme.Unpack(index > 1 and "accent" or "textFaint"))
        p.next:SetTextColor(Theme.Unpack(index < total and "accent" or "textFaint"))
    else
        p.title:SetText(p.titleText or "Copy")
    end

    C_Timer.After(0, function() self:_SelectAll() end)
end

-- Re-focus the edit box and select everything in it.
function CopyWindow:_SelectAll()
    local p = self:_p()
    if p.edit then p.edit:SelectAll() end
end

-- ---- show / hide ----------------------------------------------------------
-- title labels the contents; text is the body to copy. Large bodies are split
-- into pages automatically; copy each page in order and concatenate to rebuild.
function CopyWindow:Show(title, text)
    self:_Build()
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
    self:_Build()
    local p = self:_p()
    if not p.acceptBtn then
        local b = W.TextButton:New(p.frame, "Import")
        b:SetPoint("CENTER", p.footer, "CENTER", 0, 0)
        p.acceptBtn = b
    end
    p.titleText = title or "Import"
    p.title:SetText(p.titleText)
    p.footer:Show()
    p.prev:Hide(); p.next:Hide(); p.pageLabel:Hide()
    p.acceptBtn:Show()
    p.acceptBtn:SetScript("OnClick", function()
        local text = p.edit:GetText()
        self:Hide()
        p.prev:Show(); p.next:Show(); p.pageLabel:Show()  -- restore for copy-out
        if onAccept then onAccept(text) end
    end)
    p.frame:Show()
    p.edit:SetText("")
    p.edit:Focus()
end

function CopyWindow:Hide()
    local p = self:_p()
    if p.frame then p.frame:Hide() end
end

ns.ServiceManager:Register(CopyWindow:New("CopyWindow", { ui = true }))
