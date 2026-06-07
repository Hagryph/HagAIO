local addonName, ns = ...
local Class = ns.Class
local Theme = ns.Theme
local W = ns.UI.Widgets

-- Modules/Tasklist.lua
-- A lightweight objective tracker. Other code registers tasks; each task is
-- one-time / daily / weekly, completes either MANUALLY (you tick it) or
-- AUTOMATICALLY (a condition is re-checked whenever one of the task's declared
-- game events fires -- e.g. a boss kill). Daily/weekly tasks clear themselves at
-- the server reset. The on-screen tracker is a sleek, movable (Edit Mode) panel
-- in the addon's dark-blue style, hidden during combat, laid out like Blizzard's
-- quest tracker (section headers + bulleted task points).
--
-- API (also reachable as ns.Tasks):
--   ns.Tasks:Register{ key=, title=, type="once"|"daily"|"weekly",
--                      events={ "ENCOUNTER_END", ... }, condition=function(task,...) return done end,
--                      manual=false, desc= }
--   ns.Tasks:Unregister(key)   :SetDone(key, bool)   :IsDone(key)
--   ns.Tasks:Track{ key=, title=, itemID=, type= }   -- persistent user task (e.g. from ATT)
--   ns.Tasks:Untrack(key)      :TrackFromATT(attGroup)

local Tasklist = Class.new("Tasklist", ns.Module)

local TYPE_LABEL = { once = "Tasks", daily = "Daily", weekly = "Weekly" }
local TYPE_ORDER = { "once", "daily", "weekly" }

-- Is an item collected? Prefer ATT's knowledge, since it covers every collectible.
local function itemCollected(itemID)
    if not itemID then return false end
    local app = _G.AllTheThings
    if app and app.SearchForField then
        local res = app.SearchForField("itemID", itemID)
        if res then for _, g in ipairs(res) do if g.collected then return true end end end
    end
    return false
end

-- Generic "is this ATT thing done?" -- re-resolves the group by its key+id (so it
-- survives reloads) and reads ATT's own saved/collected state. Works for bosses
-- (encounterID, via the hidden kill-credit quest ATT tracks as `saved`), quests
-- (questID), and collectibles (itemID/mountID/...). Falls back to the quest API.
local function attDone(attKey, id)
    if not (attKey and id) then return false end
    local app = _G.AllTheThings
    if app and app.SearchForField then
        local res = app.SearchForField(attKey, id)
        if res then for _, g in ipairs(res) do if g.saved or g.collected then return true end end end
    end
    if attKey == "questID" and C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
        return C_QuestLog.IsQuestFlaggedCompleted(id)
    end
    return false
end

-- Collected check straight from the Blizzard collection APIs (no ATT needed).
local function collectibleCollected(kind, id)
    if not id then return false end
    if kind == "mount" and C_MountJournal and C_MountJournal.GetMountInfoByID then
        local _, _, _, _, _, _, _, _, _, _, isCollected = C_MountJournal.GetMountInfoByID(id)
        return isCollected and true or false
    elseif kind == "toy" then
        return PlayerHasToy and PlayerHasToy(id) and true or false
    elseif kind == "heirloom" then
        return C_Heirloom and C_Heirloom.PlayerHasHeirloom and C_Heirloom.PlayerHasHeirloom(id) and true or false
    elseif kind == "pet" and C_PetJournal and C_PetJournal.GetNumCollectedInfo then
        local n = C_PetJournal.GetNumCollectedInfo(id)
        return (n or 0) > 0
    elseif kind == "transmog" and C_TransmogCollection and C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance then
        return C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance(id) and true or false  -- id = sourceID
    end
    return false
end

