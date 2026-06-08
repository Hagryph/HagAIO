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

-- The closed set of task buckets: a frozen key->section-header map. Only ever read with a
-- key drawn from TYPE_ORDER, which also drives render order (Enum keys would sort
-- alphabetically, so the sequence stays a plain list).
local TYPE_LABEL = ns.Enum.new("TaskTypeLabel", { once = "Tasks", daily = "Daily", weekly = "Weekly" })
local TYPE_ORDER = { "once", "daily", "weekly" }

-- Is an item collected? Prefer ATT's knowledge, since it covers every collectible.
function Tasklist:_ItemCollected(itemID)
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
function Tasklist:_AttDone(attKey, id)
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
function Tasklist:_CollectibleCollected(kind, id)
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
    -- ns.Tasks is published by the Module base (opts.publishAs) before this runs.
    local p = self:_p()
    p.tasks = {}          -- key -> runtime def
    p.subscribed = {}     -- event -> true: dedupe self:On so each event is hooked once
    p.eventTasks = {}     -- event -> { key -> def }: reverse index so a fire dispatches
                          -- ONLY to interested tasks (never scan all tasks; never debounce)
    -- db.state / db.tracked / db.nextId are pre-seeded from dbSchema (see registration).
end

function Tasklist:OnEnable()
    -- Lifecycle subscriptions via self:On -> auto-released on disable (no manual tokens).
    self:On("PLAYER_REGEN_DISABLED", function() self:_UpdateVisibility() end)
    self:On("PLAYER_REGEN_ENABLED",  function() self:_UpdateVisibility() end)
    self:On("PLAYER_ENTERING_WORLD", function() self:_CheckResets() end)
    -- Authoritative live boss-kill detection (see DBM/BigWigs + warcraft.wiki):
    -- ENCOUNTER_END success==1 / BOSS_KILL, matched on the DungeonEncounterID.
    self:On("ENCOUNTER_END", function(_, encID, _, _, _, success) self:_OnEncounterEnd(encID, success) end)
    self:On("BOSS_KILL",     function(_, encID) self:_OnEncounterEnd(encID, 1) end)

    -- re-create persistent tracked tasks
    for key, t in pairs(self:GetDB().tracked) do self:_RegisterTracked(key, t) end

    self:_CheckResets()
    self:Every(60, function() self:_CheckResets() end)  -- catch resets while logged in (auto-cancelled on disable)
    self:_Refresh()
    self:_UpdateVisibility()
end

function Tasklist:OnDisable()
    local p = self:_p()
    -- Every self:On / self:Every subscription is released by the framework (_ReleaseAll);
    -- just reset the per-event dedupe so re-enabling re-hooks the task events.
    wipe(p.subscribed)
    if p.frame then p.frame:Hide() end
end


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
    for _, ev in ipairs(def.events or {}) do
        self:_SubscribeEvent(ev)
        local idx = p.eventTasks[ev]; if not idx then idx = {}; p.eventTasks[ev] = idx end
        idx[def.key] = def
    end
    self:_Evaluate(def)
    self:_Refresh()
    return def
end

function Tasklist:Unregister(key)
    local p = self:_p()
    local def = p.tasks[key]
    if def then
        for _, ev in ipairs(def.events or {}) do
            if p.eventTasks[ev] then p.eventTasks[ev][key] = nil end
        end
    end
    p.tasks[key] = nil
    self:_Refresh()
end

function Tasklist:IsDone(key)
    return self:_State(key).done and true or false
end

function Tasklist:SetDone(key, done)
    local st = self:_State(key)
    local def = self:_p().tasks[key]
    st.done = done and true or false
    -- Only a registered task carries a reset stamp; an unknown key (a stale SetDone) stays
    -- a one-time mark by design rather than silently becoming a never-resetting task.
    st.resetAt = (done and def) and self:_NextReset(def.type) or nil
    self:_Refresh()
    self:_UpdateVisibility()
end

