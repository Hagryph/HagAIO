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

-- name -> { type, options } for the curated entries, so custom-CVar type
-- detection can prefer a KNOWN typing before falling back to value inference.
local KNOWN = {}
for _, cat in ipairs(CURATED) do
    for _, c in ipairs(cat.cvars) do
        KNOWN[c.name] = { type = c.type, options = c.options }
    end
end

-- ---- lifecycle ------------------------------------------------------------
function CVars:OnInitialize()
    local p = self:_p()
    p.sections = {}
    -- db.managed / db.custom are pre-seeded from dbSchema (see registration).
    -- The "/hag cvar" sub-command is declared on registration and wired by the base
    -- on enable (removed on disable), like the module's events.
end

function CVars:OnEnable()
    self:On("PLAYER_ENTERING_WORLD", function() self:_ApplyAll() end)  -- auto-released on disable
    self:_ApplyAll()
end

-- Re-apply every globalised CVar (only while enabled; disabling stops forcing).
function CVars:_ApplyAll()
    if not (C_CVar and C_CVar.SetCVar) then return end
    for name, value in pairs(self:GetDB().managed) do
        pcall(C_CVar.SetCVar, name, value)
    end
end

-- ---- CVar helpers ---------------------------------------------------------
function CVars:_Exists(name)
    return C_CVar and C_CVar.GetCVarInfo and C_CVar.GetCVarInfo(name) ~= nil
end

-- Set a CVar in the game (no globalising). If the CVar is already globalised its
-- saved value is kept in sync. Returns true on success; warns + returns false.
function CVars:_SetCVar(name, value)
    if not (C_CVar and C_CVar.GetCVarInfo) then self:LogWarn("CVar API unavailable"); return false end
    local cur, _, _, _, _, _, readOnly = C_CVar.GetCVarInfo(name)
    if cur == nil then self:LogWarn("unknown CVar: " .. name); return false end
    if readOnly then self:LogWarn(name .. " is read-only"); return false end
    if not pcall(C_CVar.SetCVar, name, value) then self:LogWarn("couldn't set " .. name); return false end
    if self:GetDB().managed[name] ~= nil then self:GetDB().managed[name] = value end
    return true
end

-- Toggle whether a CVar is globalised: when on, its current value is saved
-- account-wide and re-applied on every character at login; when off, the value
-- is left as-is but no longer forced. Only meaningful for per-character CVars.
function CVars:_SetGlobalise(name, on)
    if on then
        self:GetDB().managed[name] = C_CVar.GetCVar(name)
        self:LogSuccess("saving " .. name .. " on every character")
        if not self:IsEnabled() then
            self:LogWarn("enable the CVars module so this re-applies on every login")
        end
    else
        self:GetDB().managed[name] = nil
        self:LogInfo("stopped saving " .. name .. " globally (current value kept)")
    end
end

-- Set a CVar AND globalise it in one go (used by the slash command, where typing
-- a value implies you want it forced). Returns true on success.
function CVars:_ApplyCVar(name, value)
    if not self:_SetCVar(name, value) then return false end
    self:GetDB().managed[name] = value
    if not self:IsEnabled() then
        self:LogWarn("module is disabled -- enable CVars to re-apply this on every login")
    end
    return true
end

-- Work out a CVar's control type: a curated/known typing wins; otherwise infer
-- from the current value ("0"/"1" -> boolean, numeric -> number, else text).
function CVars:_DetectType(name)
    local known = KNOWN[name]
    if known then return known.type, known.options end
    local v = C_CVar and C_CVar.GetCVar and C_CVar.GetCVar(name)
    return ns.CVarHelper:InferType(v)   -- pure value-based inference
end