-- Events that can signal a boss kill / quest turn-in / collectible gain.
local ATT_EVENTS = {
    "QUEST_TURNED_IN", "QUEST_LOG_UPDATE", "ENCOUNTER_END", "BOSS_KILL", "UPDATE_INSTANCE_INFO",
    "BAG_UPDATE_DELAYED", "NEW_MOUNT_ADDED", "NEW_TOY_ADDED", "TOYS_UPDATED",
    "COMPANION_LEARNED", "TRANSMOG_COLLECTION_SOURCE_ADDED", "PET_JOURNAL_LIST_UPDATE",
}

-- ---- lifecycle ------------------------------------------------------------
function Tasklist:OnInitialize()
    ns.Tasks = self
    local p = self:_p()
    p.tasks = {}          -- key -> runtime def
    p.eventTokens = {}    -- event -> EventBus token (subscribed once, shared)
    p.busTokens = {}      -- lifecycle subscriptions (combat, reset)
    local db = self:GetDB()
    db.state = db.state or {}      -- key -> { done, resetAt }
    db.tracked = db.tracked or {}  -- key -> { title, itemID, type, source }  (persistent)
    db.nextId = db.nextId or 0     -- counter for unique manual-task keys
end

function Tasklist:OnEnable()
    local bus = ns.EventBus
    local p = self:_p()
    p.busTokens.combat1 = bus:On("PLAYER_REGEN_DISABLED", function() self:_UpdateVisibility() end)
    p.busTokens.combat2 = bus:On("PLAYER_REGEN_ENABLED", function() self:_UpdateVisibility() end)
    p.busTokens.world   = bus:On("PLAYER_ENTERING_WORLD", function() self:_CheckResets() end)
    -- Authoritative live boss-kill detection (see DBM/BigWigs + warcraft.wiki):
    -- ENCOUNTER_END success==1 / BOSS_KILL, matched on the DungeonEncounterID.
    p.busTokens.encEnd   = bus:On("ENCOUNTER_END", function(_, encID, _, _, _, success) self:_OnEncounterEnd(encID, success) end)
    p.busTokens.bossKill = bus:On("BOSS_KILL", function(_, encID) self:_OnEncounterEnd(encID, 1) end)

    -- re-create persistent tracked tasks
    for key, t in pairs(self:GetDB().tracked) do self:_RegisterTracked(key, t) end

    self:_CheckResets()
    if not p.ticker then
        p.ticker = C_Timer.NewTicker(60, function() self:_CheckResets() end)  -- catch resets while logged in
    end
    self:_Refresh()
    self:_UpdateVisibility()
end

function Tasklist:OnDisable()
    local p = self:_p()
    local bus = ns.EventBus
    for ev, tok in pairs(p.eventTokens) do bus:Off(ev, tok) end
    if p.busTokens.combat1 then bus:Off("PLAYER_REGEN_DISABLED", p.busTokens.combat1) end
    if p.busTokens.combat2 then bus:Off("PLAYER_REGEN_ENABLED", p.busTokens.combat2) end
    if p.busTokens.world then bus:Off("PLAYER_ENTERING_WORLD", p.busTokens.world) end
    if p.busTokens.encEnd then bus:Off("ENCOUNTER_END", p.busTokens.encEnd) end
    if p.busTokens.bossKill then bus:Off("BOSS_KILL", p.busTokens.bossKill) end
    wipe(p.eventTokens); wipe(p.busTokens)
    if p.ticker then p.ticker:Cancel(); p.ticker = nil end
    if p.frame then p.frame:Hide() end
end

function Tasklist:OnSettingChanged() self:_Refresh() end

-- ---- registry -------------------------------------------------------------
function Tasklist:_State(key)
    local s = self:GetDB().state
    s[key] = s[key] or { done = false }
    return s[key]
end

function Tasklist:Register(def)
    if not def or not def.key then return end
    local p = self:_p()
    def.type = def.type or "once"
    p.tasks[def.key] = def
    self:_State(def.key)
    for _, ev in ipairs(def.events or {}) do self:_SubscribeEvent(ev) end
    self:_Evaluate(def)
    self:_Refresh()
    return def
end

