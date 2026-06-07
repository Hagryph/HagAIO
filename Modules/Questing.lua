local addonName, ns = ...
local Class = ns.Class
local Theme = ns.Theme

-- Modules/Questing.lua
-- Everything around levelling through quests, in one module:
--   * Experience: tracks XP gained this session, shows XP/hour, time played and
--     projected time-to-level in a hover tooltip on the XP bar.
--   * Quests: auto-accepts offered quests and turns in completed ones; quests
--     with a choice of rewards are left for you to pick. Hold Shift to pause.

local Questing = Class.new("Questing", ns.Module)

-- ---- helpers --------------------------------------------------------------
local function commafy(n)
    return BreakUpLargeNumbers(math.floor(n + 0.5))
end

local function clock(seconds)
    if not seconds or seconds <= 0 then return "-" end
    seconds = math.floor(seconds)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = seconds % 60
    if h > 0 then return ("%dh %02dm"):format(h, m) end
    if m > 0 then return ("%dm %02ds"):format(m, s) end
    return ("%ds"):format(s)
end

local function maxLevel()
    if GetMaxLevelForPlayerExpansion then return GetMaxLevelForPlayerExpansion() end
    if GetMaxPlayerLevel then return GetMaxPlayerLevel() end
    return 80
end

local function findXPBar()
    return MainStatusTrackingBarContainer
        or _G.StatusTrackingBarManager
        or _G.MainMenuExpBar
end

local function currentQuestID()
    return GetQuestID and GetQuestID() or nil
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
    p.skipTurnIn = {}   -- questIDs that need a manual reward choice
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
            :format(UnitLevel("player"), perHour > 0 and commafy(perHour) or "-"))
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

local function statLine(tt, label, value, valueKey)
    local lr, lg, lb = Theme.Unpack("textDim")
    local vr, vg, vb = Theme.Unpack(valueKey or "text")
    tt:AddDoubleLine(label, value, lr, lg, lb, vr, vg, vb)
end

function Questing:_ShowTooltip()
    local p = self:_p()
    if not p.overlay then return end
    if not self:GetSetting("showTooltip") then
        if GameTooltip:IsOwned(p.overlay) then GameTooltip:Hide() end
        return
    end
    local tt = GameTooltip
    tt:SetOwner(p.overlay, "ANCHOR_TOP")
    tt:ClearLines()
    tt:AddLine("|cff" .. Theme.hex.accent .. "HagAIO|r  |cff" .. Theme.hex.gold .. "Questing|r")

    if UnitLevel("player") >= maxLevel() or UnitXPMax("player") == 0 then
        tt:AddLine("Max level - no experience to track.", Theme.Unpack("textDim"))
        tt:Show()
        return
    end
    if IsXPUserDisabled and IsXPUserDisabled() then
        tt:AddLine("XP gain is disabled.", Theme.Unpack("amber"))
    end

    local cur, max, pct, remaining, rested, sessionXP, perHour, elapsed, ttl = self:_Stats()

    statLine(tt, "Level", UnitLevel("player"), "accent")
    statLine(tt, "XP", ("%s / %s  (%.1f%%)"):format(commafy(cur), commafy(max), pct))
    statLine(tt, "Remaining", commafy(remaining))
    if rested and rested > 0 then
        statLine(tt, "Rested", ("%s  (%.0f%%)"):format(commafy(rested), max > 0 and (rested / max * 100) or 0), "gold")
    end

    tt:AddLine(" ")
    statLine(tt, "Session XP", commafy(sessionXP))
    statLine(tt, "XP / hour", perHour > 0 and commafy(perHour) or "-", "green")
    statLine(tt, "Time played", clock(elapsed))
    statLine(tt, "Time to level", clock(ttl), "accent")

    tt:Show()
end

function Questing:_EnsureOverlay()
    local p = self:_p()
    if p.overlay then return end
    local bar = findXPBar()
    if not bar then
        self:LogWarn("XP bar not found; hover tooltip unavailable (max level?)")
        return
    end

    local overlay = CreateFrame("Frame", "HagAIOQuestingXPOverlay", bar)
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
    if UnitLevel("player") >= maxLevel() or max == 0 then
        self:LogInfo("max level - no XP to track")
        return
    end
    self:LogInfo(("L%d  %s/%s (%.1f%%)  |  session %s  |  %s/hr  |  to level %s")
        :format(UnitLevel("player"), commafy(cur), commafy(max), pct,
            commafy(sessionXP), perHour > 0 and commafy(perHour) or "-", clock(ttl)))
end

-- ======================= QUESTS ============================================
function Questing:_Paused()
    if self:GetSetting("shiftPause") and IsShiftKeyDown() then return true end
    if self:GetSetting("pauseInstance") and IsInInstance() then return true end
    return false
end

function Questing:_OnDetail()
    if not self:GetSetting("autoAccept") or self:_Paused() then return end
    self:LogEchoInfo("accepted:", GetTitleText())
    AcceptQuest()
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
        local qid = currentQuestID()
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
            if acceptGrey or not q.isTrivial then  -- skip trivial (grey) quests unless opted in
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
            -- GetActiveTitle's completion flag is a boolean/number, so it's rarely nil;
            -- when it's falsy, fall back to the quest-log ready-for-turn-in check.
            if not isComplete and GetActiveQuestID and C_QuestLog and C_QuestLog.ReadyForTurnIn then
                local qid = GetActiveQuestID(i)
                isComplete = qid and C_QuestLog.ReadyForTurnIn(qid)
            end
            if isComplete then
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
    commands = { xp = { handler = "_PrintSession", help = "session XP / hour" } },
    events = {
        PLAYER_XP_UPDATE      = "_OnXP",
        PLAYER_LEVEL_UP       = "_OnLevelUp",
        PLAYER_ENTERING_WORLD = "_Snapshot",
        GOSSIP_SHOW           = "_OnGossip",
        QUEST_GREETING        = "_OnGreeting",
        QUEST_DETAIL          = "_OnDetail",
        QUEST_PROGRESS        = "_OnProgress",
        QUEST_COMPLETE        = "_OnComplete",
    },
    settings = {
        { type = "header", text = "Experience" },
        { type = "toggle", key = "showTooltip", label = "Show tooltip on the XP bar", default = true,
          desc = "Hover the XP bar for session XP per hour and time to level." },
        { type = "toggle", key = "echoLevelUp", label = "Announce XP/hour on level-up", default = false,
          desc = "Print your session rate to chat each time you level up." },

        { type = "header", text = "Quests" },
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
    },
}))
