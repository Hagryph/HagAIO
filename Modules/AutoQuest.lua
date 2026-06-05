local addonName, ns = ...
local Class = ns.Class

-- Modules/AutoQuest.lua
-- Automatically accepts quests offered by NPCs and turns in completed ones.
-- Quests that let you choose between several rewards are left open so you pick.
-- Hold Shift (optional) to handle an NPC manually.

local AutoQuest = Class.new("AutoQuest", ns.Module)

function AutoQuest:OnInitialize()
    local p = self:_p()
    p.tokens = {}
    p.skipTurnIn = {}   -- questIDs that need a manual reward choice
end

function AutoQuest:OnEnable()
    local p = self:_p()
    local bus = ns.EventBus.Get()
    p.tokens["GOSSIP_SHOW"]     = bus:On("GOSSIP_SHOW",     function() self:_OnGossip() end)
    p.tokens["QUEST_GREETING"]  = bus:On("QUEST_GREETING",  function() self:_OnGreeting() end)
    p.tokens["QUEST_DETAIL"]    = bus:On("QUEST_DETAIL",    function() self:_OnDetail() end)
    p.tokens["QUEST_PROGRESS"]  = bus:On("QUEST_PROGRESS",  function() self:_OnProgress() end)
    p.tokens["QUEST_COMPLETE"]  = bus:On("QUEST_COMPLETE",  function() self:_OnComplete() end)
end

function AutoQuest:OnDisable()
    local p = self:_p()
    local bus = ns.EventBus.Get()
    for event, token in pairs(p.tokens) do bus:Off(event, token) end
    wipe(p.tokens)
    wipe(p.skipTurnIn)
end

-- ---- helpers --------------------------------------------------------------
function AutoQuest:_Paused()
    if self:GetSetting("shiftPause") and IsShiftKeyDown() then return true end
    if self:GetSetting("pauseInstance") and IsInInstance() then return true end
    return false
end

local function currentQuestID()
    return GetQuestID and GetQuestID() or nil
end

-- ---- single-quest dialogs -------------------------------------------------
function AutoQuest:_OnDetail()
    if not self:GetSetting("autoAccept") or self:_Paused() then return end
    self:LogInfo("accepted:", GetTitleText())
    AcceptQuest()
end

function AutoQuest:_OnProgress()
    if not self:GetSetting("autoTurnIn") or self:_Paused() then return end
    if IsQuestCompletable() then
        CompleteQuest()
    end
end

function AutoQuest:_OnComplete()
    if not self:GetSetting("autoTurnIn") or self:_Paused() then return end
    local choices = GetNumQuestChoices() or 0
    if choices > 1 then
        -- multiple rewards: leave it open for the player to pick
        local qid = currentQuestID()
        if qid then self:_p().skipTurnIn[qid] = true end
        return
    end
    self:LogSuccess("turned in:", GetTitleText())
    GetQuestReward(1)
end

-- ---- multi-quest NPCs -----------------------------------------------------
-- Only one quest can be actioned per window; selecting it reopens the NPC for
-- the next, so we handle a single quest then return.
function AutoQuest:_OnGossip()
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
        local avail = C_GossipInfo.GetAvailableQuests()
        if avail and avail[1] then
            C_GossipInfo.SelectAvailableQuest(avail[1].questID)
            return
        end
    end
end

function AutoQuest:_OnGreeting()
    if self:_Paused() then return end

    if self:GetSetting("autoTurnIn") then
        for i = 1, GetNumActiveQuests() do
            local _, isComplete = GetActiveTitle(i)
            if isComplete == nil and GetActiveQuestID and C_QuestLog and C_QuestLog.ReadyForTurnIn then
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
ns.ModuleManager.Get():Register(AutoQuest:New("AutoQuest", {
    title = "Auto Quest",
    description = "Accepts quests and turns in completed ones at NPCs automatically.",
    defaultEnabled = true,
    color = ns.Theme.hex.gold,
    settings = {
        { type = "header", text = "Behaviour" },
        { type = "toggle", key = "autoAccept", label = "Auto-accept quests", default = true },
        { type = "toggle", key = "autoTurnIn", label = "Auto-turn-in quests", default = true },
        { type = "toggle", key = "shiftPause", label = "Hold Shift to pause", default = true,
          desc = "Hold Shift while talking to an NPC to handle it yourself." },
        { type = "toggle", key = "pauseInstance", label = "Pause inside instances", default = false,
          desc = "Skip automation while in dungeons and raids." },
        { type = "note", text = "Quests that let you choose between rewards are left open so you can pick." },
    },
}))