function Tasklist:Unregister(key)
    self:_p().tasks[key] = nil
    self:_Refresh()
end

function Tasklist:IsDone(key)
    return self:_State(key).done and true or false
end

function Tasklist:SetDone(key, done)
    local st = self:_State(key)
    local def = self:_p().tasks[key]
    st.done = done and true or false
    st.resetAt = done and self:_NextReset(def and def.type) or nil
    self:_Refresh()
    self:_UpdateVisibility()
end

function Tasklist:_SubscribeEvent(ev)
    local p = self:_p()
    if p.eventTokens[ev] then return end
    p.eventTokens[ev] = ns.EventBus:On(ev, function(_, ...) self:_OnEvent(ev, ...) end)
end

function Tasklist:_OnEvent(ev, ...)
    for _, def in pairs(self:_p().tasks) do
        if not def.manual and not self:IsDone(def.key) then
            for _, e in ipairs(def.events or {}) do
                if e == ev then self:_Evaluate(def, ...); break end
            end
        end
    end
end

function Tasklist:_Evaluate(def, ...)
    if def.manual or self:IsDone(def.key) then return end
    if def.condition and def.condition(def, ...) then self:SetDone(def.key, true) end
end

-- Live kill: ENCOUNTER_END(success==1) / BOSS_KILL give a DungeonEncounterID.
-- Complete any task whose stored dungeonID matches.
function Tasklist:_OnEncounterEnd(encounterID, success)
    if not encounterID or success == 0 then return end
    for key, def in pairs(self:_p().tasks) do
        if def.dungeonID == encounterID and not self:IsDone(key) then
            self:SetDone(key, true)
        end
    end
end

-- ---- resets ---------------------------------------------------------------
function Tasklist:_NextReset(taskType)
    local cd = C_DateAndTime
    if taskType == "daily" and cd and cd.GetSecondsUntilDailyReset then
        return time() + cd.GetSecondsUntilDailyReset()
    elseif taskType == "weekly" and cd and cd.GetSecondsUntilWeeklyReset then
        return time() + cd.GetSecondsUntilWeeklyReset()
    end
    return nil
end

function Tasklist:_CheckResets()
    local now = time()
    local changed = false
    for key, st in pairs(self:GetDB().state) do
        if st.done and st.resetAt and now >= st.resetAt then
            st.done, st.resetAt = false, nil
            changed = true
        end
    end
    for _, def in pairs(self:_p().tasks) do self:_Evaluate(def) end  -- maybe already re-done
    if changed then self:_Refresh(); self:_UpdateVisibility() end
end

-- ---- tracking (persistent user tasks, e.g. from ATT) ----------------------
function Tasklist:Track(info)
    if not info or not info.key then return end
    local db = self:GetDB()
    db.tracked[info.key] = {
        title = info.title, itemID = info.itemID, type = info.type or "once",
        source = info.source, att = info.att,  -- att = { key=, id= } for saved/lockout check
        dungeonID = info.dungeonID,            -- DungeonEncounterID for live kill detection
        coll = info.coll,                      -- coll = { kind=, id= } collection-journal item
    }
    self:_RegisterTracked(info.key, db.tracked[info.key])
    self:LogInfo("tracking: " .. (info.title or info.key))
end

function Tasklist:Untrack(key)
    local db = self:GetDB()
    db.tracked[key] = nil
    db.state[key] = nil
    self:Unregister(key)
    self:_UpdateVisibility()
end

-- Add a manual, user-described objective (e.g. "Raid LK weekly", "Grind X mob").
-- These have no auto-condition; you tick them off yourself. Persisted.
function Tasklist:AddCustom(title, taskType)
    title = title and title:match("^%s*(.-)%s*$")
    if not title or title == "" then return end
    local db = self:GetDB()
    db.nextId = (db.nextId or 0) + 1
    self:Track({ key = "user:" .. db.nextId, title = title, type = taskType or "once", source = "Manual" })
