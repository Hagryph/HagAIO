local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, claimLevel, adopt = _wb.unwrap, _wb.style, _wb.claimLevel, _wb.adopt

-- UI/Widgets/Grid.lua
-- Column-aligned GRID -- the one row/column layout engine. Define columns ONCE (width +
-- header label + justify); the optional sticky header AND every data row derive their cell
-- x-positions from the SAME column spec, so alignment is structural, never hand-offset. The
-- same primitive drives a single-column selectable list (a sidebar/nav) and an N-column data
-- table, so the sidebar items, section headers and the main grid all align through one code path.
--   opts: columns = { { width=number|nil(flex), label=string, justify="LEFT"/"CENTER"/"RIGHT" }, ... }
--         header   build a sticky column-label row;  striped  alternate row tints
--         scroll   default true -> rows scroll under the header; false -> laid out in place
--         name     frame name (REQUIRED when scroll, for the scrollbar);  rowHeight (22; 24 with header)
--         indentStep (12)  pixels per row.indent level on the first column
-- A grid WITH a header is a DATA TABLE and dresses itself like one (the LoL-style treatment):
-- a filled header band with an accent underline, zebra striping (default on), hairline row
-- separators, a hover wash on every row, and auto-fainted empty ("-") cells. A grid WITHOUT a
-- header (the sidebar/nav form) keeps the bare look -- only clickable rows paint.
-- A row passed to :SetRows is one of:
--   { cells = { "..", .. }, color=paletteKey, cellColor=function(colIndex)->key|{r,g,b},
--     onClick=fn, active=bool, indent=number,
--     controls=function(rowFrame, columnXs) ... end }  -- a data / nav row; controls lets the
--       caller place persistent widgets (checkboxes/buttons) at columnXs[i] (cache them on
--       rowFrame, re-bind each call) so an interactive table still aligns through the grid
--   { section = "Label" }                          -- a full-width section header row
-- Methods: :SetColumns(cols)  :SetRows(rows)  :Refresh()  (.header is the header frame).
local GridW = ns.Class.new("Grid", FrameWidget)
function GridW:Initialize(parent, opts)
    opts = opts or {}
    local g = CreateFrame("Frame", nil, unwrap(parent))
    -- clip everything (the sticky header's columns + the scrolled rows) to the grid's own bounds, so a
    -- table wider/taller than its area is cut at the edge instead of spilling over the rest of the UI.
    if g.SetClipsChildren then g:SetClipsChildren(true) end
    local p = self:_p()
    p.columns = opts.columns or {}
    local dataMode   = opts.header and true or false       -- header => the full data-table dressing
    local rowH       = opts.rowHeight or (dataMode and 24 or 22)
    local indentStep = opts.indentStep or 12
    local pad        = opts.cellPad or (dataMode and 8 or 4)   -- text padding (clears the active bar)
    local striped    = opts.striped
    if striped == nil then striped = dataMode end           -- data tables stripe by default
    local rows = {}

    -- x offset of each column from the grid's left; a width=nil column flexes to fill `width`.
    local function colX(width)
        local fixed = 0
        for _, c in ipairs(p.columns) do fixed = fixed + (c.width or 0) end
        local xs, x = {}, 0
        for i, c in ipairs(p.columns) do
            xs[i] = x
            x = x + (c.width or math.max(40, width - fixed))
        end
        return xs
    end

    local header, headerDiv
    if opts.header then
        header = CreateFrame("Frame", nil, g)
        header:SetPoint("TOPLEFT"); header:SetPoint("TOPRIGHT")
        header:SetHeight(opts.headerHeight or 24)
        header.cells = {}
        -- the band: a filled strip so the column labels sit ON something, not in the void
        header.bg = header:CreateTexture(nil, "BACKGROUND")
        header.bg:SetAllPoints()
        header.bg:SetColorTexture(Theme.Unpack("panel2", 0.9))
        -- accent underline directly below the band (the LoL signature line), then a breathing gap
        headerDiv = g:CreateTexture(nil, "ARTWORK")
        headerDiv:SetHeight(1)
        headerDiv:SetColorTexture(Theme.Unpack("accent", 0.35))
        headerDiv:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
        headerDiv:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)
    end
    p.header = header

    local content
    if opts.scroll ~= false then
        local sa = Widgets.ScrollArea:New(g, opts.name)   -- custom themed scrollbar
        sa:SetPoint("TOPLEFT", header and headerDiv or g, header and "BOTTOMLEFT" or "TOPLEFT", 0, header and -6 or 0)
        sa:SetPoint("BOTTOMRIGHT", g, "BOTTOMRIGHT", 0, 0)
        p.scrollArea, content = sa, unwrap(sa:Content())
    else
        content = CreateFrame("Frame", nil, g)
        content:SetPoint("TOPLEFT", header and unwrap(headerDiv) or g, header and "BOTTOMLEFT" or "TOPLEFT", 0, header and -6 or 0)
        content:SetPoint("TOPRIGHT")
    end
    p.content = content

    local function bodyWidth()
        local w = content:GetWidth()
        if not w or w < 1 then w = g:GetWidth() or 200 end
        return w
    end

    local function getRow(i)
        local r = rows[i]
        if r then return r end
        r = CreateFrame("Button", nil, content)
        r:SetHeight(rowH)
        r.bg = r:CreateTexture(nil, "BACKGROUND"); r.bg:SetAllPoints()
        r.sep = r:CreateTexture(nil, "BORDER")                                -- hairline row separator
        r.sep:SetPoint("BOTTOMLEFT"); r.sep:SetPoint("BOTTOMRIGHT"); r.sep:SetHeight(1)
        r.sep:SetColorTexture(Theme.Unpack("border", 0.10)); r.sep:Hide()
        r.bar = r:CreateTexture(nil, "OVERLAY")
        r.bar:SetPoint("TOPLEFT"); r.bar:SetPoint("BOTTOMLEFT"); r.bar:SetWidth(3)  -- flush to the row bg
        r.bar:SetColorTexture(Theme.Unpack("accent")); r.bar:Hide()
        r.cells = {}
        r.sectionTick = r:CreateTexture(nil, "ARTWORK")                       -- accent tick before a section label
        r.sectionTick:SetSize(3, 10); r.sectionTick:SetPoint("LEFT", pad - 4, 0)
        r.sectionTick:SetColorTexture(Theme.Unpack("accent", 0.8)); r.sectionTick:Hide()
        r.sectionFS = Widgets.SectionLabel:New(r, ""); r.sectionFS:SetPoint("LEFT", pad + 4, 0); r.sectionFS:Hide()
        rows[i] = r
        return r
    end

    local function setColor(fs, key)
        if type(key) == "table" then fs:SetTextColor(key[1], key[2], key[3]) else fs:SetTextColor(Theme.Unpack(key)) end
    end

    local function refresh()
        local width = bodyWidth()   -- the ScrollArea keeps content width = viewport (no manual set)
        local xs = colX(width)

        if header then
            for ci, c in ipairs(p.columns) do
                local fs = header.cells[ci]
                if not fs then fs = Widgets.SectionLabel:New(header, ""); header.cells[ci] = fs end
                fs:ClearAllPoints(); fs:SetPoint("LEFT", xs[ci] + pad, 0)
                fs:SetWidth(math.max(10, (c.width or (width - xs[ci])) - pad - 2))
                fs:SetJustifyH(c.justify or "LEFT"); fs:SetText(c.label or ""); fs:SetWordWrap(false); fs:Show()
            end
            for ci = #p.columns + 1, #header.cells do header.cells[ci]:Hide() end
        end

        local data, y = p._data or {}, 0
        for i, rd in ipairs(data) do
            local r = getRow(i)
            for ci = #r.cells + 1, #p.columns do
                r.cells[ci] = Widgets.Text:New(r, "", "text", "GameFontHighlightSmall")
            end
            r:ClearAllPoints(); r:SetPoint("TOPLEFT", 0, y); r:SetPoint("RIGHT", content, "RIGHT", 0, 0)
            r:SetScript("OnClick", nil); r:SetScript("OnEnter", nil); r:SetScript("OnLeave", nil); r:EnableMouse(false)
            r.bar:Hide(); r.sectionFS:Hide(); r.sectionTick:Hide(); r.sep:Hide(); r.bg:SetColorTexture(0, 0, 0, 0)
            for _, fs in ipairs(r.cells) do fs:Hide() end

            if rd.section then
                r.sectionFS:SetText(rd.section); r.sectionFS:Show()
                if dataMode then r.sectionTick:Show() end
            else
                local indent = (rd.indent or 0) * indentStep
                for ci, c in ipairs(p.columns) do
                    local fs, extra = r.cells[ci], (ci == 1) and (rd.indent or 0) * indentStep or 0
                    fs:ClearAllPoints(); fs:SetPoint("LEFT", xs[ci] + pad + extra, 0)
                    fs:SetWidth(math.max(10, (c.width or (width - xs[ci])) - pad - 2 - extra))
                    fs:SetJustifyH(c.justify or "LEFT"); fs:SetWordWrap(false)
                    local text = (rd.cells and rd.cells[ci]) or ""
                    fs:SetText(text)
                    local color = (rd.cellColor and rd.cellColor(ci)) or rd.color
                    if not color and (text == "-" or text == "") then color = "textFaint" end   -- empty reads as absence
                    setColor(fs, color or "text")
                    fs:Show()
                end
                -- one paint path for every row state: active wash > hover wash > stripe > bare
                local stripe = striped and (i % 2 == 0)
                local function paint(hover)
                    if rd.active then r.bg:SetColorTexture(Theme.Unpack("accentSoft"))
                    elseif hover then r.bg:SetColorTexture(Theme.Unpack("panelHover", 0.55))
                    elseif stripe then r.bg:SetColorTexture(Theme.Unpack("panel2", 0.45))
                    else r.bg:SetColorTexture(0, 0, 0, 0) end
                end
                if rd.onClick then
                    r:EnableMouse(true)
                    r:SetScript("OnClick", function() rd.onClick(rd) end)
                    r.bar:SetShown(rd.active and true or false)
                    if rd.active then r.cells[1]:SetTextColor(Theme.Unpack("accent")) end
                    r:SetScript("OnEnter", function() paint(true) end)
                    r:SetScript("OnLeave", function() paint(false) end)
                elseif dataMode then
                    r:EnableMouse(true)                       -- hover wash even on read-only data rows
                    r:SetScript("OnEnter", function() paint(true) end)
                    r:SetScript("OnLeave", function() paint(false) end)
                end
                paint(false)
                if dataMode then r.sep:Show() end             -- hairline under every data row
                -- custom per-row widgets (checkboxes/buttons) positioned at the column x's: the row
                -- caches them on first call and re-binds them to this row's data. The first arg is a
                -- raw row region (allowlisted: an internal grid surface) and `xs` the column offsets.
                if rd.controls then rd.controls(r, xs) end
            end
            r:Show()
            y = y - rowH
        end
        for i = #data + 1, #rows do rows[i]:Hide() end
        content:SetHeight(math.max(1, -y))
        if p.scrollArea then p.scrollArea:Update() end   -- resize/position the custom scrollbar
    end
    p.refresh = refresh
    self:_attach(g)
end
function GridW:SetColumns(cols) local p = self:_p(); p.columns = cols or {}; p.refresh(); return self end
function GridW:SetRows(data)    local p = self:_p(); p._data = data; p.refresh(); return self end
function GridW:Refresh()        self:_p().refresh(); return self end
function GridW:ScrollTop()      local p = self:_p(); if p.scrollArea then p.scrollArea:ScrollTop() end; return self end
Widgets.Grid = GridW