function Tasklist:_SubscribeEvent(ev)
    local p = self:_p()
    if p.subscribed[ev] then return end
    p.subscribed[ev] = true
    self:On(ev, function(_, ...) self:_OnEvent(ev, ...) end)  -- auto-released on disable
end

-- Dispatch ONE event to exactly the tasks that registered for it (reverse index), every
-- fire -- no scan of all tasks, no debouncing (a coalesced fire could drop the state
-- change that mattered).
function Tasklist:_OnEvent(ev, ...)
    local tasks = self:_p().eventTasks[ev]
    if not tasks then return end
    for _, def in pairs(tasks) do
        if not def.manual and not self:IsDone(def.key) then
            self:_Evaluate(def, ...)
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
    local secs
    if taskType == "daily" and cd and cd.GetSecondsUntilDailyReset then
        secs = cd.GetSecondsUntilDailyReset()
    elseif taskType == "weekly" and cd and cd.GetSecondsUntilWeeklyReset then
        secs = cd.GetSecondsUntilWeeklyReset()
    end
    return ns.TaskRules:ResetAt(taskType, time(), secs)   -- pure rule (Lib/TaskRules.lua)
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
        condition = function() return self:_AttDone(ak, aid) end
    elseif t.coll and t.coll.kind and t.coll.id then  -- collection-journal collectible
        local kind, id = t.coll.kind, t.coll.id
        condition = function() return self:_CollectibleCollected(kind, id) end
    elseif t.itemID then                              -- plain item collectible
        local itemID = t.itemID
        condition = function() return self:_ItemCollected(itemID) end
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

-- Stable task key for an ATT group (its key field + id, else item/name). Pure rule in
-- Lib/TaskRules.lua so the key format -- an integration contract -- is unit-tested.
function Tasklist:ATTKey(ref)
    return ns.TaskRules:ATTKey(ref)
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
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(240, 30)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)

    -- Faint fill shown ONLY while moving in Edit Mode, so there's something to grab.
    local grab = f:CreateTexture(nil, "BACKGROUND")
    grab:SetAllPoints(f)
    grab:SetColorTexture(Theme.Unpack("accent", 0.18))
    grab:Hide()
    p.grab = grab

    p.frame = f

    if ns.EditMode then
        -- TOPLEFT anchor: the top stays fixed and the list grows down. A fresh key
        -- (taskTracker) so any old centre-anchored saved position is dropped.
        ns.EditMode:Register(f, {
            key = "taskTracker", label = "Task List", anchor = "TOPLEFT",
            default = { point = "TOPLEFT", x = 420, y = -260 },
            active = function() return self:IsEnabled() end,
            -- entering Edit Mode renders the sample preview (IsEditing() is already true here); exiting
            -- clears it and re-checks visibility so an empty tracker hides again.
            onEnter = function() grab:Show(); self:_Refresh() end,
            onExit  = function() grab:Hide(); self:_Refresh(); self:_UpdateVisibility() end,
        })
    end
    f:Hide()
end

-- Static row-button handlers: set on the pooled buttons each refresh WITHOUT allocating a
-- fresh closure per task. They read the owning list + task key off the button (b._list/_key).
local function rmOnEnter(b)  b.label:SetTextColor(Theme.Unpack("red")) end
local function rmOnLeave(b)  b.label:SetTextColor(Theme.Unpack("textFaint")) end
local function rmOnClick(b)  b._list:Remove(b._key) end
local function manualOnClick(b) b._list:SetDone(b._key, not b._list:IsDone(b._key)) end

