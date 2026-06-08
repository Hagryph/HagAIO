local addonName, ns = ...
local Class = ns.Class
local Theme = ns.Theme

-- Modules/Questing.lua
-- Everything around levelling through quests, in one module:
--   * Experience: tracks XP gained this session, shows XP/hour, time played and
--     projected time-to-level in a hover tooltip on the XP bar.
--   * Quests: auto-accepts offered quests and turns in completed ones; quests
--     with a choice of rewards are left for you to pick. Hold Shift to pause.
--
-- TIMED QUESTS: the client exposes NOTHING about a quest's time limit while it's
-- only being offered (GetTimeAllowed / GetQuestLogTimeLeft / GetQuestTagInfo all
-- come back empty until the quest is in your log -- verified in-game, and Blizzard
-- only renders the timer in the quest-LOG UI templates). So a timed quest can't be
-- spotted before accepting it. Instead we learn: the first time one is auto-accepted
-- we detect the timer (now readable), abandon it, and remember its questID in an
-- ACCOUNT-WIDE registry -- so on every future encounter, on any character, it's
-- skipped before acceptance.

local Questing = Class.new("Questing", ns.Module, { mixins = { ns.Persisted } })

local clock = ns.Format.Clock   -- pure duration formatter (Lib/Format.lua)

-- ---- helpers (thousands-separated number wraps the WoW global; the rest wrap
-- spec/quest/frame lookups that only make sense against the live client) --------
function Questing:_Commafy(n)
    return BreakUpLargeNumbers(math.floor(n + 0.5))
end

function Questing:_MaxLevel()
    if GetMaxLevelForPlayerExpansion then return GetMaxLevelForPlayerExpansion() end
    if GetMaxPlayerLevel then return GetMaxPlayerLevel() end
    return 90   -- Midnight cap (fallback only; the APIs above are authoritative)
end

function Questing:_FindXPBar()
    return MainStatusTrackingBarContainer
        or _G.StatusTrackingBarManager
        or _G.MainMenuExpBar
end

function Questing:_CurrentQuestID()
    return GetQuestID and GetQuestID() or nil
end

-- The account-wide registry of known-timed quests ({ [questID] = totalSeconds }), or nil
-- before SavedVariables load. Learned over time (see _OnQuestAccepted), shared across
-- characters. (Older entries may be the boolean `true` -- pre-seconds; still truthy.)
function Questing:_TimedRegistry()
    local store = self:_Store()
    return store and store.timed or nil
end

-- A quest's live time limit, in seconds, is only readable once it's in your log (offered
-- quests always report nothing). C_QuestLog.GetTimeAllowed gives a positive total for timed
-- quests and nothing for ordinary ones. Returns the number or nil.
function Questing:_LiveSeconds(questID)
    if questID and C_QuestLog and C_QuestLog.GetTimeAllowed then
        local total = C_QuestLog.GetTimeAllowed(questID)
        if total and total > 0 then return total end
    end
    return nil
end

-- The pre-accept gate: a quest is treated as timed if we've LEARNED it is (account-wide
-- registry) or if its timer is somehow already readable. Offered timed quests are unknown
-- on the very first encounter -- they're caught post-accept and remembered for next time.
function Questing:_IsTimedQuest(questID)
    if not questID then return false end
    local reg = self:_TimedRegistry()
    if reg and reg[questID] then return true end
    return self:_LiveSeconds(questID) ~= nil
end

-- The known time limit (seconds) for a timed quest, or nil. Prefers a live in-log timer,
-- falls back to the learned registry value (a number; an older boolean entry yields nil).
function Questing:_TimedSeconds(questID)
    local live = self:_LiveSeconds(questID)
    if live then return live end
    local reg = self:_TimedRegistry()
    local v = reg and questID and reg[questID]
    return type(v) == "number" and v or nil
end

-- Record a questID as timed in the account-wide registry, storing its time limit (seconds).
function Questing:_RememberTimed(questID, seconds)
    local reg = self:_TimedRegistry()
    if reg and questID then reg[questID] = seconds or true end
end

function Questing:_QuestTitle(questID)
    return (C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID))
        or ("quest #" .. tostring(questID))
end

-- Abandon a quest by ID (select -> mark -> abandon, the modern C_QuestLog sequence).
function Questing:_AbandonQuest(questID)
    if not (C_QuestLog and C_QuestLog.SetSelectedQuest and C_QuestLog.AbandonQuest) then return end
    C_QuestLog.SetSelectedQuest(questID)
    if C_QuestLog.SetAbandonQuest then C_QuestLog.SetAbandonQuest() end
    C_QuestLog.AbandonQuest()