end

-- Remove any task (manual, tracked, or code-registered) from the list + storage.
function Tasklist:Remove(key)
    self:Untrack(key)
end

function Tasklist:IsTracked(key)
    return self:GetDB().tracked[key] ~= nil
end

function Tasklist:_RegisterTracked(key, t)
    local condition, manual
    if t.att and t.att.key and t.att.id then          -- quest / collectible / boss-lockout via ATT
        local ak, aid = t.att.key, t.att.id
        condition = function() return attDone(ak, aid) end
    elseif t.coll and t.coll.kind and t.coll.id then  -- collection-journal collectible
        local kind, id = t.coll.kind, t.coll.id
        condition = function() return collectibleCollected(kind, id) end
    elseif t.itemID then                              -- plain item collectible
        local itemID = t.itemID
        condition = function() return itemCollected(itemID) end
    elseif t.dungeonID then                           -- boss: live kill via ENCOUNTER_END handler
        manual = false                               -- no polling condition; event-completed
    else                                              -- user-described objective
        manual = true
    end
    self:Register({
        key = key, title = t.title, type = t.type or "once", desc = t.source, tracked = true,
        manual = manual, dungeonID = t.dungeonID,
        events = (not manual) and ATT_EVENTS or nil, condition = condition,
    })
end

-- Stable task key for an ATT group (its key field + id, else item/name).
function Tasklist:ATTKey(ref)
    local idKey = ref.key
    return "att:" .. tostring(idKey or "g") .. ":" .. tostring((idKey and ref[idKey]) or ref.itemID or ref.text or "?")
end

function Tasklist:IsTrackedRef(ref)
    return ref ~= nil and self:IsTracked(self:ATTKey(ref))
end

