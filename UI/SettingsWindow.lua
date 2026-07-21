local addonName, ns = ...
local Class = ns.Class
local Theme = ns.Theme
local W = ns.UI.Widgets

-- UI/SettingsWindow.lua
-- The unique, themed settings menu (replaces the default Blizzard options
-- panel). A movable, ESC-closable dark+blue window with a left nav rail and
-- three pages: Modules (live toggles), Log (the Logger's history, live), and
-- About. Styled to match the LoL Game Helper desktop app.

local SettingsWindow = Class.new("SettingsWindow", ns.Service, { statics = {
    windowWidth = 920,
    windowHeight = 640,
    navWidth = 170,
    gridMinWidth = 660,
    gridGutter = 16,
} })

-- A General-page contribution may carry `visibleDeps` (a list of SERVICE names): it shows only
-- when every one of them is loaded. A soft, visibility-only dependency (e.g. a dev-only toggle
-- gated on the "Dev" service), distinct from a module's `deps`, which gate whether it starts.
local function allServicesLoaded(deps)
    if not deps then return true end
    for _, name in ipairs(deps) do
        if not ns.ServiceManager:IsLoaded(name) then return false end
    end
    return true
end

function SettingsWindow:OnInitialize()
    local p = self:_p()
    p.built = false
    p.pages = {}          -- static pages: modules / log / about
    p.modulePages = {}    -- name -> auto-generated module settings page
    p.nav = {}
    p.current = nil
    p.generalToggles = {} -- descriptors pushed in by addon-wide features (see RegisterGeneralToggle)

    -- Own the bare "/hag" action (we depend on the router, not the reverse): it toggles
    -- this window. The "config"/"log" sub-commands are declared on registration (see the
    -- `commands` opts below) and wired by the Service base.
    ns.SlashCommand:SetDefaultHandler(function() self:Toggle() end)
end

-- Let an addon-wide feature contribute a toggle to the static "General" page
-- WITHOUT the settings window having to know that feature exists. This inverts
-- the dependency: the compartment / minimap icons push their toggle in here (they
-- already depend on this window to open it), so this window never reaches back
-- into them -- no dependency cycle. Descriptor fields:
--   section     : group label on the page (default "General")
--   label       : the toggle's text
--   desc        : a faint one-line description under it
--   reload      : true to append the "(reload)" hint to the label
--   get()       : -> current bool state
--   set(on)     : apply; may return true if a /reload is needed to take effect
--   reloadMsg   : warning logged when set() reports a reload is needed
-- Returns the descriptor as an opaque HANDLE; pass it to UnregisterGeneralToggle to
-- withdraw the toggle later (an enable-tied module does this on disable).
function SettingsWindow:RegisterGeneralToggle(desc)
    local p = self:_p()
    p.generalToggles = p.generalToggles or {}
    p.generalToggles[#p.generalToggles + 1] = desc
    self:_InvalidateGeneral()  -- reflect a toggle contributed after the window was built
    return desc
end

-- Withdraw a previously-registered toggle (by the handle RegisterGeneralToggle gave).
-- No-op if it isn't present. Rebuilds the General page if it's already on screen.
function SettingsWindow:UnregisterGeneralToggle(handle)
    local list = self:_p().generalToggles
    if not (handle and list) then return end
    for i = #list, 1, -1 do
        if list[i] == handle then table.remove(list, i); break end
    end
    self:_InvalidateGeneral()
end

-- Rebuild the General page from the CURRENT toggle list after a feature contributed or
-- withdrew one. Mirrors InvalidateModule: no-op until the window is built, and re-shows
-- the page if it's the one currently visible.
function SettingsWindow:_InvalidateGeneral()
    local p = self:_p()
    if not p.built then return end
    local old = p.pages and p.pages.general
    if old then old:Dispose() end
    p.pages.general = self:_BuildGeneralPage(p.content)
    if p.frame and p.frame:IsShown() and p.current == "general" then
        self:Show("general")
    end
end

-- ---- construction ---------------------------------------------------------
-- Internal, idempotent lazy build (the `_` prefix marks it private, like every other
-- builder); the public Show/Toggle/Open call it on first use.
function SettingsWindow:_Build()
    local p = self:_p()
    if p.built then return end

    -- shared chrome: movable HIGH-strata frame + draggable bar (title + version) + close X.
    local layout = self:_statics()
    local f = W.Window:New(600, { name = "HagAIOSettingsWindow",
        width = layout.windowWidth, height = layout.windowHeight,
        strata = "HIGH", title = "HAGAIO", subtitle = "v" .. tostring(ns.Meta.version),
        onClose = function() self:Hide() end,
        autoClose = true,   -- hide in combat / Edit Mode, reopen to the same page after
        onAutoShow = function()
            local key = p.reopenKey or p.current or "modules"
            p.reopenKey = nil
            self:Show(key)
        end,
    })
    local bar = f:Bar()
    p.frame = f

    -- left nav rail
    local nav = W.Panel:New(f, "bg0", "border", { highlight = true })
    nav:SetWidth(layout.navWidth)
    nav:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -1)
    nav:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 1, 1)

    local navLabel = W.SectionLabel:New(nav, "Navigation")
    navLabel:SetPoint("TOPLEFT", 16, -16)

    -- content area
    local content = W.Panel:New(f, "surface", "border")
    content:SetPoint("TOPLEFT", nav, "TOPRIGHT", 1, 0)
    content:SetPoint("BOTTOMRIGHT", -1, 1)
    p.content = content

    -- pages
    p.pages.modules  = self:_BuildModulesPage(content)
    p.pages.general  = self:_BuildGeneralPage(content)
    p.pages.profiles = self:_BuildProfilesPage(content)
    p.pages.log      = self:_BuildLogPage(content)
    p.pages.about    = self:_BuildAboutPage(content)

    -- nav items
    local defs = {
        { key = "general",  text = "General" },
        { key = "modules",  text = "Modules" },
        { key = "profiles", text = "Profiles" },
        { key = "log",      text = "Log" },
        { key = "about",    text = "About" },
    }
    local y = -48
    for _, d in ipairs(defs) do
        local item = W.NavItem:New(nav, d.text)
        item:SetPoint("TOPLEFT", nav, "TOPLEFT", 8, y)
        item:SetPoint("RIGHT", nav, "RIGHT", -8, 0)
        item:SetScript("OnClick", function() self:Show(d.key) end)
        p.nav[d.key] = item
        y = y - 42
    end

    -- live log updates while the Log page is open
    ns.EventBus:Subscribe("LOG_ADDED", function()
        if p.frame:IsShown() and p.current == "log" then
            self:_RefreshLog()
        end
    end)

    p.built = true
