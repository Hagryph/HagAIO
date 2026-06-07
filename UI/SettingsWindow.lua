local addonName, ns = ...
local Class = ns.Class
local Theme = ns.Theme
local W = ns.UI.Widgets

-- UI/SettingsWindow.lua
-- The unique, themed settings menu (replaces the default Blizzard options
-- panel). A movable, ESC-closable dark+blue window with a left nav rail and
-- three pages: Modules (live toggles), Log (the Logger's history, live), and
-- About. Styled to match the LoL Game Helper desktop app.

local SettingsWindow = Class.new("SettingsWindow", ns.Service)

function SettingsWindow:OnInitialize()
    local p = self:_p()
    p.built = false
    p.pages = {}          -- static pages: modules / log / about
    p.modulePages = {}    -- name -> auto-generated module settings page
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
    close:SetScript("OnEnter", function() x:SetTextColor(Theme.Unpack("red")) end)
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
    p.pages.general = self:_BuildGeneralPage(content)
    p.pages.log     = self:_BuildLogPage(content)
    p.pages.about   = self:_BuildAboutPage(content)

    -- nav items
    local defs = {
        { key = "general", text = "General" },
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
    ns.EventBus:Subscribe("LOG_ADDED", function()
        if p.frame:IsShown() and p.current == "log" then
            self:_RefreshLog()
        end
    end)

    -- auto-close while fighting OR in Edit Mode, reopen after if it was open
    -- (the two never overlap — Edit Mode is blocked in combat)
    local bus = ns.EventBus
    bus:On("PLAYER_REGEN_DISABLED", function() self:_Suspend() end)
    bus:On("PLAYER_REGEN_ENABLED",  function() self:_Resume() end)
    if EventRegistry then
        EventRegistry:RegisterCallback("EditMode.Enter", function() self:_Suspend() end, self)
        EventRegistry:RegisterCallback("EditMode.Exit",  function() self:_Resume() end, self)
    end
    -- a manual close (X / Esc) clears any pending reopen; an auto-close keeps it
    f:SetScript("OnHide", function()
        if p.autoClosed then p.autoClosed = false else p.reopenKey = nil end
    end)

    p.built = true
end

function SettingsWindow:_Suspend()
    local p = self:_p()
    if p.frame and p.frame:IsShown() then
        p.reopenKey = p.current or "modules"
        p.autoClosed = true
        p.frame:Hide()  -- direct, so OnHide keeps reopenKey
    end
end

function SettingsWindow:_Resume()
    local p = self:_p()
    if p.reopenKey then
        local key = p.reopenKey
        p.reopenKey = nil
        -- defer a frame: on EditMode.Exit, IsEditModeActive() can still be true,
        -- which would make Show() re-defer and never reopen.
        C_Timer.After(0, function() self:Show(key) end)
    end
end

-- ---- pages ----------------------------------------------------------------
function SettingsWindow:_BuildModulesPage(parent)
    local page = CreateFrame("Frame", nil, parent)
    page:SetAllPoints()

    local title = W.Text(page, "Feature Modules", "text", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 18, -16)
    local note = W.Text(page, "Toggle modules on or off. Changes apply immediately and persist.",
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

    local mm = ns.ModuleManager
    if mm:Count() == 0 then
        local empty = W.Text(holder, "No feature modules registered yet.", "textFaint", "GameFontHighlight")
        empty:SetPoint("TOPLEFT", 2, -2)
        p.moduleRows[#p.moduleRows + 1] = empty
        return
    end

    -- Each row: [toggle]  Name + short description  ............  [ Settings › ]
    -- Modules whose required addon isn't loaded are hidden entirely; modules whose
    -- prerequisite module is disabled are shown greyed out (can't toggle on).
    local y = 0
    for module in mm:Iterate() do
        if module:IsAvailable() then
            local depsMet = module:AreModuleDepsMet()

            local row = CreateFrame("Frame", nil, holder)
            row:SetPoint("TOPLEFT", 2, y)
            row:SetPoint("RIGHT", holder, "RIGHT", -2, 0)
            row:SetHeight(44)

            local toggle = W.Toggle(row, nil)
            toggle:SetPoint("TOPLEFT", 0, -4)
            toggle:SetChecked(module:IsEnabled())
            toggle:SetEnabled(depsMet)
            toggle:SetOnToggle(function(on)
                if on then module:Enable() else module:Disable() end
                self:_RefreshModules()  -- dependents may need to grey/ungrey
            end)

            local name = W.Text(row, module:GetTitle(), depsMet and "text" or "textFaint", "GameFontNormal")
            name:SetPoint("TOPLEFT", toggle, "TOPRIGHT", 12, 2)

            local settings = W.TextButton(row, "Settings >")
            settings:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            settings:SetScript("OnClick", function() self:Show("module:" .. module:GetName()) end)

            local descText = module:GetDescription()
            if not depsMet then
                local deps = module:GetModuleDeps()
                descText = "Requires " .. table.concat(deps, ", ") .. " enabled."
            end
            local desc = W.Text(row, descText, "textFaint", "GameFontHighlightSmall")
            desc:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -3)
            desc:SetPoint("RIGHT", settings, "LEFT", -10, 0)
            desc:SetJustifyH("LEFT")

            p.moduleRows[#p.moduleRows + 1] = row
            y = y - 48
        end
    end
end

-- Static "General" page: addon-wide options (currently the icon toggles).
function SettingsWindow:_BuildGeneralPage(parent)
    local page = CreateFrame("Frame", nil, parent)
    page:SetAllPoints()

    local title = W.Text(page, "General", "text", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 18, -16)
    local note = W.Text(page, "Addon-wide options.", "textDim", "GameFontHighlightSmall")
    note:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)

    local div = W.Divider(page)
    div:SetPoint("TOPLEFT", note, "BOTTOMLEFT", 0, -12)
    div:SetPoint("RIGHT", page, "RIGHT", -18, 0)

    -- Icons section
    local icons = W.SectionLabel(page, "Icons")
    icons:SetPoint("TOPLEFT", div, "BOTTOMLEFT", 4, -16)

    local comp = W.Toggle(page, W.FlagReload("Compartment icon"))
    comp:SetPoint("TOPLEFT", icons, "BOTTOMLEFT", 2, -12)
    comp:SetChecked(ns.Compartment:IsShown())
    comp:SetOnToggle(function(on)
        local needsReload = ns.Compartment:SetShown(on)
        if needsReload then
            ns.Logger:Core():Warn("Reload your UI (/reload) to remove the compartment icon.")
        end
    end)
    local compDesc = W.Text(page, "Shows HagAIO in the minimap's addon-compartment menu.",
        "textFaint", "GameFontHighlightSmall")
    compDesc:SetPoint("TOPLEFT", comp, "BOTTOMLEFT", 26, -2)

    local mini = W.Toggle(page, "Minimap icon")
    mini:SetPoint("TOPLEFT", compDesc, "BOTTOMLEFT", -26, -14)
    mini:SetChecked(ns.MinimapIcon:IsShown())
    mini:SetOnToggle(function(on) ns.MinimapIcon:SetShown(on) end)
    local miniDesc = W.Text(page, "Adds a draggable button on the minimap edge.",
        "textFaint", "GameFontHighlightSmall")
    miniDesc:SetPoint("TOPLEFT", mini, "BOTTOMLEFT", 26, -2)

    return page
end

-- Drop a module's cached settings page so it rebuilds from the CURRENT schema
-- (e.g. a module changed its settings dynamically, like a Monk spec swap). If the
-- page is on screen, rebuild and re-show it immediately.
function SettingsWindow:InvalidateModule(name)
    local p = self:_p()
    if not p.built then return end
    local page = p.modulePages[name]
    if not page then return end
    page:Hide()
    p.modulePages[name] = nil
    if p.frame and p.frame:IsShown() and p.current == ("module:" .. name) then
        self:Show("module:" .. name)
    end
end

-- Lazily build a module's auto-generated settings page from its schema.
function SettingsWindow:_EnsureModulePage(name)
    local p = self:_p()
    if p.modulePages[name] then return p.modulePages[name] end
    local module = ns.ModuleManager:GetModule(name)
    if not module then return nil end

    local page = CreateFrame("Frame", nil, p.content)
    page:SetAllPoints()

    local back = W.TextButton(page, "< Modules")
    back:SetPoint("TOPLEFT", 16, -14)
    back:SetScript("OnClick", function() self:Show("modules") end)

    local title = W.Text(page, module:GetTitle(), "text", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", back, "BOTTOMLEFT", 0, -8)

    -- enable toggle on the header row
    local enable = W.Toggle(page, "Enabled")
    enable:SetPoint("TOPRIGHT", page, "TOPRIGHT", -84, -16)
    enable:SetChecked(module:IsEnabled())
    enable:SetOnToggle(function(on)
        if on then module:Enable() else module:Disable() end
    end)

    local desc = W.Text(page, module:GetDescription(), "textDim", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    desc:SetPoint("RIGHT", page, "RIGHT", -18, 0)
    desc:SetJustifyH("LEFT")

    local div = W.Divider(page)
    div:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -12)
    div:SetPoint("RIGHT", page, "RIGHT", -18, 0)

    local sf = W.ScrollFrame(page, "HagAIOModule" .. name:gsub("%s", "") .. "Scroll")
    sf:SetPoint("TOPLEFT", div, "BOTTOMLEFT", 0, -8)
    sf:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -30, 14)

    -- A module may own a fully custom, live-bound page (e.g. CVars, whose
    -- controls bind to the game rather than to keyed saved-vars). Otherwise the
    -- shared schema renderer builds the page from module:GetSettings().
    if module.BuildSettingsPage then
        module:BuildSettingsPage(sf)
    else
        self:_BuildModuleControls(sf, module)
    end

    page.enableToggle = enable
    p.modulePages[name] = page
    return page
end

-- Render one settings HOST's schema (a Module OR a Submodule -- anything with
-- GetSettings/GetSetting/SetSetting) into `content` starting at `y`; returns the
-- new y. Controls bind live to that host.
function SettingsWindow:_RenderSchema(content, host, width, y)
    local schema = host:GetSettings()

    -- controls that declare `dependsOn` get greyed out when their parent option is off.
    local dep = W.DependencyGroup()
    local graph = ns.DependencyGraph:New()
    for _, s in ipairs(schema) do
        if s.key and (s.type == "toggle" or s.type == "select" or s.type == "color") then
            graph:Add(s.key, function() return host:GetSetting(s.key) and true or false end, s.dependsOn)
        end
    end
    local ok, issues = graph:Validate()
    if not ok then
        local log = host.GetLog and host:GetLog()
        for _, msg in ipairs(issues) do
            if log then log:Warn("settings dependency: " .. msg) else ns.Logger:Core():Warn("settings dependency: " .. msg) end
        end
    end

    for _, s in ipairs(schema) do
        if s.type == "header" then
            local h = W.SectionLabel(content, s.text)
            h:SetPoint("TOPLEFT", 4, y - 6)
            y = y - 28

        elseif s.type == "note" then
            local n = W.Text(content, s.text, "textDim", "GameFontHighlightSmall")
            n:SetPoint("TOPLEFT", 4, y)
            n:SetWidth(width - 16)
            n:SetJustifyH("LEFT")
            y = y - (n:GetStringHeight() + 12)

        elseif s.type == "toggle" then
            local t = W.Toggle(content, s.reload and W.FlagReload(s.label) or s.label)
            t:SetPoint("TOPLEFT", 6, y)
            t:SetChecked(host:GetSetting(s.key) and true or false)
            t:SetOnToggle(function(on) host:SetSetting(s.key, on); dep:Refresh() end)
            if s.dependsOn then dep:Add(t, function() return graph:IsSatisfied(s.key) end) end
            y = y - 26
            if s.desc then
                local d = W.Text(content, s.desc, "textFaint", "GameFontHighlightSmall")
                d:SetPoint("TOPLEFT", 30, y)
                d:SetWidth(width - 40)
                d:SetJustifyH("LEFT")
                y = y - (d:GetStringHeight() + 8)
            else
                y = y - 6
            end

        elseif s.type == "select" then
            local lbl = W.Text(content, s.reload and W.FlagReload(s.label) or s.label, "text", "GameFontHighlight")
            lbl:SetPoint("TOPLEFT", 6, y)
            y = y - 20
            local seg = W.Segmented(content, s.options)
            seg:SetPoint("TOPLEFT", 6, y)
            seg:SetValue(host:GetSetting(s.key))
            seg:SetOnChange(function(v) host:SetSetting(s.key, v); dep:Refresh() end)
            if s.dependsOn then dep:Add(seg, function() return graph:IsSatisfied(s.key) end) end
            y = y - 34

        elseif s.type == "color" then
            local lbl = W.Text(content, s.label, "text", "GameFontHighlight")
            lbl:SetPoint("TOPLEFT", 6, y)
            local sw = W.ColorSwatch(content)
            sw:SetPoint("TOPRIGHT", content, "TOPRIGHT", -6, y)
            local c = host:GetSetting(s.key) or s.default or { 1, 1, 1 }
            sw:SetColor(c[1] or 1, c[2] or 1, c[3] or 1)
            sw:SetOnChange(function(r, g, b) host:SetSetting(s.key, { r, g, b }) end)
            if s.default then sw:SetDefault(s.default[1], s.default[2], s.default[3]) end
            if s.dependsOn then dep:Add(sw, function() return graph:IsSatisfied(s.key) end) end
            y = y - 26
        end
    end

    dep:Refresh()  -- set initial enabled/greyed state from the current values
    return y
end

-- A module page = the module's own schema, then the settings of every LOADED
-- submodule of that module. Submodule options therefore appear (and persist)
-- ONLY while the submodule is loaded -- e.g. the ATT submodule's option shows
-- only when AllTheThings is installed. No addon checks live here.
function SettingsWindow:_BuildModuleControls(sf, module)
    local content = sf.content
    local width = sf:GetWidth()
    if not width or width < 1 then width = 420 end
    content:SetWidth(width)

    local y, rendered = -4, false
    if #module:GetSettings() > 0 then
        y = self:_RenderSchema(content, module, width, y)
        rendered = true
    end

    local subs = ns.SubmoduleManager and ns.SubmoduleManager:LoadedChildrenOf(module:GetName()) or {}
    for _, sub in ipairs(subs) do
        if sub.GetSettings and #sub:GetSettings() > 0 then
            local h = W.SectionLabel(content, sub:GetTitle())
            h:SetPoint("TOPLEFT", 4, y - 6)
            y = y - 28
            y = self:_RenderSchema(content, sub, width, y)
            rendered = true
        end
    end

    if not rendered then
        local none = W.Text(content, "This module has no options.", "textFaint", "GameFontHighlightSmall")
        none:SetPoint("TOPLEFT", 4, -4)
        content:SetHeight(30)
        return
    end
    content:SetHeight(math.max(30, -y + 8))
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
        wipe(ns.Logger:GetHistory())
        self:_RefreshLog()
    end)

    local echo = W.Toggle(page, "Echo to chat")
    echo:SetPoint("RIGHT", clear, "LEFT", -88, 0)
    echo:SetPoint("TOP", title, "TOP", 0, 0)
    echo:SetChecked(ns.Logger:GetEcho())
    echo:SetOnToggle(function(on) ns.Logger:SetEcho(on) end)

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
    local h = ns.Logger:GetHistory()

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
    local ver = W.Text(page, "Version " .. tostring(ns.version) .. "   |cff5b6473|||r   Midnight 12.0.x",
        "accent", "GameFontHighlight")
    ver:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)

    local desc = W.Text(page,
        "All-in-One toolkit. A modular framework that feature modules\nplug into, sharing one logger and this settings window.",
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
        "/hag  -  open this panel\n/hag log  -  open the activity log\n/hag modules  -  list modules\n/hag help  -  all commands",
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

    -- Defer opening during combat or Edit Mode; it opens again afterwards.
    local editActive = EditModeManagerFrame and EditModeManagerFrame.IsEditModeActive
        and EditModeManagerFrame:IsEditModeActive()
    if not p.frame:IsShown() and (InCombatLockdown() or editActive) then
        p.reopenKey = key
        if InCombatLockdown() then
            ns.Logger:Core():Warn("In combat - the settings will open when you leave combat.")
        end
        return
    end

    -- hide everything first
    for _, page in pairs(p.pages) do page:SetShown(false) end
    for _, page in pairs(p.modulePages) do page:SetShown(false) end

    local navKey = key
    local moduleName = key:match("^module:(.+)$")
    if moduleName then
        local page = self:_EnsureModulePage(moduleName)
        if page then
            if page.enableToggle then
                page.enableToggle:SetChecked(ns.ModuleManager:GetModule(moduleName):IsEnabled())
            end
            page:Show()
        else
            key, navKey = "modules", "modules"
            p.pages.modules:Show()
        end
        navKey = "modules"  -- a module page is a sub-page of Modules
    elseif p.pages[key] then
        p.pages[key]:Show()
    end

    for k, item in pairs(p.nav) do item:SetActive(k == navKey) end
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

ns.ServiceManager:Register(SettingsWindow:New("SettingsWindow", { ui = true, deps = { "EventBus" } }))