-- Toggle tracking of an ATT row's group (right-click handler calls this). Bosses
-- become weekly auto-tasks, repeatable quests daily, everything else one-time.
function Tasklist:TrackFromATT(ref)
    if not ref then return end
    local key = self:ATTKey(ref)
    if self:IsTracked(key) then
        self:Untrack(key)
        self:LogInfo("untracked: " .. (ref.text or key))
        return
    end

    local attKey = ref.key                  -- e.g. "encounterID" / "questID" / "itemID" / "mountID"
    local idval = attKey and ref[attKey]
    local ttype = "once"
    if ref.encounterID then ttype = "weekly"
    elseif ref.questID and ref.repeatable then ttype = "daily" end

    -- Bridge ATT's journal encounterID -> the DungeonEncounterID that the kill
    -- events report (EJ_GetEncounterInfo return #7).
    local dungeonID
    if ref.encounterID and EJ_GetEncounterInfo then
        dungeonID = select(7, EJ_GetEncounterInfo(ref.encounterID))
    end

    self:Track({
        key = key, type = ttype, source = "ATT",
        title = ref.text or ref.name or ("Item " .. tostring(ref.itemID or "?")),
        att = (attKey and idval) and { key = attKey, id = idval } or nil,
        itemID = ref.itemID, dungeonID = dungeonID,
    })
end

-- Toggle a collection-journal collectible (mount/pet/toy/heirloom/transmog).
function Tasklist:IsCollectibleTracked(kind, id)
    return self:IsTracked("coll:" .. kind .. ":" .. tostring(id))
end

function Tasklist:TrackCollectible(kind, id, title)
    if not (kind and id) then return end
    local key = "coll:" .. kind .. ":" .. id
    if self:IsTracked(key) then self:Untrack(key); return false end
    self:Track({ key = key, title = title or (kind .. " " .. id), type = "once",
        source = "Collection", coll = { kind = kind, id = id } })
    return true
end

-- Programmatic auto-tasks (no ATT row needed): complete on quest turn-in / boss kill.
function Tasklist:AddQuest(questID, title, taskType)
    if not questID then return end
    self:Track({ key = "quest:" .. questID, title = title or ("Quest " .. questID),
        type = taskType or "once", source = "Quest", att = { key = "questID", id = questID } })
end

-- encounterID here is the DungeonEncounterID (the ID reported by ENCOUNTER_END /
-- BOSS_KILL), so the task completes on the live kill.
function Tasklist:AddEncounter(encounterID, title, taskType)
    if not encounterID then return end
    self:Track({ key = "enc:" .. encounterID, title = title or ("Boss " .. encounterID),
        type = taskType or "weekly", source = "Encounter", dungeonID = encounterID })
end

-- ---- on-screen tracker UI -------------------------------------------------
-- Modelled on Blizzard's Objective Tracker: SEE-THROUGH (no panel), a header bar
-- per task type, indented objective lines, anchored at its TOP-LEFT so it grows
-- strictly DOWNWARD. Constants mirror the objective tracker (blockOffsetX = 20,
-- lineSpacing = 4) and use its header-bar atlas + line fonts.
local HEADER_ATLAS = "UI-QuestTracker-Secondary-Objective-Header"
local HEADER_H     = 26                        -- room for the centered title
local HEADER_TINT  = { 0.16, 0.26, 0.42 }      -- desaturated quest header re-tinted blue-black
local INDENT       = 18
local LINE_GAP     = 4

function Tasklist:_BuildFrame()
    local p = self:_p()
    if p.frame then return end

    -- See-through: no backdrop. Only header bars + text are drawn over the world.
    local f = CreateFrame("Frame", "HagAIOTaskTracker", UIParent)
    f:SetSize(240, 30)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)

    -- Faint fill shown ONLY while moving in Edit Mode, so there's something to grab.
    local grab = f:CreateTexture(nil, "BACKGROUND")
    grab:SetAllPoints(f)
    grab:SetColorTexture(Theme.Unpack("accent", 0.18))
    grab:Hide()
    p.grab = grab

    p.frame, p.rows = f, {}

    if ns.EditMode then
        -- TOPLEFT anchor: the top stays fixed and the list grows down. A fresh key
        -- (taskTracker) so any old centre-anchored saved position is dropped.
        ns.EditMode:Register(f, {
            key = "taskTracker", label = "Task List", anchor = "TOPLEFT",
            default = { point = "TOPLEFT", x = 420, y = -260 },
            active = function() return self:IsEnabled() end,
            onEnter = function() grab:Show() end,
            onExit  = function() grab:Hide() end,
        })
    end
    f:Hide()
end