-- ---- settings page (custom builder, called by SettingsWindow) -------------
function CVars:BuildSettingsPage(sf)
    local p = self:_p()
    local content = sf.content
    local width = sf:GetWidth()
    if not width or width < 1 then width = 420 end
    content:SetWidth(width)
    p.pageContent = content
    p.pageWidth = width
    p.sections = {}

    local intro = W.Text(content, "Grouped useful CVars -- expand a category to change values. "
        .. "Changes apply right away. Tick Global on a per-character CVar to save it and "
        .. "re-apply it on every character (while this module is enabled).",
        "textDim", "GameFontHighlightSmall")
    intro:SetPoint("TOPLEFT", 4, -2)
    intro:SetWidth(width - 12)
    intro:SetJustifyH("LEFT")
    p.introH = intro:GetStringHeight() + 12

    -- curated categories
    for _, cat in ipairs(CURATED) do
        local defs = {}
        for _, c in ipairs(cat.cvars) do
            if self:_Exists(c.name) then defs[#defs + 1] = c end
        end
        if #defs > 0 then self:_BuildSection(cat.name, defs, false) end
    end

    -- the user's custom CVars (plus the add field)
    self:_BuildCustomSection()

    self:_Relayout()
end

-- Build one collapsible category section with the given CVar defs.
function CVars:_BuildSection(titleText, defs, prependAdd)
    local p = self:_p()
    local sec = W.CollapsibleSection(p.pageContent, titleText)
    local box = sec:GetContent()
    local y = -6

    if prependAdd then y = self:_PlaceAddRow(box, y, p.pageWidth) end
    for _, def in ipairs(defs) do
        y = self:_PlaceRow(box, def, y, p.pageWidth)
    end

    sec:SetContentHeight(-y + 6)
    sec:SetOnToggle(function() self:_Relayout() end)
    p.sections[#p.sections + 1] = sec
    return sec
end

function CVars:_BuildCustomSection()
    local custom = self:GetDB().custom
    local defs = {}
    for name, t in pairs(custom) do
        if self:_Exists(name) then
            defs[#defs + 1] = { name = name, label = name, type = t,
                options = KNOWN[name] and KNOWN[name].options, custom = true }
        end
    end
    table.sort(defs, function(a, b) return a.name:lower() < b.name:lower() end)
    self:_BuildSection("Custom", defs, true)
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
    local input = W.Input(box, width - 120)
    input:SetPoint("TOPLEFT", 6, y)

    local add = W.TextButton(box, "Add")
    add:SetPoint("LEFT", input, "RIGHT", 10, 0)

    local function submit()
        local name = (input:GetValue() or ""):match("^%s*(.-)%s*$")
        if name == "" then return end
        if not self:_Exists(name) then
            self:LogWarn(("unknown CVar: %s -- check the spelling (/hag cvar get %s)"):format(name, name))
            return
        end
        local t = self:_DetectType(name)
        self:GetDB().custom[name] = t
        self:LogSuccess(("added custom CVar %s (%s)"):format(name, t))
        input:SetValue("")
        if ns.UI.SettingsWindow then ns.UI.SettingsWindow:InvalidateModule(self:GetName()) end
    end
    add:SetScript("OnClick", submit)
    input:SetOnChange(function() end)  -- commit-on-enter handled below
    input:SetScript("OnEnterPressed", function(self) self:ClearFocus(); submit() end)

    local hint = W.Text(box, "Type any CVar name, then Add. The field type is detected automatically.",
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
        local rm = W.TextButton(box, "Remove")
        rm:SetPoint("TOPRIGHT", box, "TOPRIGHT", -cursor, y - 2)
        rm.text:SetTextColor(Theme.Unpack("red"))
        rm:SetScript("OnEnter", function() rm.text:SetTextColor(Theme.Unpack("text")) end)
        rm:SetScript("OnLeave", function() rm.text:SetTextColor(Theme.Unpack("red")) end)
        rm:SetScript("OnClick", function()
            self:GetDB().custom[def.name] = nil
            self:LogInfo("removed custom CVar " .. def.name)
            if ns.UI.SettingsWindow then ns.UI.SettingsWindow:InvalidateModule(self:GetName()) end
        end)
        cursor = cursor + rm:GetWidth() + 12
    end

    -- "Global" toggle: only for per-character CVars (account/global ones are
    -- already shared, so forcing them is meaningless).
    if perChar then
        local g = W.Toggle(box, nil)
        g:SetPoint("TOPRIGHT", box, "TOPRIGHT", -cursor, y)
        g:SetChecked(self:GetDB().managed[def.name] ~= nil)
        g:SetOnToggle(function(on) self:_SetGlobalise(def.name, on) end)
        local glbl = W.Text(box, "Global", "textDim", "GameFontHighlightSmall")
        glbl:SetPoint("RIGHT", g, "LEFT", -6, 0)
        cursor = cursor + 18 + 6 + glbl:GetStringWidth() + 14
    end

    local valInset = -cursor

    if def.type == "boolean" then
        local t = W.Toggle(box, nil)
        t:SetPoint("TOPLEFT", 6, y)
        t:SetChecked(cur == "1")
        t:SetOnToggle(function(on) self:_SetCVar(def.name, on and "1" or "0") end)
        local lbl = W.Text(box, def.label, "text", "GameFontHighlight")
        lbl:SetPoint("LEFT", t, "RIGHT", 10, 0)

    elseif def.options then
        local lbl = W.Text(box, def.label, "text", "GameFontHighlight")
        lbl:SetPoint("TOPLEFT", 6, y - 2)
        local seg = W.Segmented(box, def.options)
        seg:SetPoint("TOPRIGHT", box, "TOPRIGHT", valInset, y)
        seg:SetValue(cur)
        seg:SetOnChange(function(v) self:_SetCVar(def.name, v) end)

    else  -- number or string -> text box
        local lbl = W.Text(box, def.label, "text", "GameFontHighlight")
        lbl:SetPoint("TOPLEFT", 6, y - 2)
        local numeric = def.type == "number"
        local input = W.Input(box, numeric and 90 or 150)
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
        local d = W.Text(box, def.desc, "textFaint", "GameFontHighlightSmall")
        d:SetPoint("TOPLEFT", def.type == "boolean" and 30 or 6, descY)
        d:SetWidth(width - 40)
        d:SetJustifyH("LEFT")
        return descY - d:GetStringHeight() - 8
    end
    return descY - 4
end

-- ---- slash ----------------------------------------------------------------
function CVars:_Slash(rest)
    local cmd, arg = (rest or ""):match("^(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    if cmd == "dump" then
        self:_Dump(arg)
    elseif cmd == "set" then
        local name, value = arg:match("^(%S+)%s+(.+)$")
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
        self:LogInfo("|cffffff00/hag cvar|r dump [filter] | set <name> <value> | get <name> | clear <name> | list")
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
    local managed = self:GetDB().managed[name]
    self:LogInfo(("%s = %s  (default %s, %s%s)%s"):format(
        name, tostring(v), tostring(d), scope,
        #flags > 0 and (", " .. table.concat(flags, ", ")) or "",
        managed and ("  |cff44ff44[globalised = " .. managed .. "]|r") or ""))
end

function CVars:_Clear(name)
    if self:GetDB().managed[name] == nil then self:LogInfo("not globalising: " .. name); return end
    self:GetDB().managed[name] = nil
    self:LogSuccess("stopped globalising " .. name .. " (current value kept)")
end

function CVars:_List()
    local managed = self:GetDB().managed
    local names = {}
    for n in pairs(managed) do names[#names + 1] = n end
    table.sort(names)
    if #names == 0 then self:LogInfo("not globalising any CVars yet (try /hag cvar set <name> <value>)"); return end
    self:LogInfo(("globalising %d CVar%s:"):format(#names, #names == 1 and "" or "s"))
    for _, n in ipairs(names) do
        self:LogInfo(("  %s = %s"):format(n, tostring(managed[n])))
    end
end

ns.ModuleManager:Register(CVars:New("CVars", {
    title = "CVars",
    description = "Force useful console variables on every character. Grouped, typed controls plus custom CVars.",
    defaultEnabled = false,
    color = ns.Theme.hex.red,
    deps = { "SlashCommand", "Dev", "SettingsWindow", "CVarHelper" },  -- routing + enumeration + page refresh + type inference
    commands = { cvar = { handler = "_Slash", help = "console variables: dump / set / get / clear / list" } },
    -- Persisted structure (seeded on bind, before OnInitialize):
    dbSchema = {
        managed = {},  -- name -> value (account-wide, re-applied each login)
        custom  = {},  -- name -> type, the user-added "custom" CVars
    },
}))
