local addonName, ns = ...
local Class = ns.Class
local Theme = ns.Theme
local W = ns.UI.Widgets

-- Modules/CVars.lua
-- Force chosen console variables on every character. Blizzard stores many CVars
-- per character; this module saves your chosen values account-wide (its DB is
-- global) and re-applies them at each login.
--
-- The settings page shows a CURATED set of useful CVars, grouped into
-- collapsible categories so the list stays short (expand only what you need).
-- Each control is typed -- a toggle for on/off CVars, a number box, a text box,
-- or a pick-one row -- and bound live to the game. You can also add ANY CVar by
-- name under "Custom": the module looks it up, works out whether it's a
-- boolean / number / text value, and renders the matching field.
--
-- The /hag cvar command still works for power users:
--   /hag cvar dump [filter]    list CVars (name = value [default]); filter by substring
--   /hag cvar set <name> <v>   set a CVar AND globalise it (re-applied every login)
--   /hag cvar get <name>       show a CVar's value / default / scope
--   /hag cvar clear <name>     stop globalising a CVar (its current value is kept)
--   /hag cvar list             show the CVars this module is globalising

local CVars = Class.new("CVars", ns.Module)

local DUMP_CAP = 120  -- /hag cvar dump: don't flood the log above this; ask to narrow

-- ---- curated dataset ------------------------------------------------------
-- Useful, broadly-stable CVars grouped by category, adapted from the community
-- AdvancedInterfaceOptions list. type drives the control: "boolean" -> toggle,
-- "number" -> number box, "string" -> text box, plus `options` -> pick-one row.
-- Any entry whose CVar doesn't exist on the current client is skipped silently,
-- so a stale name is harmless.
local CURATED = {
    { name = "Camera", cvars = {
        { name = "cameraDistanceMaxZoomFactor", label = "Max zoom distance", type = "number",
          desc = "How far you can zoom the camera out (1 = default, up to ~2.6)." },
        { name = "cameraYawMoveSpeed",  label = "Turn speed",  type = "number", desc = "How fast the camera turns left/right." },
        { name = "cameraPitchMoveSpeed", label = "Tilt speed", type = "number", desc = "How fast the camera tilts up/down." },
        { name = "cameraWaterCollision", label = "Water collision", type = "boolean", desc = "Stop the camera from dipping underwater." },
        { name = "cameraSmoothStyle", label = "Follow camera", type = "number", desc = "0 off, 1 horizontal, 2 full auto-follow." },
    }},
    { name = "Nameplates", cvars = {
        { name = "nameplateShowFriends", label = "Show friendly", type = "boolean", desc = "Nameplates on friendly units." },
        { name = "nameplateShowEnemies", label = "Show enemies", type = "boolean", desc = "Nameplates on enemy units." },
        { name = "nameplateShowAll", label = "Always show", type = "boolean", desc = "Keep nameplates up without holding the key." },
        { name = "nameplateMaxDistance", label = "View distance", type = "number", desc = "How far away nameplates appear." },
        { name = "nameplateGlobalScale", label = "Scale", type = "number", desc = "Overall nameplate size." },
        { name = "nameplateMinAlpha", label = "Min transparency", type = "number", desc = "Transparency of distant nameplates (0-1)." },
        { name = "nameplateOverlapV", label = "Vertical spacing", type = "number", desc = "Gap between stacked nameplates." },
    }},
    { name = "Combat & targeting", cvars = {
        { name = "stopAutoAttackOnTargetChange", label = "Stop attack on swap", type = "boolean",
          desc = "Stop auto-attacking when you switch targets." },
        { name = "SpellQueueWindow", label = "Spell queue (ms)", type = "number", desc = "How early the next spell can be queued." },
        { name = "enableFloatingCombatText", label = "Floating combat text", type = "boolean", desc = "Show floating combat text." },
        { name = "floatingCombatTextCombatDamage", label = "Damage numbers", type = "boolean", desc = "Show outgoing damage numbers." },
        { name = "floatingCombatTextCombatHealing", label = "Healing numbers", type = "boolean", desc = "Show healing numbers." },
    }},
    { name = "Looting", cvars = {
        { name = "autoLootDefault", label = "Auto loot", type = "boolean", desc = "Loot corpses automatically." },
        { name = "lootUnderMouse", label = "Loot at cursor", type = "boolean", desc = "Open the loot window at the mouse cursor." },
    }},
    { name = "Action bars", cvars = {
        { name = "ActionButtonUseKeyDown", label = "Cast on key down", type = "boolean", desc = "Trigger abilities on press, not release." },
        { name = "lockActionBars", label = "Lock bars", type = "boolean", desc = "Lock action buttons in place." },
        { name = "alwaysShowActionBars", label = "Always show bars", type = "boolean", desc = "Show empty action bar slots." },
        { name = "countdownForCooldowns", label = "Cooldown numbers", type = "boolean", desc = "Show countdown text on cooldowns." },
    }},
    { name = "Interface", cvars = {
        { name = "UnitNameOwn", label = "Show own name", type = "boolean", desc = "Show your own name above your character." },
        { name = "showTutorials", label = "Tutorials", type = "boolean", desc = "Show tutorial popups." },
        { name = "scriptErrors", label = "Lua errors", type = "boolean", desc = "Show Lua error popups." },
        { name = "autoQuestWatch", label = "Auto-track quests", type = "boolean", desc = "Track quests automatically when accepted." },
        { name = "trackQuestSorting", label = "Quest sorting", type = "string",
          options = { { value = "proximity", text = "Nearest" }, { value = "top", text = "Newest" } },
          desc = "How the objective tracker orders quests." },
    }},
    { name = "Sound", cvars = {
        { name = "Sound_MasterVolume", label = "Master volume", type = "number", desc = "Overall game volume (0-1)." },
        { name = "Sound_EnableMusic", label = "Music", type = "boolean", desc = "Play music." },
        { name = "Sound_EnableSFX", label = "Sound effects", type = "boolean", desc = "Play sound effects." },
        { name = "Sound_EnableAmbience", label = "Ambience", type = "boolean", desc = "Play ambient sounds." },
        { name = "Sound_EnableErrorSpeech", label = "Error speech", type = "boolean", desc = "Play spoken error lines." },
    }},
    { name = "Graphics", cvars = {
        { name = "ffxGlow", label = "Full-screen glow", type = "boolean", desc = "Soft bloom/glow effect." },
        { name = "ffxDeath", label = "Death desaturation", type = "boolean", desc = "Drain colour from the screen while dead." },
        { name = "weatherDensity", label = "Weather density", type = "number", desc = "Amount of weather effects (0-3)." },
    }},
}