end

-- ---- pages ----------------------------------------------------------------
function SettingsWindow:_BuildModulesPage(parent)
    local page = W.Container:New(parent)
    page:SetAllPoints()

    local header = W.PageHeader:New(page, "Feature Modules",
        "Enable features and open their configuration panels.")
    header:SetPoint("TOPLEFT", 12, -12)
    header:SetPoint("TOPRIGHT", -12, -12)

    -- the rows live in a scroll area so a long module list scrolls (and clips) instead of spilling
    -- past the window. ScrollArea syncs its content width + clips the viewport for us.
    local sa = W.ScrollArea:New(page, "HagAIOModulesScroll")
    sa:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -12)
    sa:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -12, 12)

    local p = self:_p()
    p.moduleHolder = sa:Content()
    p.moduleScroll = sa
    p.moduleRows = {}
    return page
end

function SettingsWindow:_RefreshModules()
    local p = self:_p()
    local holder = p.moduleHolder
    for _, r in ipairs(p.moduleRows) do r:Dispose() end
    wipe(p.moduleRows)

    local mm = ns.ModuleManager
    if mm:Count() == 0 then
        local empty = W.Text:New(holder, "No feature modules registered yet.", "textFaint", "GameFontHighlight")
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

            local row = W.Panel:New(holder, "surfaceRaised", "border", {
                accent = module:IsEnabled(), accentKey = "accent",
            })
            row:SetPoint("TOPLEFT", 4, y)
            row:SetPoint("RIGHT", holder, "RIGHT", -4, 0)
            row:SetHeight(58)

            local toggle = W.Toggle:New(row, nil)
            toggle:SetPoint("LEFT", row, "LEFT", 16, 0)
            if module:IsAlwaysOn() then       -- mandatory: show it ticked but locked (no toggling)
                toggle:SetChecked(true)
                toggle:SetEnabled(false)
            else
                toggle:SetChecked(module:IsEnabled())
                toggle:SetEnabled(depsMet)
                toggle:SetOnToggle(function(on)
                    if on then module:Enable() else module:Disable() end
                    self:_RefreshModules()  -- dependents may need to grey/ungrey
                end)
            end

            local name = W.Text:New(row, module:GetTitle(), depsMet and "text" or "textFaint", "GameFontNormal")
            name:SetPoint("TOPLEFT", row, "TOPLEFT", 50, -12)

            local settings = W.Button:New(row, "Configure", { width = 92 })
            settings:SetPoint("RIGHT", row, "RIGHT", -14, 0)
            settings:SetOnClick(function() self:Show("module:" .. module:GetName()) end)

            local descText = module:GetDescription()
            if not depsMet then
                local deps = module:GetModuleDeps()
                descText = "Requires " .. table.concat(deps, ", ") .. " enabled."
            end
            local desc = W.Text:New(row, descText, "textFaint", "GameFontHighlightSmall")
            desc:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -3)
            desc:SetPoint("RIGHT", settings, "LEFT", -10, 0)
            desc:SetJustifyH("LEFT")

            p.moduleRows[#p.moduleRows + 1] = row
            y = y - 66
        end
    end
    -- size the scroll child to the rows so it scrolls when the list outgrows the viewport (the
    -- ScrollArea keeps the content WIDTH synced + shows/hides its bar from this height)
    holder:SetHeight(math.max(1, -y))
    if p.moduleScroll then p.moduleScroll:Update() end
end

-- Static "General" page: addon-wide options. Its contents are CONTRIBUTED by
-- features via RegisterGeneralToggle (e.g. the compartment / minimap icons) so
-- this page never references those features directly -- keeping the dependency
-- one-way (icons -> window) with no cycle.
function SettingsWindow:_BuildGeneralPage(parent)
    local p = self:_p()
    local page = W.Container:New(parent)
    page:SetAllPoints()

    local header = W.PageHeader:New(page, "General", "Addon-wide behaviour and integration options.")
    header:SetPoint("TOPLEFT", 12, -12)
    header:SetPoint("TOPRIGHT", -12, -12)

    local sa = W.ScrollArea:New(page, "HagAIOGeneralScroll")
    sa:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -12)
    sa:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -12, 12)
    local content = sa:Content()
    local width = content:GetWidth()
    if not width or width < 1 then width = 700 end

    local groups, byName = {}, {}
    for _, d in ipairs(p.generalToggles or {}) do
        if allServicesLoaded(d.visibleDeps) then  -- soft visibility dep: hide unless all listed services are loaded
            local section = d.section or "General"
            local group = byName[section]
            if not group then
                group = { title = section, settings = {} }
                groups[#groups + 1] = group
                byName[section] = group
            end
            group.settings[#group.settings + 1] = d
        end
    end

    local columns = width >= self:_statics().gridMinWidth and #groups > 1 and 2 or 1
    local gutter, sideInset = self:_statics().gridGutter, 4
    local panelWidth = math.floor((width - sideInset * 2 - (columns - 1) * gutter) / columns)
    local rendered = {}
    for _, group in ipairs(groups) do
        local panel = W.SettingsGroup:New(content, group.title, { collapsible = false })
        panel:SetWidth(panelWidth)
        local body, y = panel:GetContent(), 0
        for _, d in ipairs(group.settings) do
            local label = W.Text:New(body, d.reload and W.FlagReload(d.label) or d.label,
                "text", "GameFontHighlight")
            label:SetPoint("TOPLEFT", 2, y - 2)
            label:SetWidth(panelWidth - 76); label:SetJustifyH("LEFT")
            local toggle = W.Toggle:New(body, nil)
            toggle:SetPoint("TOPRIGHT", body, "TOPRIGHT", -2, y)
            toggle:SetChecked(d.get and d.get())
            toggle:SetOnToggle(function(on)
                local needsReload = d.set and d.set(on)
                if needsReload and d.reloadMsg then self:LogWarn(d.reloadMsg) end
            end)
            y = y - 26
            if d.desc and d.desc ~= "" then
                local desc = W.Text:New(body, d.desc, "textFaint", "GameFontHighlightSmall")
                desc:SetPoint("TOPLEFT", 2, y)
                desc:SetWidth(panelWidth - 46)
                desc:SetJustifyH("LEFT")
                y = y - desc:GetStringHeight() - 12
            else
                y = y - 8
            end
        end
        panel:SetContentHeight(math.max(18, -y))
        rendered[#rendered + 1] = { panel = panel, height = panel:GetHeight() }
    end

    local y = -4
    for first = 1, #rendered, columns do
        local rowHeight = 0
        for i = first, math.min(#rendered, first + columns - 1) do
            rowHeight = math.max(rowHeight, rendered[i].height)
        end
        for i = first, math.min(#rendered, first + columns - 1) do
            local column = i - first
            rendered[i].panel:SetHeight(rowHeight)
            rendered[i].panel:SetPoint("TOPLEFT", content, "TOPLEFT",
                sideInset + column * (panelWidth + gutter), y)
        end
        y = y - rowHeight - gutter
    end
    if #rendered == 0 then
        local empty = W.Text:New(content, "No addon-wide options are available.", "textFaint", "GameFontHighlightSmall")
        empty:SetPoint("TOPLEFT", 8, -8)
        y = -32
    end
    content:SetHeight(math.max(30, -y + 4))
    return page
end

-- ---- Profiles page --------------------------------------------------------
function SettingsWindow:_BuildProfilesPage(parent)
    local p = self:_p()
    local page = W.Container:New(parent)
    page:SetAllPoints()

    local header = W.PageHeader:New(page, "Profiles",
        "Save, switch and share complete configuration sets.")
    header:SetPoint("TOPLEFT", 12, -12)
    header:SetPoint("TOPRIGHT", -12, -12)

    local savePanel = W.SettingsGroup:New(page, "Save or Import", { collapsible = false })
    savePanel:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -12)
    savePanel:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -12)
    local saveBody = savePanel:GetContent()

    -- save-current row
    local saveLabel = W.Text:New(saveBody, "Save current configuration as", "textDim", "GameFontHighlightSmall")
    saveLabel:SetPoint("TOPLEFT", 2, 0)
    local input = W.Input:New(saveBody, 220)
    input:SetPoint("TOPLEFT", 0, -20)
    local save = W.Button:New(saveBody, "Save", { width = 72 })
    save:SetPoint("LEFT", input, "RIGHT", 16, 0)
    save:SetOnClick(function()
        local name = input:GetValue()
        if name and name ~= "" then
            ns.Profiles:Save(name)
            input:SetValue("")
            self:LogSuccess("saved profile '" .. name .. "'")
            self:_RefreshProfilesPage()
        end
    end)
    local import = W.Button:New(saveBody, "Import", { width = 82 })
    import:SetPoint("LEFT", save, "RIGHT", 24, 0)
    import:SetOnClick(function()
        ns.UI.CopyWindow:Prompt("Paste a profile string, then Import", function(text)
            local ok, res = ns.Profiles:Import(text, "Imported")
            if ok then
                self:LogSuccess("imported as '" .. res .. "'")
                self:_RefreshProfilesPage()
            else
                self:LogWarn("import failed: " .. tostring(res))
            end
        end)
    end)
    local profileNote = W.Text:New(saveBody,
        "Loading applies after /reload. Global profiles become the default for characters without a selection.",
        "textFaint", "GameFontHighlightSmall")
    profileNote:SetPoint("LEFT", import, "RIGHT", 18, 0)
    profileNote:SetPoint("RIGHT", saveBody, "RIGHT", 0, 0)
    profileNote:SetJustifyH("LEFT")
    savePanel:SetContentHeight(50)

    local listLabel = W.SectionLabel:New(page, "Saved profiles")
    listLabel:SetPoint("TOPLEFT", savePanel, "BOTTOMLEFT", 4, -18)

    -- the saved-profile list is a grid: a flex name column, then a Global checkbox column (the
    -- header names it -- no per-row label) and the Load / Export / Delete action columns.
    local grid = W.Grid:New(page, { name = "HagAIOProfilesGrid", header = true, striped = true,
        rowHeight = 26, columns = {
            { width = nil, label = "" },                      -- profile name (flex)
            { width = 58, label = "Global", justify = "CENTER" },
            { width = 50, label = "" },                       -- Load
            { width = 62, label = "" },                       -- Export
            { width = 62, label = "" },                       -- Delete
        } })
    grid:SetPoint("TOPLEFT", listLabel, "BOTTOMLEFT", -4, -8)
    grid:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -12, 12)
    p.profileGrid = grid

    local empty = W.Text:New(page, "No profiles yet.", "textFaint", "GameFontHighlightSmall")
    empty:SetPoint("TOPLEFT", grid, "TOPLEFT", 4, -30)
    p.profileEmpty = empty

    page:SetScript("OnShow", function() self:_RefreshProfilesPage() end)
    return page
end

-- Per-row interactive widgets for a profile (Global checkbox + Load/Export/Delete), placed at
-- the grid's column x's. Created once per pooled row and re-bound to `name` on every refresh.
function SettingsWindow:_ProfileRowControls(row, xs, name)
    if not row.pInit then
        row.gCheck   = W.Toggle:New(row, nil)        -- no label: the column header reads "Global"
        row.loadBtn  = W.TextButton:New(row, "Load")
        row.expBtn   = W.TextButton:New(row, "Export")
        row.delBtn   = W.TextButton:New(row, "Delete")
        row.pInit = true
    end
    row.gCheck:ClearAllPoints(); row.gCheck:SetPoint("LEFT", xs[2] + 20, 0)  -- centred in the column
    row.gCheck:SetChecked(ns.Profiles:IsGlobal(name))
    -- Exclusive flag: ticking one clears any other; unticking leaves none.
    row.gCheck:SetOnToggle(function(on)
        ns.Profiles:SetGlobal(on and name or nil)
        self:_RefreshProfilesPage()
    end)
    row.loadBtn:ClearAllPoints(); row.loadBtn:SetPoint("LEFT", xs[3], 0)
    row.loadBtn:SetScript("OnClick", function()
        local ok, err = ns.Profiles:LoadProfile(name)
        if ok then self:LogSuccess(("loaded '%s' -- type /reload to apply"):format(name))
        else self:LogWarn(err or "load failed") end
    end)
    row.expBtn:ClearAllPoints(); row.expBtn:SetPoint("LEFT", xs[4], 0)
    row.expBtn:SetScript("OnClick", function()
        local str, err = ns.Profiles:Export(name)
        if str then ns.UI.CopyWindow:Show("Profile - " .. name, str)
        else self:LogWarn(err or "export failed") end
    end)
    row.delBtn:ClearAllPoints(); row.delBtn:SetPoint("LEFT", xs[5], 0)
    row.delBtn:SetScript("OnClick", function()
        ns.Profiles:Delete(name)
        self:_RefreshProfilesPage()
    end)
end

-- Rebuild the saved-profile list (cheap; called on show + after save/delete/import).
function SettingsWindow:_RefreshProfilesPage()
    local p = self:_p()
    if not p.profileGrid then return end
    local names = ns.Profiles and ns.Profiles:List() or {}
    p.profileEmpty:SetShown(#names == 0)
    local rows = {}
    for _, name in ipairs(names) do
        rows[#rows + 1] = {
            cells = { name, "", "", "", "" },
            controls = function(row, xs) self:_ProfileRowControls(row, xs, name) end,
        }
    end
    p.profileGrid:SetRows(rows)
end

-- Drop a module's cached settings page so it rebuilds from the CURRENT schema
-- (e.g. a module changed its settings dynamically, like a Monk spec swap). If the
-- page is on screen, rebuild and re-show it immediately.
function SettingsWindow:InvalidateModule(name)
    local p = self:_p()
    if not p.built then return end
    local page = p.modulePages[name]
    if not page then return end
    page:Dispose()   -- cascade teardown: drops every control's EventBus subscription, then hides
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

    local page = W.Container:New(p.content)   -- a widget so :Dispose tears its whole control tree down
    page:SetAllPoints()

    local header = W.PageHeader:New(page, module:GetTitle(), module:GetDescription())
    header:SetPoint("TOPLEFT", 12, -12)
    header:SetPoint("TOPRIGHT", -12, -12)
    local actions = header:Actions()

    -- enable toggle on the header row -- omitted for a mandatory (always-on) module, which shows a
    -- faint "Always on" tag instead since it can't be turned off.
    local enable
    if module:IsAlwaysOn() then
        local tag = W.Text:New(actions, "ALWAYS ON", "green", "GameFontHighlightSmall")
        tag:SetPoint("RIGHT", actions, "RIGHT", 0, 0)
    else
        enable = W.Toggle:New(actions, "Enabled")
        enable:SetPoint("RIGHT", actions, "RIGHT", -58, 0)
        enable:SetChecked(module:IsEnabled())
        enable:SetOnToggle(function(on)
            if on then module:Enable() else module:Disable() end
        end)
    end

    -- the framework hands every module page our themed scroll area, so a module's BuildSettingsPage
    -- just fills sf:Content() and never defines a scrollbar of its own.
    local sf = W.ScrollArea:New(page, "HagAIOModule" .. name:gsub("%s", "") .. "Scroll")
    sf:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -12)
    sf:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -12, 12)

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

-- A dependency state belongs to one settings host, but is shared by all of that host's visual
-- sections. A dependency may therefore cross a column without losing its parent widget.
function SettingsWindow:_NewSchemaState(host)
    local schema = host:GetSettings()
    local graph = ns.DependencyGraph:New()
    for _, s in ipairs(schema) do
        if s.key and (s.type == ns.SettingType.TOGGLE or s.type == ns.SettingType.SELECT
            or s.type == ns.SettingType.DROPDOWN or s.type == ns.SettingType.COLOR) then
            graph:Add(s.key, function() return host:GetSetting(s.key) and true or false end, s.dependsOn)
        end
    end
    local ok, issues = graph:Validate()
    if not ok then
        -- A malformed dependsOn graph is a schema bug -- warn through the host's own channel (so it
        -- lands in that module's Log), or the Core channel if the host has none (a Submodule logging
        -- through its host). Hoisted: the host's channel doesn't change across the issue list.
        local hosted = host.LogWarn and host:GetLog()
        for _, msg in ipairs(issues) do
            local line = "settings dependency: " .. msg
            if hosted then host:LogWarn(line) else ns.Logger:Core():Warn(line) end
        end
    end

    return { graph = graph, controls = {}, pending = {} }