end

-- /hag questreset -- forget every learned timed quest (account-wide). Handy for testing:
-- afterwards the next encounter re-learns the quest's limit.
function Questing:_WipeTimed()
    local reg = self:_TimedRegistry()
    if reg then wipe(reg) end
    self:LogInfo("cleared learned timed quests")
end

-- ---- Advanced quest info: a time-limit banner above the offered-quest window ----------
-- Pretty duration string for the banner (Blizzard's SecondsToTime, falling back to clock).
local function timeString(seconds)
    if SecondsToTime then return SecondsToTime(seconds) end
    return clock(seconds)
end

-- The banner FontString floats just above the QuestFrame so it never overlaps the parchment
-- or scrolls with it. Created lazily the first time a quest window is shown.
function Questing:_EnsureQuestBanner()
    local p = self:_p()
    if p.questBanner then return p.questBanner end
    if not QuestFrame then return nil end
    local fs = QuestFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetPoint("BOTTOM", QuestFrame, "TOP", 0, 6)
    fs:SetShadowColor(0, 0, 0, 1)
    fs:SetShadowOffset(1, -1)
    fs:Hide()
    p.questBanner = fs
    return fs
end

function Questing:_HideQuestBanner()
    local fs = self:_p().questBanner
    if fs then fs:Hide() end
end

-- Show "Timed quest -- <time>" above the window when Advanced Quest Info is on and we know
-- the quest's limit; hide it otherwise. Independent of the auto-accept settings.
function Questing:_UpdateQuestBanner(questID)
    local fs = self:_EnsureQuestBanner()
    if not fs then return end
    local secs = self:GetSetting("advancedInfo") and self:_TimedSeconds(questID)
    if secs then
        fs:SetText(("|cff%sTimed quest|r  |cff%s%s|r")
            :format(Theme.hex.amber, Theme.hex.gold, timeString(secs)))
        fs:Show()
    else
        fs:Hide()
    end
end

-- ---- lifecycle ------------------------------------------------------------
function Questing:OnInitialize()
    local p = self:_p()
    -- experience
    p.startTime = nil
    p.sessionXP = 0
    p.lastXP, p.lastLevel, p.lastMax = 0, 0, 0
    p.overlay = nil
    p.hovering = false
    -- quests
    p.skipTurnIn = {}     -- questIDs that need a manual reward choice
    p.pendingAccept = {}  -- questIDs WE auto-accepted, awaiting QUEST_ACCEPTED (for the timed check)
    -- Account-wide registry of known-timed questIDs, learned as they're encountered.
    self:_BindStore("timedQuests", { timed = {} })
end

-- Event subscriptions are declared on the module (see registration below) and
-- wired/torn down automatically; OnEnable only does the one-off setup.
function Questing:OnEnable()
    local p = self:_p()
    self:_Snapshot()
    p.startTime = GetTime()
    p.sessionXP = 0
    self:_EnsureOverlay()
    if p.overlay then p.overlay:Show() end
end

function Questing:OnDisable()
    local p = self:_p()
    wipe(p.skipTurnIn)
    wipe(p.pendingAccept)
    self:_HideQuestBanner()
    if p.xpTicker then p.xpTicker:Cancel(); p.xpTicker = nil end
    if p.overlay then
        p.overlay:Hide()
        if GameTooltip:IsOwned(p.overlay) then GameTooltip:Hide() end
    end
end

-- ======================= EXPERIENCE ========================================
function Questing:_Snapshot()
    local p = self:_p()
    p.lastLevel = UnitLevel("player")
    p.lastXP = UnitXP("player")
    p.lastMax = UnitXPMax("player")
end

function Questing:_OnLevelUp()
    self:_Snapshot()
    if self:GetSetting("echoLevelUp") then
        local _, _, _, _, _, _, perHour = self:_Stats()
        -- Always announced to chat (even with Echo to Chat off) -- gated only by the
        -- echoLevelUp setting above.
        self:LogAnnounce(("ding! L%d - %s XP/hr this session")
            :format(UnitLevel("player"), perHour > 0 and self:_Commafy(perHour) or "-"))
    end
end

function Questing:_OnXP()
    local p = self:_p()
    local lvl = UnitLevel("player")
    local xp  = UnitXP("player")
    local max = UnitXPMax("player")

    if lvl == p.lastLevel then
        local delta = xp - p.lastXP
        if delta > 0 then p.sessionXP = p.sessionXP + delta end
    else
        p.sessionXP = p.sessionXP + math.max(0, p.lastMax - p.lastXP) + xp
    end

    p.lastLevel, p.lastXP, p.lastMax = lvl, xp, max
    if p.hovering then self:_ShowTooltip() end
end

-- Returns: cur, max, pct, remaining, rested, sessionXP, perHour, elapsed, ttl
function Questing:_Stats()
    local p = self:_p()
    local cur, max = UnitXP("player"), UnitXPMax("player")
    local pct = (max > 0) and (cur / max * 100) or 0
    local remaining = math.max(0, max - cur)
    local rested = GetXPExhaustion()
    local elapsed = p.startTime and (GetTime() - p.startTime) or 0
    local perHour = (elapsed > 1) and (p.sessionXP / (elapsed / 3600)) or 0
    local ttl = (perHour > 0) and (remaining / perHour * 3600) or nil
    return cur, max, pct, remaining, rested, p.sessionXP, perHour, elapsed, ttl
end

function Questing:_StatLine(tt, label, value, valueKey)
    local lr, lg, lb = Theme.Unpack("textDim")
    local vr, vg, vb = Theme.Unpack(valueKey or "text")
    tt:AddDoubleLine(label, value, lr, lg, lb, vr, vg, vb)
end

function Questing:_ShowTooltip()
    local p = self:_p()
    if not p.overlay then return end
    -- No tooltip when it's turned off, or at max level (no XP to track) -- just hide and bail.
    if not self:GetSetting("showTooltip")
        or UnitLevel("player") >= self:_MaxLevel() or UnitXPMax("player") == 0 then
        if GameTooltip:IsOwned(p.overlay) then GameTooltip:Hide() end
        return
    end
    local tt = GameTooltip
    tt:SetOwner(p.overlay, "ANCHOR_TOP")
    tt:ClearLines()
    tt:AddLine("|cff" .. Theme.hex.accent .. "HagAIO|r  |cff" .. Theme.hex.gold .. "Questing|r")

    if IsXPUserDisabled and IsXPUserDisabled() then
        tt:AddLine("XP gain is disabled.", Theme.Unpack("amber"))
    end

    local cur, max, pct, remaining, rested, sessionXP, perHour, elapsed, ttl = self:_Stats()

    self:_StatLine(tt, "Level", UnitLevel("player"), "accent")
    self:_StatLine(tt, "XP", ("%s / %s  (%.1f%%)"):format(self:_Commafy(cur), self:_Commafy(max), pct))
    self:_StatLine(tt, "Remaining", self:_Commafy(remaining))
    if rested and rested > 0 then
        self:_StatLine(tt, "Rested", ("%s  (%.0f%%)"):format(self:_Commafy(rested), max > 0 and (rested / max * 100) or 0), "gold")
    end

    tt:AddLine(" ")
    self:_StatLine(tt, "Session XP", self:_Commafy(sessionXP))
    self:_StatLine(tt, "XP / hour", perHour > 0 and self:_Commafy(perHour) or "-", "green")
    self:_StatLine(tt, "Time played", clock(elapsed))
    self:_StatLine(tt, "Time to level", clock(ttl), "accent")

    tt:Show()
end

function Questing:_EnsureOverlay()
    local p = self:_p()
    if p.overlay then return end
    local bar = self:_FindXPBar()
    if not bar then
        self:LogWarn("XP bar not found; hover tooltip unavailable (max level?)")
        return
    end

    local overlay = CreateFrame("Frame", nil, bar)
    overlay:SetAllPoints(bar)
    overlay:SetFrameLevel(bar:GetFrameLevel() + 10)
    if overlay.EnableMouseMotion then
        overlay:EnableMouseMotion(true)
    else
        overlay:EnableMouse(true)
    end

    -- Refresh the tooltip on a 0.5s ticker only WHILE hovered (started on enter,
    -- cancelled on leave) -- no per-frame OnUpdate burning cycles when not hovering.
    overlay:SetScript("OnEnter", function()
        p.hovering = true
        self:_ShowTooltip()
        if p.xpTicker then p.xpTicker:Cancel() end
        p.xpTicker = C_Timer.NewTicker(0.5, function() self:_ShowTooltip() end)
    end)
    overlay:SetScript("OnLeave", function()
        p.hovering = false
        if p.xpTicker then p.xpTicker:Cancel(); p.xpTicker = nil end
        if GameTooltip:IsOwned(overlay) then GameTooltip:Hide() end
    end)

    p.overlay = overlay
end

function Questing:_PrintSession()
    local cur, max, pct, remaining, rested, sessionXP, perHour, elapsed, ttl = self:_Stats()
    if UnitLevel("player") >= self:_MaxLevel() or max == 0 then
        self:LogInfo("max level - no XP to track")
        return
    end
    self:LogInfo(("L%d  %s/%s (%.1f%%)  |  session %s  |  %s/hr  |  to level %s")
        :format(UnitLevel("player"), self:_Commafy(cur), self:_Commafy(max), pct,
            self:_Commafy(sessionXP), perHour > 0 and self:_Commafy(perHour) or "-", clock(ttl)))
end

-- ======================= QUESTS ============================================
function Questing:_Paused()
    if self:GetSetting("shiftPause") and IsShiftKeyDown() then return true end
    if self:GetSetting("pauseInstance") and IsInInstance() then return true end
    return false
end

function Questing:_OnDetail()
    local qid = self:_CurrentQuestID()
    -- Advanced info runs regardless of the auto-accept settings -- show the time banner on any
    -- timed-quest window the player opens.
    self:_UpdateQuestBanner(qid)

    if not self:GetSetting("autoAccept") or self:_Paused() then return end
    -- Skip quests we already KNOW are timed (learned account-wide) before accepting. This is
    -- the universal gate: gossip/greeting selections all open the quest-detail window before
    -- any quest is accepted. A first-seen timed quest is unknown here and gets caught
    -- post-accept by _OnQuestAccepted, then remembered so it lands here next time.
    if self:_IsTimedQuest(qid) then return end
    -- Mark it ours so QUEST_ACCEPTED can catch it if it turns out to be timed (the limit
    -- only becomes readable once it's in the log).
    if qid then self:_p().pendingAccept[qid] = true end
    self:LogEchoInfo("accepted:", GetTitleText())
    AcceptQuest()
end

-- A quest we auto-accepted has landed in the log -- now its timer is readable. If it's
-- timed, abandon it and remember it account-wide so it's skipped before acceptance next
-- time (on any character). Quests we didn't auto-accept (manual / shift-paused) are left
-- alone. QUEST_ACCEPTED payload is (questID) on retail, (questLogIndex, questID) on classic.
function Questing:_OnQuestAccepted(_, a, b)
    local questID = b or a
    local p = self:_p()
    if not questID or not p.pendingAccept[questID] then return end
    p.pendingAccept[questID] = nil
    -- Defer one tick: the log timer isn't always initialised the instant the event fires.
    C_Timer.After(0.1, function()
        local secs = self:_LiveSeconds(questID)
        if not secs then return end
        self:_RememberTimed(questID, secs)   -- store the limit for the advanced-info banner
        self:_AbandonQuest(questID)
        self:LogWarnAlways("auto-abandoned timed quest:", self:_QuestTitle(questID))
    end)
end

function Questing:_OnProgress()
    if not self:GetSetting("autoTurnIn") or self:_Paused() then return end
    if IsQuestCompletable() then
        CompleteQuest()
    end
end

function Questing:_OnComplete()
    if not self:GetSetting("autoTurnIn") or self:_Paused() then return end
    local choices = GetNumQuestChoices() or 0
    if choices > 1 then
        local qid = self:_CurrentQuestID()
        if qid then self:_p().skipTurnIn[qid] = true end
        return
    end
    self:LogEchoSuccess("turned in:", GetTitleText())
    GetQuestReward(1)
end

-- one quest actioned per window; selecting it reopens the NPC for the next
function Questing:_OnGossip()
    if self:_Paused() then return end
    local p = self:_p()

    if self:GetSetting("autoTurnIn") and C_GossipInfo and C_GossipInfo.GetActiveQuests then
        for _, q in ipairs(C_GossipInfo.GetActiveQuests()) do
            if q.isComplete and not p.skipTurnIn[q.questID] then
                C_GossipInfo.SelectActiveQuest(q.questID)
                return
            end
        end
    end

    if self:GetSetting("autoAccept") and C_GossipInfo and C_GossipInfo.GetAvailableQuests then
        local acceptGrey = self:GetSetting("acceptGrey")
        for _, q in ipairs(C_GossipInfo.GetAvailableQuests()) do
            -- skip trivial (grey) quests unless opted in, and always skip timed quests
            if (acceptGrey or not q.isTrivial) and not self:_IsTimedQuest(q.questID) then
                C_GossipInfo.SelectAvailableQuest(q.questID)
                return
            end
        end
    end

    -- Auto-advance a lone dialogue option, but only on a pure-dialogue NPC
    -- (no quests to accept or turn in).
    if self:GetSetting("autoDialogue") and C_GossipInfo and C_GossipInfo.GetOptions then
        local active = (C_GossipInfo.GetActiveQuests and C_GossipInfo.GetActiveQuests()) or {}
        local avail  = (C_GossipInfo.GetAvailableQuests and C_GossipInfo.GetAvailableQuests()) or {}
        if #active == 0 and #avail == 0 then
            local options = C_GossipInfo.GetOptions()
            if options and #options == 1 and options[1].gossipOptionID then
                C_GossipInfo.SelectOption(options[1].gossipOptionID)
            end
        end
    end
end

function Questing:_OnGreeting()
    if self:_Paused() then return end

    if self:GetSetting("autoTurnIn") then
        for i = 1, GetNumActiveQuests() do
            local _, isComplete = GetActiveTitle(i)
            -- GetActiveTitle's completion flag may be a number (0/1) -- and 0 is TRUTHY in
            -- Lua -- so normalise to a real boolean before testing. When not complete, fall
            -- back to the quest-log ready-for-turn-in check.
            local complete = isComplete == true or isComplete == 1
            if not complete and GetActiveQuestID and C_QuestLog and C_QuestLog.ReadyForTurnIn then
                local qid = GetActiveQuestID(i)
                complete = (qid and C_QuestLog.ReadyForTurnIn(qid)) or false
            end
            if complete then
                SelectActiveQuest(i)
                return
            end
        end
    end

    if self:GetSetting("autoAccept") and GetNumAvailableQuests and GetNumAvailableQuests() > 0 then
        SelectAvailableQuest(1)
    end
end

-- ---- registration ---------------------------------------------------------
ns.ModuleManager:Register(Questing:New("Questing", {
    title = "Questing",
    description = "XP-per-hour tracking, plus auto-accepting and turning in quests.",
    defaultEnabled = true,
    color = ns.Theme.hex.gold,
    deps = { "SlashCommand" },  -- for its declarative /hag xp sub-command
    commands = {
        xp          = { handler = "_PrintSession", help = "session XP / hour" },
        questreset  = { handler = "_WipeTimed",    help = "forget learned timed quests" },
    },
    events = {
        PLAYER_XP_UPDATE      = "_OnXP",
        PLAYER_LEVEL_UP       = "_OnLevelUp",
        PLAYER_ENTERING_WORLD = "_Snapshot",
        GOSSIP_SHOW           = "_OnGossip",
        QUEST_GREETING        = "_OnGreeting",
        QUEST_DETAIL          = "_OnDetail",
        QUEST_ACCEPTED        = "_OnQuestAccepted",
        QUEST_PROGRESS        = "_OnProgress",
        QUEST_COMPLETE        = "_OnComplete",
        QUEST_FINISHED        = "_HideQuestBanner",
    },
    settings = {
        { type = "header", text = "Experience" },
        { type = "toggle", key = "showTooltip", label = "Show tooltip on the XP bar", default = true,
          desc = "Hover the XP bar for session XP per hour and time to level." },
        { type = "toggle", key = "echoLevelUp", label = "Announce XP/hour on level-up", default = false,
          desc = "Print your session rate to chat each time you level up." },

        { type = "header", text = "Quests" },
        { type = "toggle", key = "advancedInfo", label = "Advanced quest info", default = false,
          desc = "Show how long you have on timed quests at the top of the quest window." },
        { type = "toggle", key = "autoAccept", label = "Auto-accept quests", default = false },
        { type = "toggle", key = "acceptGrey", label = "Accept grey quests", default = false,
          dependsOn = "autoAccept",
          desc = "Also accept trivial quests too low-level to award XP. Off by default so they're skipped." },
        { type = "toggle", key = "autoTurnIn", label = "Auto-turn-in quests", default = false },
        { type = "toggle", key = "autoDialogue", label = "Auto-advance single dialogue", default = false,
          desc = "When an NPC has only one dialogue option (and no quests), pick it automatically." },
        { type = "toggle", key = "shiftPause", label = "Hold Shift to pause", default = true,
          dependsOn = { "autoAccept", "autoTurnIn", "autoDialogue" },
          desc = "Hold Shift while talking to an NPC to handle it yourself." },
        { type = "toggle", key = "pauseInstance", label = "Pause inside instances", default = false,
          dependsOn = { "autoAccept", "autoTurnIn", "autoDialogue" },
          desc = "Skip quest automation while in dungeons and raids." },
        { type = "note", text = "Quests that let you choose between rewards are left open so you can pick." },
        { type = "note", text = "Timed quests aren't kept by auto-accept -- they're dropped so you can take them on yourself when you're ready." },
    },
}))