-- Rebuild the tracker: a header bar per task type, then its objective lines,
-- laid out top-down so the frame grows downward.
function Tasklist:_Refresh()
    if not self:IsEnabled() then return end
    self:_BuildFrame()
    local p = self:_p()
    local f = p.frame

    -- Reuse pooled widgets instead of creating fresh ones each rebuild: WoW can't GC
    -- frames, so the old "CreateFrame every refresh" leaked a Button per task on every
    -- change. Each kind (texture / fontstring / button) has a free-list; we hand them out
    -- by a per-kind cursor and hide whatever's left over from a previous, larger build.
    p.pool = p.pool or { tex = {}, fs = {}, btn = {} }
    local pool, n = p.pool, { tex = 0, fs = 0, btn = 0 }
    local function tex()
        n.tex = n.tex + 1
        local w = pool.tex[n.tex]
        if not w then w = f:CreateTexture(nil, "ARTWORK"); pool.tex[n.tex] = w end
        w:ClearAllPoints(); w:Show(); return w
    end
    local function fs(font)
        n.fs = n.fs + 1
        local w = pool.fs[n.fs]
        if not w then w = f:CreateFontString(nil, "OVERLAY"); pool.fs[n.fs] = w end
        w:ClearAllPoints(); w:SetWidth(0); w:SetFontObject(font); w:Show(); return w
    end
    local function btn()
        n.btn = n.btn + 1
        local w = pool.btn[n.btn]
        if not w then
            w = CreateFrame("Button", nil, f)
            w.label = w:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            pool.btn[n.btn] = w
        end
        w:ClearAllPoints()
        w:SetScript("OnEnter", nil); w:SetScript("OnLeave", nil); w:SetScript("OnClick", nil)
        w.label:ClearAllPoints(); w.label:SetPoint("CENTER"); w.label:SetText("")
        w:Show(); return w
    end

    local width = f:GetWidth()
    local showDone = self:GetSetting("showCompleted") ~= false
    local headerFont = _G.ObjectiveTrackerHeaderFont or _G.GameFontNormal
    local lineFont   = _G.ObjectiveTrackerLineFont or _G.GameFontHighlightSmall

    local buckets = { once = {}, daily = {}, weekly = {} }
    for key, def in pairs(p.tasks) do
        if showDone or not self:IsDone(key) then
            local b = buckets[def.type] or buckets.once
            b[#b + 1] = def
        end
    end

    local y = 0
    local function header(text)
        -- The quest header bar, desaturated and re-tinted blue-black (solid, not a
        -- fade), with the title CENTERED.
        local bar = tex()
        bar:SetPoint("TOPLEFT", 0, y)
        bar:SetPoint("TOPRIGHT", 0, y)
        bar:SetHeight(HEADER_H)
        bar:SetAtlas(HEADER_ATLAS, false)
        bar:SetDesaturated(true)
        bar:SetVertexColor(HEADER_TINT[1], HEADER_TINT[2], HEADER_TINT[3])

        local t = fs(headerFont)
        t:SetPoint("CENTER", bar, "CENTER", 0, 0)
        t:SetText(text)
        t:SetTextColor(Theme.Unpack("accent"))
        y = y - HEADER_H - 2
    end

    local function objective(def)
        local done = self:IsDone(def.key)
        local t = fs(lineFont)
        t:SetPoint("TOPLEFT", INDENT, y)
        t:SetWidth(width - INDENT - 14)
        t:SetJustifyH("LEFT")
        t:SetText("- " .. (def.title or def.key))
        if done then t:SetTextColor(0.5, 0.5, 0.5) else t:SetTextColor(0.95, 0.95, 0.95) end
        local h = t:GetStringHeight()

        -- Remove (x) at the right edge. The list + key ride on the button so the OnEnter/
        -- OnLeave/OnClick handlers can stay shared module functions (no per-task closures).
        local x = btn()
        x:SetSize(14, 14)
        x:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, y)
        x.label:SetText("x"); x.label:SetTextColor(Theme.Unpack("textFaint"))
        x._list, x._key = self, def.key
        x:SetScript("OnEnter", rmOnEnter)
        x:SetScript("OnLeave", rmOnLeave)
        x:SetScript("OnClick", rmOnClick)

        -- manual tasks: click the text to toggle done
        if def.manual then
            local mbtn = btn()
            mbtn:SetPoint("TOPLEFT", t, "TOPLEFT", 0, 0)
            mbtn:SetPoint("RIGHT", x, "LEFT", -2, 0)
            mbtn:SetHeight(h + 4)
            mbtn._list, mbtn._key = self, def.key
            mbtn:SetScript("OnClick", manualOnClick)
        end
        y = y - (h + LINE_GAP)
    end

    local any = false
    for _, ttype in ipairs(TYPE_ORDER) do
        local list = buckets[ttype]
        if #list > 0 then
            any = true
            header(TYPE_LABEL[ttype])
            for _, def in ipairs(list) do objective(def) end
            y = y - 6
        end
    end

    p.hasTasks = any   -- drives visibility: an empty tracker hides itself (see _UpdateVisibility)
    local editing = ns.EditMode and ns.EditMode:IsEditing()

    if not any and not editing then
        local t = fs(lineFont)
        t:SetPoint("TOPLEFT", 2, y); t:SetText("No active tasks."); t:SetTextColor(0.6, 0.6, 0.6)
        y = y - 18
    end

    -- Edit Mode: pad the tracker to at least 500px with faint SAMPLE lines so it's always visible and
    -- grabbable while positioning -- whether it's empty (then we also lead with the section headers)
    -- or just shorter than 500px with a few real tasks.
    if editing then
        local function sample(text)
            local t = fs(lineFont)
            t:SetPoint("TOPLEFT", INDENT, y); t:SetWidth(width - INDENT - 14); t:SetJustifyH("LEFT")
            t:SetText(text); t:SetTextColor(0.55, 0.55, 0.55)
            y = y - (t:GetStringHeight() + LINE_GAP)
        end
        if not any then
            for _, ttype in ipairs(TYPE_ORDER) do
                header(TYPE_LABEL[ttype])
                for i = 1, 3 do sample("- " .. TYPE_LABEL[ttype] .. " sample " .. i) end
                y = y - 6
            end
        end
        while -y < 500 do sample("- sample task") end
    end

    -- hide any widgets left over from a previous, larger build
    for i = n.tex + 1, #pool.tex do pool.tex[i]:Hide() end
    for i = n.fs  + 1, #pool.fs  do pool.fs[i]:Hide() end
    for i = n.btn + 1, #pool.btn do pool.btn[i]:Hide() end

    f:SetHeight(math.max(20, -y + 4))