-- Rebuild the tracker: a header bar per task type, then its objective lines,
-- laid out top-down so the frame grows downward.
function Tasklist:_Refresh()
    if not self:IsEnabled() then return end
    self:_BuildFrame()
    local p = self:_p()
    for _, r in ipairs(p.rows) do r:Hide() end
    wipe(p.rows)

    local f = p.frame
    local width = f:GetWidth()
    local showDone = self:GetSetting("showCompleted") ~= false
    local headerFont = _G.ObjectiveTrackerHeaderFont or _G.GameFontNormal
    local lineFont   = _G.ObjectiveTrackerLineFont or _G.GameFontHighlightSmall

    local buckets = { once = {}, daily = {}, weekly = {} }
    for key, def in pairs(p.tasks) do
        local done = self:IsDone(key)
        if showDone or not done then
            local b = buckets[def.type] or buckets.once
            b[#b + 1] = { def = def, done = done }
        end
    end

    local y = 0
    local function header(text)
        -- The quest header bar, desaturated and re-tinted blue-black (solid, not a
        -- fade), with the title CENTERED.
        local bar = f:CreateTexture(nil, "ARTWORK")
        bar:SetPoint("TOPLEFT", 0, y)
        bar:SetPoint("TOPRIGHT", 0, y)
        bar:SetHeight(HEADER_H)
        bar:SetAtlas(HEADER_ATLAS, false)
        bar:SetDesaturated(true)
        bar:SetVertexColor(HEADER_TINT[1], HEADER_TINT[2], HEADER_TINT[3])
        p.rows[#p.rows + 1] = bar

        local t = f:CreateFontString(nil, "OVERLAY")
        t:SetFontObject(headerFont)
        t:SetPoint("CENTER", bar, "CENTER", 0, 0)
        t:SetText(text)
        t:SetTextColor(Theme.Unpack("accent"))
        p.rows[#p.rows + 1] = t
        y = y - HEADER_H - 2
    end

    local function objective(def, done)
        local t = f:CreateFontString(nil, "OVERLAY")
        t:SetFontObject(lineFont)
        t:SetPoint("TOPLEFT", INDENT, y)
        t:SetWidth(width - INDENT - 14)
        t:SetJustifyH("LEFT")
        t:SetText("- " .. (def.title or def.key))
        if done then t:SetTextColor(0.5, 0.5, 0.5) else t:SetTextColor(0.95, 0.95, 0.95) end
        p.rows[#p.rows + 1] = t
        local h = t:GetStringHeight()

        -- Remove (x) at the right edge
        local x = CreateFrame("Button", nil, f)
        x:SetSize(14, 14)
        x:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, y)
        local xfs = x:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        xfs:SetPoint("CENTER"); xfs:SetText("x"); xfs:SetTextColor(Theme.Unpack("textFaint"))
        x:SetScript("OnEnter", function() xfs:SetTextColor(Theme.Unpack("red")) end)
        x:SetScript("OnLeave", function() xfs:SetTextColor(Theme.Unpack("textFaint")) end)
        x:SetScript("OnClick", function() self:Remove(def.key) end)
        p.rows[#p.rows + 1] = x

        -- manual tasks: click the text to toggle done
        if def.manual then
            local btn = CreateFrame("Button", nil, f)
            btn:SetPoint("TOPLEFT", t, "TOPLEFT", 0, 0)
            btn:SetPoint("RIGHT", x, "LEFT", -2, 0)
            btn:SetHeight(h + 4)
            btn:SetScript("OnClick", function() self:SetDone(def.key, not done) end)
            p.rows[#p.rows + 1] = btn
        end
        y = y - (h + LINE_GAP)
    end

    local any = false
    for _, ttype in ipairs(TYPE_ORDER) do
        local list = buckets[ttype]
        if #list > 0 then
            any = true
            header(TYPE_LABEL[ttype])
            for _, item in ipairs(list) do objective(item.def, item.done) end
            y = y - 6
        end
    end

    if not any then
        local t = f:CreateFontString(nil, "OVERLAY")
        t:SetFontObject(lineFont)
        t:SetPoint("TOPLEFT", 2, y); t:SetText("No active tasks."); t:SetTextColor(0.6, 0.6, 0.6)
        p.rows[#p.rows + 1] = t
        y = y - 18
    end

    f:SetHeight(math.max(20, -y + 4))
end

-- Show when enabled & out of combat (and not empty); Edit Mode shows it regardless.
function Tasklist:_UpdateVisibility()
    local p = self:_p()
    if not p.frame then return end
    local editing = ns.EditMode and ns.EditMode:IsEditing()
    local show = self:IsEnabled() and (editing or not InCombatLockdown())
    p.frame:SetShown(show)
end

-- ---- settings page (custom: add/remove tasks) -----------------------------
function Tasklist:BuildSettingsPage(sf)
    local content = sf.content
    local width = sf:GetWidth(); if not width or width < 1 then width = 420 end
    content:SetWidth(width)
    local y = -4

    local show = W.Toggle(content, "Show completed tasks")
    show:SetPoint("TOPLEFT", 6, y)
    show:SetChecked(self:GetSetting("showCompleted") ~= false)
    show:SetOnToggle(function(on) self:SetSetting("showCompleted", on) end)
    y = y - 28

    y = y - 2

    local div = W.Divider(content); div:SetPoint("TOPLEFT", 6, y); div:SetPoint("RIGHT", content, "RIGHT", -6, 0); y = y - 14

    -- Add a task
    local addLbl = W.SectionLabel(content, "Add a task"); addLbl:SetPoint("TOPLEFT", 6, y); y = y - 22
    local input = W.Input(content, width - 230)
    input:SetPoint("TOPLEFT", 6, y)
    local seg = W.Segmented(content, {
        { value = "once", text = "Once" }, { value = "daily", text = "Daily" }, { value = "weekly", text = "Weekly" },
    })
    seg:SetValue("once")
    seg:SetPoint("LEFT", input, "RIGHT", 8, 0)
    local add = W.TextButton(content, "Add"); add:SetPoint("LEFT", seg, "RIGHT", 10, 0)
    local function submit()
        local title = input:GetValue()
        if title and title:match("%S") then
            self:AddCustom(title, seg:GetValue() or "once")
            input:SetValue("")
            if ns.UI.SettingsWindow then ns.UI.SettingsWindow:InvalidateModule(self:GetName()) end
        end
    end
    add:SetScript("OnClick", submit)
    input:SetScript("OnEnterPressed", function(s) s:ClearFocus(); submit() end)
    local hint = W.Text(content, "Manual tasks (tick them off yourself). e.g. \"Raid LK (weekly)\", \"Grind X mob\".",
        "textFaint", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 6, y - 26); hint:SetWidth(width - 16); hint:SetJustifyH("LEFT")
    y = y - 26 - hint:GetStringHeight() - 12

    local div2 = W.Divider(content); div2:SetPoint("TOPLEFT", 6, y); div2:SetPoint("RIGHT", content, "RIGHT", -6, 0); y = y - 14

    -- Current tasks (grouped by type) with Remove
    local cur = W.SectionLabel(content, "Current tasks"); cur:SetPoint("TOPLEFT", 6, y); y = y - 22
    local p = self:_p()
    local any = false
    for _, ttype in ipairs(TYPE_ORDER) do
        for key, def in pairs(p.tasks) do
            if def.type == ttype then
                any = true
                local done = self:IsDone(key)
                local lbl = W.Text(content, ("|cff5b6473[%s]|r %s"):format(TYPE_LABEL[def.type], def.title or key),
                    done and "textFaint" or "text", "GameFontHighlightSmall")
                lbl:SetPoint("TOPLEFT", 10, y); lbl:SetWidth(width - 90); lbl:SetJustifyH("LEFT")
                local rm = W.TextButton(content, "Remove")
                rm:SetPoint("TOPRIGHT", content, "TOPRIGHT", -6, y)
                rm.text:SetTextColor(Theme.Unpack("red"))
                rm:SetScript("OnClick", function()
                    self:Remove(key)
                    if ns.UI.SettingsWindow then ns.UI.SettingsWindow:InvalidateModule(self:GetName()) end
                end)
                y = y - (math.max(lbl:GetStringHeight(), 14) + 8)
            end
        end
    end
    if not any then
        local none = W.Text(content, "No tasks yet.", "textFaint", "GameFontHighlightSmall")
        none:SetPoint("TOPLEFT", 10, y); y = y - 20
    end

    content:SetHeight(math.max(30, -y + 8))
end

ns.ModuleManager:Register(Tasklist:New("Tasklist", {
    title = "Task List",
    description = "A movable objective tracker for one-time, daily and weekly tasks.",
    defaultEnabled = true,
    color = ns.Theme.hex.amber,  -- distinct tag (Core uses accent)
    settings = {
        { type = "header", text = "Task List" },
        { type = "toggle", key = "showCompleted", label = "Show completed tasks", default = true },
        { type = "note", text = "Move the tracker with Edit Mode. It hides automatically in combat." },
        { type = "note", text = "Other modules (e.g. ATT) add tasks here; daily/weekly tasks reset with the server." },
    },
}))