-- Derived from CURATED, the single source of the code catalog:
--   CATALOG[name]   -> the full curated def (label/type/desc/options); also "is this CVar code-managed?"
--   ORDER[name]     -> its position in code order (sorts a category's rows the way the code lists them)
--   CAT_ORDER[name] -> a category's position in code order (sorts the category list; non-code last)
local CATALOG, ORDER, CAT_ORDER = {}, {}, {}
do
    local i = 0
    for ci, cat in ipairs(CURATED) do
        CAT_ORDER[cat.name] = ci
        for _, c in ipairs(cat.cvars) do
            i = i + 1
            CATALOG[c.name] = c
            ORDER[c.name] = i
        end
    end
end

-- Broadly-known, hand-set CVars (none in the curated list) offered as the add-field placeholder. The
-- example shown is the first of these that ACTUALLY EXISTS on the current client -- CVar availability
-- shifts between builds, so we never advertise a dead name.
local EXAMPLE_CVARS = { "WorldTextScale_v2", "WorldTextScale", "removeChatDelay", "nameplateMotionSpeed", "chatStyle" }

-- ---- lifecycle ------------------------------------------------------------
function CVars:OnInitialize()
    local p = self:_p()
    p.sections = {}
    -- Forced CVars (cvar_managed: name -> value) and the tracked-CVar catalog (cvar_tracked: every
    -- curated + custom CVar) live in the shared DB; see the DAO below. The tracked catalog is synced
    -- (backfill new code CVars + prune ones the client lost) once per session, off the loading screen,
    -- here at init so it stays current even while the module is disabled. /hag cvar declared on registration.
    self:_ScheduleSync()
end

-- ---- persistence (cvar_managed: name -> forced value; cvar_tracked: name -> control type) ------
function CVars:_IsManaged(name)
    local db = self:DB(); if not db then return false end
    return #db:Select("name"):From("cvar_managed"):Where("name", "=", name):Limit(1):Run() > 0
end
function CVars:_ManagedValue(name)
    local db = self:DB(); if not db then return nil end
    local r = db:Select("value"):From("cvar_managed"):Where("name", "=", name):Limit(1):Run()[1]
    return r and r.value or nil
end
function CVars:_ManagedAll()   -- array of { name, value }
    local db = self:DB(); return db and db:Select("name", "value"):From("cvar_managed"):Run() or {}
end
function CVars:_SetManaged(name, value)
    local db = self:DB(); if not db then return end
    if self:_IsManaged(name) then db:Update("cvar_managed", { value = value }, function(x) return x.name == name end)
    else db:Insert("cvar_managed", { name = name, value = value }) end
end
function CVars:_ClearManaged(name)
    local db = self:DB(); if db then db:Delete("cvar_managed", function(x) return x.name == name end) end
end
function CVars:_TrackedAll()    -- array of { name, type, category_id } -- every tracked CVar
    local db = self:DB(); return db and db:Select("name", "type", "category_id"):From("cvar_tracked"):Run() or {}
end
function CVars:_IsTracked(name)
    local db = self:DB(); if not db then return false end
    return #db:Select("name"):From("cvar_tracked"):Where("name", "=", name):Limit(1):Run() > 0
end
function CVars:_SetTracked(name, t, categoryId)
    local db = self:DB(); if not db then return end
    if self:_IsTracked(name) then
        db:Update("cvar_tracked", { type = t, category_id = categoryId }, function(x) return x.name == name end)
    else db:Insert("cvar_tracked", { name = name, type = t, category_id = categoryId }) end
end
function CVars:_ClearTracked(name)
    local db = self:DB(); if db then db:Delete("cvar_tracked", function(x) return x.name == name end) end
end

-- Get (or create) a category row by name, returning its id -- the FK target for cvar_tracked.
function CVars:_CategoryId(name)
    local db = self:DB(); if not db then return nil end
    local r = db:Select("id"):From("cvar_category"):Where("name", "=", name):Limit(1):Run()[1]
    if r then return r.id end
    local row = db:Insert("cvar_category", { name = name })
    return row and row.id or nil
end

-- All categories, as { id, name }, ordered by code order (CAT_ORDER); non-code categories (Custom and
-- any left over from a removed code category) sort last, alphabetically. This IS the UI category list.
function CVars:_Categories()
    local db = self:DB(); if not db then return {} end
    local cats = db:Select("id", "name"):From("cvar_category"):Run()
    table.sort(cats, function(a, b)
        local oa, ob = CAT_ORDER[a.name], CAT_ORDER[b.name]
        if oa and ob then return oa < ob end
        if oa ~= ob then return oa ~= nil end   -- a code category sorts before a non-code one
        return a.name < b.name
    end)
    return cats
end

-- Backfill the code catalog into the DB: ensure every curated category exists and every curated CVar
-- is tracked UNDER its code category (re-set each sync, so a CVar always reflects the current code).
-- The Custom category is ensured up front so it always renders (with its add field).
function CVars:_BackfillTracked()
    if not (C_CVar and C_CVar.GetCVarInfo) then return end   -- never seed blind
    self:_CategoryId("Custom")
    for _, cat in ipairs(CURATED) do
        local cid = self:_CategoryId(cat.name)
        for _, c in ipairs(cat.cvars) do
            if self:_Exists(c.name) then self:_SetTracked(c.name, c.type, cid) end
        end
    end
end

-- Prune rows whose CVar the client no longer has, then MOVE any tracked CVar the code no longer
-- manages (not in CATALOG) into Custom -- so a configured value is never lost, just regrouped. The
-- two passes + the backfill leave every tracked CVar correctly categorised in the database.
function CVars:_PruneTracked()
    if not (C_CVar and C_CVar.GetCVarInfo) then return end   -- API down -> don't wipe against nothing
    local db = self:DB(); if not db then return end
    db:Delete("cvar_tracked", function(r) return not self:_Exists(r.name) end)
    local customId = self:_CategoryId("Custom")
    for _, row in ipairs(self:_TrackedAll()) do
        if not CATALOG[row.name] and row.category_id ~= customId then
            db:Update("cvar_tracked", { category_id = customId }, function(x) return x.name == row.name end)
        end
    end
end

-- Sync the tracked catalog once per session, off the loading screen (C_Timer doesn't fire while a
-- loading screen is up). Mirrors the deferred passes elsewhere.
function CVars:_ScheduleSync()
    local p = self:_p()
    if p.syncPending or p.synced then return end
    p.syncPending = true
    C_Timer.After(0, function()
        p.syncPending = false
        self:_BackfillTracked()
        self:_PruneTracked()
        p.synced = true
    end)
end

function CVars:OnEnable()
    self:On("PLAYER_ENTERING_WORLD", function() self:_ScheduleApply() end)  -- auto-released on disable
    self:_ScheduleApply()
end

-- Re-apply DEFERRED past the loading screen: a SetCVar over every managed CVar is not free, and a
-- C_Timer callback does not fire while a loading screen is up, so this lands on the first frame once
-- the world is shown -- never stretching the load bar. Coalesced so each zone/instance change applies
-- once rather than stacking a fresh pass per loading screen.
function CVars:_ScheduleApply()
    local p = self:_p()
    if p.applyPending then return end
    p.applyPending = true
    C_Timer.After(0, function()
        p.applyPending = false
        if self:IsEnabled() then self:_ApplyAll() end   -- skip if disabled before the frame ran
    end)
end

-- Re-apply every globalised CVar (only while enabled; disabling stops forcing).
function CVars:_ApplyAll()
    if not (C_CVar and C_CVar.SetCVar) then return end
    for _, r in ipairs(self:_ManagedAll()) do
        pcall(C_CVar.SetCVar, r.name, r.value)
    end
end

-- ---- CVar helpers ---------------------------------------------------------
function CVars:_Exists(name)
    return C_CVar and C_CVar.GetCVarInfo and C_CVar.GetCVarInfo(name) ~= nil
end

-- The first EXAMPLE_CVARS entry that exists on this client (nil if none), for the add-field placeholder.
function CVars:_HintExample()
    for _, name in ipairs(EXAMPLE_CVARS) do
        if self:_Exists(name) then return name end
    end
    return nil
end

-- Set a CVar in the game (no globalising). If the CVar is already globalised its
-- saved value is kept in sync. Returns true on success; warns + returns false.
function CVars:_SetCVar(name, value)
    if not (C_CVar and C_CVar.GetCVarInfo) then self:LogWarn("CVar API unavailable"); return false end
    local cur, _, _, _, _, _, readOnly = C_CVar.GetCVarInfo(name)
    if cur == nil then self:LogWarn("unknown CVar: " .. name); return false end
    if readOnly then self:LogWarn(name .. " is read-only"); return false end
    if not pcall(C_CVar.SetCVar, name, value) then self:LogWarn("couldn't set " .. name); return false end
    if self:_IsManaged(name) then self:_SetManaged(name, value) end
    return true
end

-- Toggle whether a CVar is globalised: when on, its current value is saved
-- account-wide and re-applied on every character at login; when off, the value
-- is left as-is but no longer forced. Only meaningful for per-character CVars.
-- CVar-API rule (consistent across this file): FEATURE-DETECT existence before reading
-- (C_CVar and C_CVar.GetCVar), and PCALL only the calls that can throw on a valid-but-
-- rejected argument (SetCVar). A missing read API is a no-op, not a crash.
function CVars:_SetGlobalise(name, on)
    if on then
        if not (C_CVar and C_CVar.GetCVar) then return end
        self:_SetManaged(name, C_CVar.GetCVar(name))
        self:LogSuccess("saving " .. name .. " on every character")
        if not self:IsEnabled() then
            self:LogWarn("enable the CVars module so this re-applies on every login")
        end
    else
        self:_ClearManaged(name)
        self:LogInfo("stopped saving " .. name .. " globally (current value kept)")
    end
end

-- Set a CVar AND globalise it in one go (used by the slash command, where typing
-- a value implies you want it forced). Returns true on success.
function CVars:_ApplyCVar(name, value)
    if not self:_SetCVar(name, value) then return false end
    self:_SetManaged(name, value)
    if not self:IsEnabled() then
        self:LogWarn("module is disabled -- enable CVars to re-apply this on every login")
    end
    return true
end

-- Work out a CVar's control type: a curated/known typing wins; otherwise infer
-- from the current value ("0"/"1" -> boolean, numeric -> number, else text).
function CVars:_DetectType(name)
    local v = C_CVar and C_CVar.GetCVar and C_CVar.GetCVar(name)
    return ns.CVarHelper:DetectType(CATALOG[name], v)   -- curated override else value inference
end

-- ---- settings page (custom builder, called by SettingsWindow) -------------
function CVars:BuildSettingsPage(sf)
    local p = self:_p()
    local content = sf:Content()                     -- the framework's scroll area; we just fill it
    local width = content:GetWidth()
    if not width or width < 1 then width = 420 end
    p.pageContent = content
    p.pageWidth = width
    p.scrollArea = sf            -- kept so a rebuild can restore the scroll offset
    p.sections = {}
    p.sectionByTitle = {}        -- title -> section, so a rebuild can restore which were expanded

    local intro = W.Text:New(content, "Grouped useful CVars -- expand a category to change values. "
        .. "Changes apply right away. Tick Global on a per-character CVar to save it and "
        .. "re-apply it on every character (while this module is enabled).",
        "textDim", "GameFontHighlightSmall")
    intro:SetPoint("TOPLEFT", 4, -2)
    intro:SetWidth(width - 12)
    intro:SetJustifyH("LEFT")
    p.introH = intro:GetStringHeight() + 12

    -- keep the catalog current before drawing it (idempotent with the login sync): seed the code
    -- CVars under their categories, prune ones the client lost, move code-dropped ones into Custom.
    self:_BackfillTracked()
    self:_PruneTracked()

    -- Bucket every tracked CVar under its DB category; a CVar in the code catalog uses the rich code
    -- def, anything else (user-added or code-dropped) renders as a removable Custom row.
    local db = self:DB()
    local catName = {}   -- id -> name (the category list comes straight from the DB)
    for _, c in ipairs(db and db:Select("id", "name"):From("cvar_category"):Run() or {}) do catName[c.id] = c.name end
    local buckets = {}
    for _, row in ipairs(self:_TrackedAll()) do
        if self:_Exists(row.name) then
            local cname = catName[row.category_id] or "Custom"
            local def = CATALOG[row.name] or { name = row.name, label = row.name, type = row.type, custom = true }
            buckets[cname] = buckets[cname] or {}
            buckets[cname][#buckets[cname] + 1] = def
        end
    end

    -- one section per category (derived from the DB), code categories first then Custom; Custom always
    -- shows so the add field is reachable even when empty.
    for _, cat in ipairs(self:_Categories()) do
        local isCustom = cat.name == "Custom"
        local defs = buckets[cat.name] or {}
        if isCustom then table.sort(defs, function(a, b) return a.name:lower() < b.name:lower() end)
        else table.sort(defs, function(a, b) return (ORDER[a.name] or math.huge) < (ORDER[b.name] or math.huge) end) end
        if isCustom or #defs > 0 then self:_BuildSection(cat.name, defs, isCustom) end
    end

    self:_Relayout()
    self:_RestorePageState()   -- re-expand + re-scroll to where the player was before a rebuild
end

-- Capture which sections are expanded and the scroll offset, so the rebuild a custom add/remove
-- triggers (SettingsWindow:InvalidateModule tears the whole page down) doesn't snap the player back to
-- all-collapsed at the top. Called just before that rebuild, while the OLD widgets are still alive.
function CVars:_RememberPageState()
    local p = self:_p()
    local exp = {}
    for title, sec in pairs(p.sectionByTitle or {}) do exp[title] = sec:IsExpanded() end
    p.pendingExpanded = exp
    p.pendingScroll = p.scrollArea and p.scrollArea:GetScroll() or nil
end

-- Reapply the remembered state onto the freshly built page (no-op when nothing was remembered).
function CVars:_RestorePageState()
    local p = self:_p()
    if p.pendingExpanded then
        for title, sec in pairs(p.sectionByTitle or {}) do
            if p.pendingExpanded[title] then sec:SetExpanded(true) end
        end
        p.pendingExpanded = nil
        self:_Relayout()   -- re-stack: the restored expands changed section heights
    end
    if p.pendingScroll and p.scrollArea then
        p.scrollArea:Update()
        p.scrollArea:SetScroll(p.pendingScroll)   -- clamped to the new content height
        p.pendingScroll = nil
    end
end

-- Build one collapsible category section with the given CVar defs.
function CVars:_BuildSection(titleText, defs, prependAdd)
    local p = self:_p()
    local sec = W.CollapsibleSection:New(p.pageContent, titleText)
    local box = sec:GetContent()
    local y = -6

    if prependAdd then y = self:_PlaceAddRow(box, y, p.pageWidth) end
    for _, def in ipairs(defs) do
        y = self:_PlaceRow(box, def, y, p.pageWidth)
    end

    sec:SetContentHeight(-y + 6)
    sec:SetOnToggle(function() self:_Relayout() end)
    p.sections[#p.sections + 1] = sec
    p.sectionByTitle[titleText] = sec
    return sec
end

-- Stack every section top-to-bottom (their heights vary as they collapse/expand)
-- and size the scroll content to fit.
function CVars:_Relayout()
    local p = self:_p()
    local y = -(p.introH or 0)
    for _, sec in ipairs(p.sections) do
        sec:ClearAllPoints()
        sec:SetPoint("TOPLEFT", p.pageContent, "TOPLEFT", 0, y)
        sec:SetPoint("RIGHT", p.pageContent, "RIGHT", 0, 0)
        y = y - sec:GetHeight() - 6
    end
    p.pageContent:SetHeight(math.max(30, -y + 8))
end

-- ---- row builders ---------------------------------------------------------
-- Place the "add a custom CVar" row: a text box for the name + an Add button.
function CVars:_PlaceAddRow(box, y, width)
    local input = W.Input:New(box, width - 120)
    input:SetPoint("TOPLEFT", 6, y)
    local eg = self:_HintExample()                       -- a popular hand-set CVar that exists here
    input:SetHint(eg and ("e.g. " .. eg) or "e.g. a CVar name")

    local add = W.TextButton:New(box, "Add")
    add:SetPoint("LEFT", input, "RIGHT", 10, 0)

    local function submit()
        local name = (input:GetValue() or ""):match("^%s*(.-)%s*$")
        if name == "" then return end
        if not self:_Exists(name) then
            self:LogWarn(("unknown CVar: %s -- check the spelling (/hag cvar get %s)"):format(name, name))
            return
        end
        local t = self:_DetectType(name)
        self:_SetTracked(name, t, self:_CategoryId("Custom"))
        self:LogSuccess(("added custom CVar %s (%s)"):format(name, t))
        input:SetValue("")
        self:_RememberPageState()   -- keep the Custom section open + the scroll position on rebuild
        if ns.UI.SettingsWindow then ns.UI.SettingsWindow:InvalidateModule(self:GetName()) end
    end
    add:SetScript("OnClick", submit)
    input:SetScript("OnEnterPressed", function(s) s:ClearFocus(); submit() end)

    local hint = W.Text:New(box, "Type any CVar name, then Add. The field type is detected automatically.",
        "textFaint", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 6, y - 26)
    hint:SetWidth(width - 24)
    hint:SetJustifyH("LEFT")
    return y - 26 - hint:GetStringHeight() - 10
end

-- Place one CVar control row into `box` at vertical offset `y`; return the new y.
-- Right-side cluster (built right-to-left): optional Remove (custom rows), then a
-- "Global" toggle on per-character CVars to save the value on every character.
-- The value control sits to the left of that cluster.
function CVars:_PlaceRow(box, def, y, width)
    local cur = C_CVar.GetCVar(def.name)
    local _, _, _, perChar = C_CVar.GetCVarInfo(def.name)

    local cursor = 6  -- running inset from the box's right edge

    -- Remove (custom rows only), pinned furthest right.
    if def.custom then
        local rm = W.TextButton:New(box, "Remove")
        rm:SetPoint("TOPRIGHT", box, "TOPRIGHT", -cursor, y - 2)
        rm:SetTextColor(Theme.Unpack("red"))
        rm:SetScript("OnEnter", function() rm:SetTextColor(Theme.Unpack("text")) end)
        rm:SetScript("OnLeave", function() rm:SetTextColor(Theme.Unpack("red")) end)
        rm:SetScript("OnClick", function()
            self:_ClearTracked(def.name)
            self:LogInfo("removed custom CVar " .. def.name)
            self:_RememberPageState()   -- keep the Custom section open + the scroll position on rebuild
            if ns.UI.SettingsWindow then ns.UI.SettingsWindow:InvalidateModule(self:GetName()) end
        end)
        cursor = cursor + rm:GetWidth() + 12
    end

    -- "Global" toggle: only for per-character CVars (account/global ones are
    -- already shared, so forcing them is meaningless).
    if perChar then
        local g = W.Toggle:New(box, nil)
        g:SetPoint("TOPRIGHT", box, "TOPRIGHT", -cursor, y)
        g:SetChecked(self:_IsManaged(def.name))
        g:SetOnToggle(function(on) self:_SetGlobalise(def.name, on) end)
        local glbl = W.Text:New(box, "Global", "textDim", "GameFontHighlightSmall")
        glbl:SetPoint("RIGHT", g, "LEFT", -6, 0)
        cursor = cursor + 18 + 6 + glbl:GetStringWidth() + 14
    end

    local valInset = -cursor

    if def.type == "boolean" then
        local t = W.Toggle:New(box, nil)
        t:SetPoint("TOPLEFT", 6, y)
        t:SetChecked(cur == "1")
        t:SetOnToggle(function(on) self:_SetCVar(def.name, on and "1" or "0") end)
        local lbl = W.Text:New(box, def.label, "text", "GameFontHighlight")
        lbl:SetPoint("LEFT", t, "RIGHT", 10, 0)

    elseif def.options then
        local lbl = W.Text:New(box, def.label, "text", "GameFontHighlight")
        lbl:SetPoint("TOPLEFT", 6, y - 2)
        local seg = W.Segmented:New(box, def.options)
        seg:SetPoint("TOPRIGHT", box, "TOPRIGHT", valInset, y)
        seg:SetValue(cur)
        seg:SetOnChange(function(v) self:_SetCVar(def.name, v) end)

    else  -- number or string -> text box
        local lbl = W.Text:New(box, def.label, "text", "GameFontHighlight")
        lbl:SetPoint("TOPLEFT", 6, y - 2)
        local numeric = def.type == "number"
        local input = W.Input:New(box, numeric and 90 or 150)
        input:SetPoint("TOPRIGHT", box, "TOPRIGHT", valInset, y)
        input:SetValue(cur)
        input:SetOnChange(function(v)
            if numeric and tonumber(v) == nil then
                self:LogWarn(("%s needs a number"):format(def.name))
                input:SetValue(C_CVar.GetCVar(def.name))  -- revert
                return
            end
            if not self:_SetCVar(def.name, v) then
                input:SetValue(C_CVar.GetCVar(def.name))  -- revert on failure
            end
        end)
    end

    local descY = y - 22
    if def.desc then
        local d = W.Text:New(box, def.desc, "textFaint", "GameFontHighlightSmall")
        d:SetPoint("TOPLEFT", def.type == "boolean" and 30 or 6, descY)
        d:SetWidth(width - 40)
        d:SetJustifyH("LEFT")
        return descY - d:GetStringHeight() - 8
    end
    return descY - 4
end

-- ---- slash ----------------------------------------------------------------
function CVars:_Slash(rest)
    local cmd, arg = ns.SlashParse:Split(rest)   -- pure tokeniser (Lib/SlashParse.lua)
    -- "dump" (enumerate every CVar) is a developer-only command: available only on a whitelisted dev
    -- character. Off-whitelist it isn't handled or advertised; the rest of /hag cvar works for everyone.
    local devChar = ns.IsDevChar and ns.IsDevChar()
    if cmd == "dump" and devChar then
        self:_Dump(arg)
    elseif cmd == "set" then
        local name, value = ns.SlashParse:Pair(arg)
        if name and value then
            if self:_ApplyCVar(name, value) then
                self:LogSuccess(("globalising %s = %s"):format(name, value))
            end
        else self:LogInfo("usage: /hag cvar set <name> <value>") end
    elseif cmd == "get" then
        if arg ~= "" then self:_Get(arg) else self:LogInfo("usage: /hag cvar get <name>") end
    elseif cmd == "clear" then
        if arg ~= "" then self:_Clear(arg) else self:LogInfo("usage: /hag cvar clear <name>") end
    elseif cmd == "list" then
        self:_List()
    else
        local dumpHint = devChar and "dump [filter] | " or ""
        self:LogInfo("|cffffff00/hag cvar|r " .. dumpHint .. "set <name> <value> | get <name> | clear <name> | list")
    end
end

function CVars:_Dump(filter)
    local names = ns.Dev and ns.Dev:AllCVarNames(filter)  -- enumeration lives in the Dev service
    if not names then
        -- C_Console.* only exists when WoW is launched with the developer-console flag.
        self:LogWarn("can't list every CVar: the developer console isn't enabled in this client.")
        self:LogInfo("add |cffffffff-console|r to your WoW launch options to enable it (or look names up on warcraft.wiki.gg).")
        self:LogInfo("you can still inspect/set any CVar by name -- /hag cvar get <name> | set <name> <value>")
        return
    end
    local scope = (filter and filter ~= "") and (" matching '" .. filter .. "'") or ""
    self:LogInfo(("%d CVar%s%s:"):format(#names, #names == 1 and "" or "s", scope))
    if #names > DUMP_CAP then
        self:LogWarn(("too many to list (%d) -- narrow it: /hag cvar dump <filter>"):format(#names))
        return
    end
    local faint = Theme.hex.textFaint
    for _, name in ipairs(names) do
        local v, d = C_CVar.GetCVar(name), select(2, C_CVar.GetCVarInfo(name))
        local def = (d ~= nil and d ~= v) and (" |cff" .. faint .. "(default " .. tostring(d) .. ")|r") or ""
        self:LogInfo(("  %s = %s%s"):format(name, tostring(v), def))
    end
end

function CVars:_Get(name)
    if not (C_CVar and C_CVar.GetCVarInfo) then self:LogWarn("CVar API unavailable"); return end
    local v, d, acct, char, locked, secure, ro = C_CVar.GetCVarInfo(name)
    if v == nil then self:LogWarn("unknown CVar: " .. name); return end
    local scope = char and "per-character" or acct and "account" or "global"
    local flags = {}
    if secure then flags[#flags + 1] = "secure" end
    if locked then flags[#flags + 1] = "locked" end
    if ro then flags[#flags + 1] = "read-only" end
    local managed = self:_ManagedValue(name)
    self:LogInfo(("%s = %s  (default %s, %s%s)%s"):format(
        name, tostring(v), tostring(d), scope,
        #flags > 0 and (", " .. table.concat(flags, ", ")) or "",
        managed and ("  |cff44ff44[globalised = " .. managed .. "]|r") or ""))
end

function CVars:_Clear(name)
    if not self:_IsManaged(name) then self:LogInfo("not globalising: " .. name); return end
    self:_ClearManaged(name)
    self:LogSuccess("stopped globalising " .. name .. " (current value kept)")
end

function CVars:_List()
    local rows = self:_ManagedAll()
    table.sort(rows, function(a, b) return a.name < b.name end)
    if #rows == 0 then self:LogInfo("not globalising any CVars yet (try /hag cvar set <name> <value>)"); return end
    self:LogInfo(("globalising %d CVar%s:"):format(#rows, #rows == 1 and "" or "s"))
    for _, r in ipairs(rows) do
        self:LogInfo(("  %s = %s"):format(r.name, tostring(r.value)))
    end
end

ns.ModuleManager:Register(CVars:New("CVars", {
    title = "CVars",
    description = "Force useful console variables on every character. Grouped, typed controls plus custom CVars.",
    defaultEnabled = false,
    color = ns.Theme.hex.red,
    deps = { "SlashCommand", "SettingsWindow" },  -- routing + page refresh (type inference is a pure Lib: ns.CVarHelper, always available). The full-dump enumeration (ns.Dev) is dev-only and optional, so it isn't a hard dep.
    -- "dump" is dev-only (see _Slash); don't advertise it to normal users in /hag help. The help is a
    -- function so it's decided when /hag help prints (matching the runtime gate), not baked at load.
    commands = { cvar = { handler = "_Slash", help = function()
        return "console variables: " .. ((ns.IsDevChar and ns.IsDevChar()) and "dump [filter] / " or "")
            .. "set <name> <value> / get <name> / clear <name> / list"
    end } },
    -- Account-wide CVar data in the shared database.
    tables = {
        cvar_managed = { scope = "global", columns = {   -- forced CVars, re-applied each login
            { name = "name",  type = "text", primaryKey = true },
            { name = "value", type = "text" },
        } },
        -- The categories CVars are grouped under (Camera, Nameplates, ..., and Custom). Seeded from the
        -- code catalog; the UI category list is derived from this table. Keyed by an auto id that
        -- cvar_tracked references, so category membership is resolved in the database, not at render.
        cvar_category = { scope = "global",
            columns = {
                { name = "id",   type = "integer", primaryKey = true, autoIncrement = true },
                { name = "name", type = "text", nullable = false },
            },
            unique = { { "name" } } },
        -- Every CVar we TRACK -- curated (backfilled from the code catalog) AND user-added -- with the
        -- category it belongs to. When the code stops managing a CVar it is reassigned to Custom in the
        -- DB (see _PruneTracked), so a value the player configured is never lost.
        cvar_tracked = { scope = "global", columns = {
            { name = "name",        type = "text", primaryKey = true },
            { name = "type",        type = "text" },   -- control type (used when not in the code catalog)
            { name = "category_id", type = "integer", references = { table = "cvar_category", column = "id" } },
        } },
    },
}))
