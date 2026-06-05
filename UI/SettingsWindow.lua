local addonName, ns = ...
local Class = ns.Class
local Theme = ns.Theme
local W = ns.UI.Widgets

-- UI/SettingsWindow.lua
-- The unique, themed settings menu (replaces the default Blizzard options
-- panel). A movable, ESC-closable dark+blue window with a left nav rail and
-- three pages: Modules (live toggles), Log (the Logger's history, live), and
-- About. Styled to match the LoL Game Helper desktop app.

local SettingsWindow = Class.new("SettingsWindow")
local instance

function SettingsWindow:Initialize()
    local p = self:_p()
    p.built = false
    p.pages = {}
    p.nav = {}
    p.current = nil
end

-- ---- construction ---------------------------------------------------------
function SettingsWindow:Build()
    local p = self:_p()
    if p.built then return end

    local f = CreateFrame("Frame", "HagAIOSettingsWindow", UIParent, "BackdropTemplate")
    f:SetSize(620, 460)
    f:SetPoint("CENTER")
    W.Style(f, "bg1", "borderStrong")
    f:SetFrameStrata("HIGH")
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:Hide()
    tinsert(UISpecialFrames, "HagAIOSettingsWindow")  -- ESC closes
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

    local title = W.Text(bar, "HAGAIO", "accent", "GameFontNormalLarge")
    title:SetPoint("LEFT", 16, 0)
    local ver = W.Text(bar, "v" .. tostring(ns.version), "textFaint", "GameFontNormalSmall")
    ver:SetPoint("LEFT", title, "RIGHT", 8, -1)

    local close = CreateFrame("Button", nil, bar)
    close:SetSize(38, 38)
    close:SetPoint("RIGHT", 0, 0)
    local x = W.Text(close, "X", "textDim", "GameFontNormalLarge")
    x:SetPoint("CENTER")
    close:SetScript("OnEnter", function() x:SetTextColor(Theme.Unpack("loss")) end)
    close:SetScript("OnLeave", function() x:SetTextColor(Theme.Unpack("textDim")) end)
    close:SetScript("OnClick", function() self:Hide() end)

    -- left nav rail
    local nav = W.Panel(f, "bg0", "border")
    nav:SetWidth(150)
    nav:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -1)
    nav:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 1, 1)

    local navLabel = W.SectionLabel(nav, "Menu")
    navLabel:SetPoint("TOPLEFT", 16, -16)

    -- content area
    local content = W.Panel(f, "panel", "border")
    content:SetPoint("TOPLEFT", nav, "TOPRIGHT", 1, 0)
    content:SetPoint("BOTTOMRIGHT", -1, 1)
    p.content = content

    -- pages
    p.pages.modules = self:_BuildModulesPage(content)
    p.pages.log     = self:_BuildLogPage(content)
    p.pages.about   = self:_BuildAboutPage(content)

    -- nav items
    local defs = {
        { key = "modules", text = "Modules" },
        { key = "log",     text = "Log" },
        { key = "about",   text = "About" },
    }
    local y = -42
    for _, d in ipairs(defs) do
        local item = W.NavItem(nav, d.text)
        item:SetPoint("TOPLEFT", nav, "TOPLEFT", 8, y)
        item:SetPoint("RIGHT", nav, "RIGHT", -8, 0)
        item:SetScript("OnClick", function() self:Show(d.key) end)
        p.nav[d.key] = item
        y = y - 38
    end

    -- live log updates while the Log page is open
    ns.EventBus.Get():Subscribe("LOG_ADDED", function()
        if p.frame:IsShown() and p.current == "log" then
            self:_RefreshLog()
        end
    end)

    p.built = true
end

-- ---- pages ----------------------------------------------------------------
function SettingsWindow:_BuildModulesPage(parent)
    local page = CreateFrame("Frame", nil, parent)
    page:SetAllPoints()

    local title = W.Text(page, "Feature Modules", "text", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 18, -16)
    local note = W.Text(page, "Toggle modules on or off — changes apply immediately and persist.",
        "textDim", "GameFontHighlightSmall")
    note:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)

    local div = W.Divider(page)
    div:SetPoint("TOPLEFT", note, "BOTTOMLEFT", 0, -12)
    div:SetPoint("RIGHT", page, "RIGHT", -18, 0)

    local holder = CreateFrame("Frame", nil, page)
    holder:SetPoint("TOPLEFT", div, "BOTTOMLEFT", 0, -12)
    holder:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -18, 16)

    local p = self:_p()
    p.moduleHolder = holder
    p.moduleRows = {}
    return page
end