end

-- Turn a host schema into semantic layout blocks. Headers start named blocks; the caller supplies a
-- neutral fallback panel title for unheaded module settings, while a submodule title names its block.
function SettingsWindow:_AppendSchemaBlocks(blocks, host, fallbackTitle)
    local current
    for _, s in ipairs(host:GetSettings()) do
        local rule = s.visibleWhen
        local value = rule and host:GetSetting(rule.key)
        local visible = not rule or (rule.equals ~= nil and value == rule.equals)
            or (rule.notEquals ~= nil and value ~= rule.notEquals)
        if visible then
            if s.type == ns.SettingType.HEADER then
                current = { host = host, title = s.text, settings = {} }
                blocks[#blocks + 1] = current
            else
                if not current then
                    current = { host = host, title = fallbackTitle, settings = {} }
                    blocks[#blocks + 1] = current
                end
                current.settings[#current.settings + 1] = s
            end
        end
    end
end

-- Render the controls inside one semantic section. The section heading and inter-section divider
-- are owned by the grid layout, keeping row spacing independent of column placement.
function SettingsWindow:_RenderSchemaBlock(content, block, width, y, pageName, state)
    local host = block.host
    local controls, pending = state.controls, state.pending

    local groupOpen = false
    for _, s in ipairs(block.settings) do
        local keyed = s.type == ns.SettingType.TOGGLE
            or s.type == ns.SettingType.SELECT
            or s.type == ns.SettingType.DROPDOWN
            or s.type == ns.SettingType.COLOR
        if keyed then
            if s.dependsOn then
                -- Subsettings belong visually to the option above them: indent
                -- them and leave enough air that their labels don't collide.
                y = y - 10
            elseif groupOpen then
                -- These are settings within the same named section, so use only
                -- a modest gap. Dividers belong exclusively between section labels.
                y = y - 10
            end
            if not s.dependsOn then groupOpen = true end
        end

        if s.type == ns.SettingType.NOTE then
            local n = W.Text:New(content, s.text, "textDim", "GameFontHighlightSmall")
            n:SetPoint("TOPLEFT", 4, y)
            n:SetWidth(width - 16)
            n:SetJustifyH("LEFT")
            y = y - (n:GetStringHeight() + 12)

        elseif s.type == ns.SettingType.TOGGLE then
            local x = s.dependsOn and 20 or 2
            local lbl = W.Text:New(content, s.reload and W.FlagReload(s.label) or s.label,
                "text", "GameFontHighlight")
            lbl:SetPoint("TOPLEFT", x, y - 2)
            lbl:SetWidth(width - x - 48); lbl:SetJustifyH("LEFT")
            local t = W.Toggle:New(content, nil)
            t:SetPoint("TOPRIGHT", content, "TOPRIGHT", -2, y)
            t:SetChecked(host:GetSetting(s.key) and true or false)
            t:SetOnToggle(function(on) host:SetSetting(s.key, on) end)
            if s.key then controls[s.key] = t end
            if s.dependsOn then pending[#pending + 1] = { w = t, key = s.key, on = s.dependsOn } end
            y = y - 24
            if s.desc then
                local d = W.Text:New(content, s.desc, "textFaint", "GameFontHighlightSmall")
                d:SetPoint("TOPLEFT", x, y)
                d:SetWidth(width - x - 12)
                d:SetJustifyH("LEFT")
                y = y - (d:GetStringHeight() + 10)
            else
                y = y - 4
            end

        elseif s.type == ns.SettingType.SELECT then
            local lbl = W.Text:New(content, s.reload and W.FlagReload(s.label) or s.label, "text", "GameFontHighlight")
            local x = s.dependsOn and 20 or 2
            local seg = W.Segmented:New(content, s.options)
            if lbl:GetStringWidth() + seg:GetWidth() + 26 <= width - x then
                lbl:SetPoint("TOPLEFT", x, y - 5)
                seg:SetPoint("TOPRIGHT", content, "TOPRIGHT", -2, y)
                y = y - 32
            else
                lbl:SetPoint("TOPLEFT", x, y)
                seg:SetPoint("TOPLEFT", x, y - 22)
                y = y - 54
            end
            seg:SetValue(host:GetSetting(s.key))
            seg:SetOnChange(function(v) host:SetSetting(s.key, v) end)
            if s.key then controls[s.key] = seg end
            if s.dependsOn then pending[#pending + 1] = { w = seg, key = s.key, on = s.dependsOn } end

        elseif s.type == ns.SettingType.DROPDOWN then
            local lbl = W.Text:New(content, s.reload and W.FlagReload(s.label) or s.label, "text", "GameFontHighlight")
            local x = s.dependsOn and 20 or 2
            local dropdown = W.Dropdown:New(content, s.options, s.placeholder)
            local dropdownWidth = math.min(s.width or 156, math.floor(width * 0.58))
            dropdown:SetWidth(dropdownWidth)
            if lbl:GetStringWidth() + dropdownWidth + 26 <= width - x then
                lbl:SetPoint("TOPLEFT", x, y - 5)
                dropdown:SetPoint("TOPRIGHT", content, "TOPRIGHT", -2, y)
                y = y - 34
            else
                lbl:SetPoint("TOPLEFT", x, y)
                dropdown:SetPoint("TOPLEFT", x, y - 22)
                y = y - 58
            end
            dropdown:SetValue(host:GetSetting(s.key))
            dropdown:SetOnChange(function(value)
                host:SetSetting(s.key, value)
                -- Rebuild after the selection callback. The new page includes
                -- exactly the ordinary rows belonging to the newly selected variant.
                ns.Scheduler:After(0, function() self:InvalidateModule(pageName) end)
            end)
            if s.key then controls[s.key] = dropdown end
            if s.dependsOn then pending[#pending + 1] = { w = dropdown, key = s.key, on = s.dependsOn } end

        elseif s.type == ns.SettingType.COLOR then
            local lbl = W.Text:New(content, s.label, "text", "GameFontHighlight")
            local x = s.dependsOn and 20 or 2
            lbl:SetPoint("TOPLEFT", x, y - 2)
            lbl:SetWidth(width - x - 58)
            lbl:SetJustifyH("LEFT")
            local sw = W.ColorSwatch:New(content)
            sw:SetPoint("TOPRIGHT", content, "TOPRIGHT", -2, y)
            -- Colours are ns.Color values (override/profile/code default); the swatch keeps its
            -- r,g,b API, so unpack going in and re-wrap the picked colour going out.
            local c = host:GetSetting(s.key) or s.default or ns.Color:New(1, 1, 1)
            sw:SetColor(c:Unpack())
            sw:SetOnChange(function(r, g, b) host:SetSetting(s.key, ns.Color:New(r, g, b)) end)
            if s.default then sw:SetDefault(s.default:Unpack()) end
            if s.key then controls[s.key] = sw end
            if s.dependsOn then pending[#pending + 1] = { w = sw, key = s.key, on = s.dependsOn } end
            y = y - 30
        end
    end

    return y
end

function SettingsWindow:_WireSchemaState(state)
    -- Wire each dependent to watch its PARENT widget(s): when a parent changes it re-checks the graph
    -- (and the EnableWhen cascade carries transitive chains). Targeted -- only the widgets it depends on.
    for _, d in ipairs(state.pending) do
        local parents = {}
        for _, key in ipairs(type(d.on) == "table" and d.on or { d.on }) do
            if state.controls[key] then parents[#parents + 1] = state.controls[key] end
        end
        d.w:EnableWhen(parents, function() return state.graph:IsSatisfied(d.key) end)
    end
end

-- A module page = the module's own schema, then the settings of every CONFIGURABLE submodule of
-- that module. Settings content is never gated on the module's enable state: a submodule's
-- options show whenever the submodule COULD load (its condition + availability deps hold),
-- whether or not the parent module is enabled -- e.g. the ATT submodule's option shows when
-- AllTheThings is installed, regardless of whether the parent module is on. No addon checks here.
function SettingsWindow:_BuildModuleControls(sf, module)
    local content = sf:Content()
    local width = content:GetWidth()   -- the scroll area keeps the content width synced for us
    if not width or width < 1 then width = 420 end

    local blocks, states = {}, {}
    if #module:GetSettings() > 0 then
        self:_AppendSchemaBlocks(blocks, module, "Options")
        states[module] = self:_NewSchemaState(module)
    end

    local subs = ns.SubmoduleManager and ns.SubmoduleManager:ConfigurableChildrenOf(module:GetName()) or {}
    for _, sub in ipairs(subs) do
        if sub.GetSettings and #sub:GetSettings() > 0 then
            self:_AppendSchemaBlocks(blocks, sub, sub:GetTitle())
            states[sub] = self:_NewSchemaState(sub)
        end
    end

    if #blocks == 0 then
        local none = W.Text:New(content, "This module has no options.", "textFaint", "GameFontHighlightSmall")
        none:SetPoint("TOPLEFT", 4, -4)
        content:SetHeight(30)
        return
    end

    -- Named sections become application panels. Their internal controls keep a single vertical
    -- sequence, while the panels themselves follow a predictable left-to-right row order.
    local layout = self:_statics()
    local grid = width >= layout.gridMinWidth and #blocks > 1
    local columns = grid and 2 or 1
    local sideInset = 4
    local available = width - sideInset * 2
    local columnWidth = grid and math.floor((available - layout.gridGutter) / 2) or available
    local rendered = {}
    for _, block in ipairs(blocks) do
        local panel = W.SettingsGroup:New(content, block.title or "Options", {
            collapsible = false, shadow = true,
        })
        panel:SetWidth(columnWidth)
        local body = panel:GetContent()
        local bodyWidth = columnWidth - 28
        local y = self:_RenderSchemaBlock(body, block, bodyWidth, 0, module:GetName(), states[block.host])
        panel:SetContentHeight(math.max(18, -y))
        rendered[#rendered + 1] = { panel = panel, height = panel:GetHeight() }
    end

    local y = -4
    for first = 1, #rendered, columns do
        local rowHeight = 0
        for i = first, math.min(#rendered, first + columns - 1) do
            rowHeight = math.max(rowHeight, rendered[i].height)
        end
        for i = first, math.min(#rendered, first + columns - 1) do
            local column = i - first
            local entry = rendered[i]
            entry.panel:SetHeight(rowHeight)
            entry.panel:SetPoint("TOPLEFT", content, "TOPLEFT",
                sideInset + column * (columnWidth + layout.gridGutter), y)
        end
        y = y - rowHeight - layout.gridGutter
    end

    for _, state in pairs(states) do self:_WireSchemaState(state) end
    content:SetHeight(math.max(30, -y + 4))
end

function SettingsWindow:_BuildLogPage(parent)
    local page = W.Container:New(parent)
    page:SetAllPoints()

    local header = W.PageHeader:New(page, "Activity Log",
        "Every module report is recorded here automatically.", { actionsWidth = 430 })
    header:SetPoint("TOPLEFT", 12, -12)
    header:SetPoint("TOPRIGHT", -12, -12)
    local actions = header:Actions()

    local clear = W.Button:New(actions, "Clear", { width = 66 })
    clear:SetPoint("RIGHT", actions, "RIGHT", 0, 8)
    clear:SetOnClick(function()
        ns.Logger:Clear()
        self:_RefreshLog()
    end)

    local echo = W.Toggle:New(actions, "Echo to chat")
    echo:SetPoint("RIGHT", clear, "LEFT", -98, 8)
    echo:SetChecked(ns.Logger:GetEcho())
    echo:SetOnToggle(function(on) ns.Logger:SetEcho(on) end)

    -- Which reports reach chat while "Echo to chat" is on (the Logger's persisted level
    -- threshold -- forced lines like errors marked always-show still get through).
    local lvlLabel = W.Text:New(actions, "Chat shows", "textDim", "GameFontHighlightSmall")
    lvlLabel:SetPoint("BOTTOMLEFT", actions, "BOTTOMLEFT", 0, 0)
    local lvl = W.Segmented:New(actions, {
        { value = ns.LogLevel.INFO:Order(), text = "Everything" },
        { value = ns.LogLevel.WARN:Order(), text = "Warnings" },
        { value = ns.LogLevel.ERROR:Order(), text = "Errors only" },
    })
    lvl:SetPoint("LEFT", lvlLabel, "RIGHT", 10, 0)
    lvl:SetValue(ns.Logger:GetMinLevel())
    lvl:SetOnChange(function(v) ns.Logger:SetMinLevel(v) end)

    local sf = W.ScrollArea:New(page, "HagAIOLogScroll")
    sf:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -12)
    sf:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -12, 12)

    -- PLAIN text lines (one pooled FontString per entry) with a TextSelection overlay: drag to
    -- select per character across lines, then Ctrl+C copies the selection -- like any text editor.
    local sel = W.TextSelection:New(sf:Content())

    local p = self:_p()
    p.logSel = sel
    p.logSF = sf
    p.logLines = {}
    sf:SetScript("OnSizeChanged", function() self:_RefreshLog() end)
    return page
end

function SettingsWindow:_RefreshLog()
    local p = self:_p()
    if not p.logSel then return end
    local h = ns.Logger:GetHistory(200)   -- only the window we render -- no need to copy the full history
    local content = p.logSF:Content()
    local width = content:GetWidth()
    if not width or width < 1 then width = 380 end

    local startIdx = math.max(1, #h - 200)
    local lines, n, y = {}, 0, 0
    for i = startIdx, #h do
        local e = h[i]
        n = n + 1
        local fs = p.logLines[n]
        if not fs then
            fs = W.Text:New(content, "", "text", "GameFontHighlightSmall")
            p.logLines[n] = fs
        end
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
        -- SINGLE-ROW lines (no wrap): the selection's per-character maths has no row model
        fs:SetWidth(width); fs:SetJustifyH("LEFT"); fs:SetWordWrap(false)
        local line = ns.Logger:Line(e)   -- lazily formatted on first view
        fs:SetText(line)
        fs:Show()
        y = y - (fs:GetStringHeight() or 12) - 3
        -- the selection's plain text = EXACTLY the visible characters (escapes stripped), so the
        -- per-character hit maths lines up with the coloured display glyph for glyph
        lines[n] = { region = fs, text = line:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") }
    end
    if n == 0 then
        n = 1
        local fs = p.logLines[1]
        if not fs then fs = W.Text:New(content, "", "text", "GameFontHighlightSmall"); p.logLines[1] = fs end
        fs:ClearAllPoints(); fs:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
        fs:SetWidth(width); fs:SetJustifyH("LEFT")
        fs:SetText("|cff" .. Theme.hex.textFaint .. "No activity yet.|r")
        fs:Show()
        y = -14
    end
    for i = n + 1, #p.logLines do p.logLines[i]:Hide() end
    p.logSel:SetLines(lines)
    content:SetHeight(math.max(1, -y + 8))
end

function SettingsWindow:_BuildAboutPage(parent)
    local page = W.Container:New(parent)
    page:SetAllPoints()

    local header = W.PageHeader:New(page, "HagAIO",
        "A modular all-in-one toolkit for World of Warcraft.")
    header:SetPoint("TOPLEFT", 12, -12)
    header:SetPoint("TOPRIGHT", -12, -12)

    local product = W.SettingsGroup:New(page, "Product", { collapsible = false })
    product:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -12)
    product:SetWidth(342)
    local productBody = product:GetContent()
    local ver = W.Text:New(productBody,
        "Version " .. tostring(ns.Meta.version) .. "   |cff5b6473|||r   Midnight 12.0.x",
        "accent", "GameFontHighlight")
    ver:SetPoint("TOPLEFT", 0, 0)
    local desc = W.Text:New(productBody,
        "Feature modules share one framework, profile system, activity log and interface.",
        "textDim", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", ver, "BOTTOMLEFT", 0, -12)
    desc:SetWidth(310); desc:SetJustifyH("LEFT")
    local author = W.Text:New(productBody, "Created by Hagryph", "text", "GameFontHighlight")
    author:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -16)
    local repo = W.Text:New(productBody, "github.com/Hagryph/HagAIO", "textFaint", "GameFontHighlightSmall")
    repo:SetPoint("TOPLEFT", author, "BOTTOMLEFT", 0, -6)
    product:SetContentHeight(112)

    local commands = W.SettingsGroup:New(page, "Commands", { collapsible = false })
    commands:SetPoint("TOPLEFT", product, "TOPRIGHT", 16, 0)
    commands:SetPoint("RIGHT", header, "RIGHT", 0, 0)
    commands:SetHeight(product:GetHeight())
    local commandBody = commands:GetContent()
    local list = W.Text:New(commandBody,
        "/hag  -  open this panel\n/hag log  -  open the activity log\n/hag modules  -  list modules\n/hag help  -  all commands",
        "textDim", "GameFontHighlightSmall")
    list:SetPoint("TOPLEFT", 0, 0)
    list:SetJustifyH("LEFT")
    list:SetSpacing(5)
    commands:SetContentHeight(112)
    return page
end

-- ---- show / hide ----------------------------------------------------------
function SettingsWindow:Show(key)
    self:_Build()
    local p = self:_p()
    key = key or p.current or "modules"

    -- Defer opening during combat or Edit Mode; it opens again afterwards.
    local editActive = EditModeManagerFrame and EditModeManagerFrame.IsEditModeActive
        and EditModeManagerFrame:IsEditModeActive()
    if not p.frame:IsShown() and (InCombatLockdown() or editActive) then
        p.reopenKey = key
        p.frame.__autoReopen = true   -- the factory's auto-close resume reopens it afterwards
        if InCombatLockdown() then
            self:LogWarn("In combat - the settings will open when you leave combat.")
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
        ns.Scheduler:After(0, function() self:_RefreshLog() end)
    end
    p.frame:Show()
end

function SettingsWindow:Hide()
    local p = self:_p()
    if p.frame then p.frame:Hide() end
end

function SettingsWindow:Toggle()
    self:_Build()
    local p = self:_p()
    if p.frame:IsShown() then self:Hide() else self:Show(p.current or "modules") end
end

ns.ServiceManager:Register(SettingsWindow:New("SettingsWindow", {
    ui = true,
    deps = { "EventBus", "SlashCommand", "Profiles", "CopyWindow", "Scheduler" },   -- Scheduler: the deferred log re-measure
    commands = {
        config = { handler = function(self) self:Toggle() end, help = "open the settings window" },
        log    = { handler = function(self) self:Show("log") end, help = "open the activity log" },
    },
}))