end

-- Edit Mode shows it regardless (so it can be positioned). Otherwise it shows only when it actually
-- has tasks AND we're out of combat -- an empty tracker hides itself.
function Tasklist:_UpdateVisibility()
    local p = self:_p()
    if not p.frame then return end
    local editing = ns.EditMode and ns.EditMode:IsEditing()
    local show = self:IsEnabled() and (editing or (p.hasTasks and not InCombatLockdown()))
    p.frame:SetShown(show and true or false)
end

-- ---- settings page (custom: add/remove tasks) -----------------------------
function Tasklist:BuildSettingsPage(sf)
    local content = sf.content
    local width = sf:GetWidth(); if not width or width < 1 then width = 420 end
    content:SetWidth(width)
    local y = -4

    local show = W.Toggle:New(content, "Show completed tasks")
    show:SetPoint("TOPLEFT", 6, y)
    show:SetChecked(self:GetSetting("showCompleted") ~= false)
    show:SetOnToggle(function(on) self:SetSetting("showCompleted", on) end)
    y = y - 28

    y = y - 2

    local div = W.Divider:New(content); div:SetPoint("TOPLEFT", 6, y); div:SetPoint("RIGHT", content, "RIGHT", -6, 0); y = y - 14

    -- Add a task
    local addLbl = W.SectionLabel:New(content, "Add a task"); addLbl:SetPoint("TOPLEFT", 6, y); y = y - 22
    local input = W.Input:New(content, width - 230)
    input:SetPoint("TOPLEFT", 6, y)
    local seg = W.Segmented:New(content, {
        { value = "once", text = "Once" }, { value = "daily", text = "Daily" }, { value = "weekly", text = "Weekly" },
    })
    seg:SetValue("once")
    seg:SetPoint("LEFT", input, "RIGHT", 8, 0)
    local add = W.TextButton:New(content, "Add"); add:SetPoint("LEFT", seg, "RIGHT", 10, 0)
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
    local hint = W.Text:New(content, "Manual tasks (tick them off yourself). e.g. \"Raid LK (weekly)\", \"Grind X mob\".",
        "textFaint", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 6, y - 26); hint:SetWidth(width - 16); hint:SetJustifyH("LEFT")
    y = y - 26 - hint:GetStringHeight() - 12

    local div2 = W.Divider:New(content); div2:SetPoint("TOPLEFT", 6, y); div2:SetPoint("RIGHT", content, "RIGHT", -6, 0); y = y - 14

    -- Current tasks (grouped by type) with Remove
    local cur = W.SectionLabel:New(content, "Current tasks"); cur:SetPoint("TOPLEFT", 6, y); y = y - 22
    local p = self:_p()
    local any = false
    -- Bucket tasks by type ONCE (not a scan of every task per type), then render in
    -- TYPE_ORDER.
    local byType = {}
    for key, def in pairs(p.tasks) do
        local bucket = byType[def.type]
        if not bucket then bucket = {}; byType[def.type] = bucket end
        bucket[#bucket + 1] = { key = key, def = def }
    end
    for _, ttype in ipairs(TYPE_ORDER) do
        for _, entry in ipairs(byType[ttype] or {}) do
            local key, def = entry.key, entry.def
            any = true
            local done = self:IsDone(key)
            local lbl = W.Text:New(content, ("|cff5b6473[%s]|r %s"):format(TYPE_LABEL[def.type], def.title or key),
                done and "textFaint" or "text", "GameFontHighlightSmall")
            lbl:SetPoint("TOPLEFT", 10, y); lbl:SetWidth(width - 90); lbl:SetJustifyH("LEFT")
            local rm = W.TextButton:New(content, "Remove")
            rm:SetPoint("TOPRIGHT", content, "TOPRIGHT", -6, y)
            rm.text:SetTextColor(Theme.Unpack("red"))
            rm:SetScript("OnClick", function()
                self:Remove(key)
                if ns.UI.SettingsWindow then ns.UI.SettingsWindow:InvalidateModule(self:GetName()) end
            end)
            y = y - (math.max(lbl:GetStringHeight(), 14) + 8)
        end
    end
    if not any then
        local none = W.Text:New(content, "No tasks yet.", "textFaint", "GameFontHighlightSmall")
        none:SetPoint("TOPLEFT", 10, y); y = y - 20
    end

    content:SetHeight(math.max(30, -y + 8))
end

ns.ModuleManager:Register(Tasklist:New("Tasklist", {
    title = "Task List",
    description = "A movable objective tracker for one-time, daily and weekly tasks.",
    defaultEnabled = true,
    publishAs = "Tasks",         -- ns.Tasks: other modules register tasks through it
    color = ns.Theme.hex.amber,  -- distinct tag (Core uses accent)
    deps = { "EditMode", "SettingsWindow" },  -- movable frame, page refresh (events go through self:On)
    -- Persisted structure (seeded on bind, before OnInitialize):
    dbSchema = {
        state   = {},  -- key -> { done, resetAt }
        tracked = {},  -- key -> { title, itemID, type, source }  (persistent)
        nextId  = 0,   -- counter for unique manual-task keys
    },
    -- Any settings change just refreshes the tracker.
    settingsWatch = { ["*"] = "_Refresh" },
    settings = {
        { type = "header", text = "Task List" },
        { type = "toggle", key = "showCompleted", label = "Show completed tasks", default = true },
        { type = "note", text = "Move the tracker with Edit Mode. It hides automatically in combat." },
        { type = "note", text = "Other modules (e.g. ATT) add tasks here; daily/weekly tasks reset with the server." },
    },
}))