function SettingsWindow:_RefreshModules()
    local p = self:_p()
    local holder = p.moduleHolder
    for _, r in ipairs(p.moduleRows) do r:Hide() end
    wipe(p.moduleRows)

    local mm = ns.ModuleManager.Get()
    if mm:Count() == 0 then
        local empty = W.Text(holder, "No feature modules registered yet.", "textFaint", "GameFontHighlight")
        empty:SetPoint("TOPLEFT", 2, -2)
        p.moduleRows[#p.moduleRows + 1] = empty
        return
    end

    local y = 0
    for module in mm:Iterate() do
        local row = CreateFrame("Frame", nil, holder)
        row:SetPoint("TOPLEFT", 2, y)
        row:SetPoint("RIGHT", holder, "RIGHT", -2, 0)
        row:SetHeight(28)

        local toggle = W.Toggle(row, nil)
        toggle:SetPoint("LEFT", 0, 0)
        toggle:SetChecked(module:IsEnabled())
        toggle:SetOnToggle(function(on)
            if on then module:Enable() else module:Disable() end
        end)

        local name = W.Text(row, module:GetTitle(), "text", "GameFontHighlight")
        name:SetPoint("LEFT", toggle, "RIGHT", 10, 0)

        p.moduleRows[#p.moduleRows + 1] = row
        y = y - 32
    end
end

function SettingsWindow:_BuildLogPage(parent)
    local page = CreateFrame("Frame", nil, parent)
    page:SetAllPoints()

    local title = W.Text(page, "Activity Log", "text", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 18, -16)

    -- Controls sit on the title row, vertically centred on the title, so they
    -- never collide with the note line below.
    local clear = W.TextButton(page, "Clear")
    clear:SetPoint("RIGHT", page, "RIGHT", -18, 0)
    clear:SetPoint("TOP", title, "TOP", 0, 3)
    clear:SetScript("OnClick", function()
        wipe(ns.Logger.Get():GetHistory())
        self:_RefreshLog()
    end)

    local echo = W.Toggle(page, "Echo to chat")
    echo:SetPoint("RIGHT", clear, "LEFT", -88, 0)
    echo:SetPoint("TOP", title, "TOP", 0, 0)
    echo:SetChecked(ns.Logger.Get():GetEcho())
    echo:SetOnToggle(function(on) ns.Logger.Get():SetEcho(on) end)

    -- Note pinned below the whole header band (title + controls), not chained
    -- to the title, so the spacing is fixed regardless of font metrics.
    local note = W.Text(page, "Every module report is recorded here automatically.",
        "textDim", "GameFontHighlightSmall")
    note:SetPoint("TOPLEFT", page, "TOPLEFT", 18, -46)

    local div = W.Divider(page)
    div:SetPoint("TOPLEFT", note, "BOTTOMLEFT", 0, -10)
    div:SetPoint("RIGHT", page, "RIGHT", -18, 0)

    local sf = W.ScrollFrame(page, "HagAIOLogScroll")
    sf:SetPoint("TOPLEFT", div, "BOTTOMLEFT", 0, -8)
    sf:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -30, 14)

    local fs = sf.content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT")
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    fs:SetSpacing(3)

    local p = self:_p()
    p.logFS = fs
    p.logSF = sf
    sf:SetScript("OnSizeChanged", function() self:_RefreshLog() end)
    return page
end

function SettingsWindow:_RefreshLog()
    local p = self:_p()
    if not p.logFS then return end
    local h = ns.Logger.Get():GetHistory()

    local lines, startIdx = {}, math.max(1, #h - 200)
    for i = startIdx, #h do lines[#lines + 1] = h[i].line end
    p.logFS:SetText(#lines > 0 and table.concat(lines, "\n")
        or ("|cff" .. Theme.hex.textFaint .. "No activity yet.|r"))

    local width = p.logSF:GetWidth()
    if not width or width < 1 then width = 380 end
    p.logFS:SetWidth(width)
    p.logSF.content:SetWidth(width)
    p.logSF.content:SetHeight(p.logFS:GetStringHeight() + 8)
end

function SettingsWindow:_BuildAboutPage(parent)
    local page = CreateFrame("Frame", nil, parent)
    page:SetAllPoints()

    local title = W.Text(page, "HagAIO", "text", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 18, -18)
    local ver = W.Text(page, "Version " .. tostring(ns.version) .. "   |cff5b6473•|r   Midnight 12.0.x",
        "accent", "GameFontHighlight")
    ver:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)

    local desc = W.Text(page,
        "All-in-One toolkit — a modular framework that feature modules\nplug into, sharing one logger and this settings window.",
        "textDim", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", ver, "BOTTOMLEFT", 0, -16)
    desc:SetJustifyH("LEFT")
    desc:SetSpacing(4)

    local author = W.Text(page, "Author: Hagryph", "text", "GameFontHighlight")
    author:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -20)
    local repo = W.Text(page, "github.com/Hagryph/HagAIO", "textFaint", "GameFontHighlightSmall")
    repo:SetPoint("TOPLEFT", author, "BOTTOMLEFT", 0, -6)

    local cmds = W.SectionLabel(page, "Commands")
    cmds:SetPoint("TOPLEFT", repo, "BOTTOMLEFT", 0, -24)
    local list = W.Text(page,
        "/hag — open this panel\n/hag log — open the activity log\n/hag modules — list modules\n/hag help — all commands",
        "textDim", "GameFontHighlightSmall")
    list:SetPoint("TOPLEFT", cmds, "BOTTOMLEFT", 0, -8)
    list:SetJustifyH("LEFT")
    list:SetSpacing(5)
    return page
end

-- ---- show / hide ----------------------------------------------------------
function SettingsWindow:Show(key)
    self:Build()
    local p = self:_p()
    key = key or p.current or "modules"
    for k, page in pairs(p.pages) do page:SetShown(k == key) end
    for k, item in pairs(p.nav) do item:SetActive(k == key) end
    p.current = key

    if key == "modules" then self:_RefreshModules() end
    if key == "log" then
        self:_RefreshLog()
        -- re-measure once the frame has a real width on screen
        C_Timer.After(0, function() self:_RefreshLog() end)
    end
    p.frame:Show()
end

function SettingsWindow:Hide()
    local p = self:_p()
    if p.frame then p.frame:Hide() end
end

function SettingsWindow:Toggle()
    self:Build()
    local p = self:_p()
    if p.frame:IsShown() then self:Hide() else self:Show(p.current or "modules") end
end

function SettingsWindow.Get()
    if not instance then instance = SettingsWindow:New() end
    return instance
end

ns.UI.SettingsWindow = SettingsWindow
