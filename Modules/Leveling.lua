local addonName, ns = ...
local Class = ns.Class
local Theme = ns.Theme

-- Modules/Leveling.lua
-- First feature module. Tracks XP gained during the current play session and
-- shows a rich tooltip when hovering the default XP bar:
--   * current / max XP (and %), remaining, rested
--   * session XP, XP per hour, time played, projected time-to-level
--
-- The tooltip is attached by overlaying a mouse-motion-only frame on the XP
-- bar (EnableMouseMotion, 11.0+) so hover works WITHOUT swallowing the bar's
-- right-click menu. /hag xp prints the same session stats to chat.

local Leveling = Class.new("Leveling", ns.Module)

-- ---- helpers --------------------------------------------------------------
local function commafy(n)
    return BreakUpLargeNumbers(math.floor(n + 0.5))
end

local function clock(seconds)
    if not seconds or seconds <= 0 then return "—" end
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

-- Find the retail XP bar container to anchor onto (with fallbacks).
local function findXPBar()
    return MainStatusTrackingBarContainer
        or _G.StatusTrackingBarManager
        or _G.MainMenuExpBar
end

-- ---- lifecycle ------------------------------------------------------------
function Leveling:OnInitialize()
    local p = self:_p()
    p.startTime = nil
    p.sessionXP = 0
    p.lastXP, p.lastLevel, p.lastMax = 0, 0, 0
    p.tokens = {}
    p.overlay = nil
    p.hovering = false
end

function Leveling:OnEnable()
    local p = self:_p()
    self:_Snapshot()
    p.startTime = GetTime()
    p.sessionXP = 0

    -- tokens keyed by event name so OnDisable can unsubscribe cleanly
    local bus = ns.EventBus.Get()
    p.tokens["PLAYER_XP_UPDATE"]      = bus:On("PLAYER_XP_UPDATE",      function() self:_OnXP() end)
    p.tokens["PLAYER_LEVEL_UP"]       = bus:On("PLAYER_LEVEL_UP",       function() self:_Snapshot() end)
    p.tokens["PLAYER_ENTERING_WORLD"] = bus:On("PLAYER_ENTERING_WORLD", function() self:_Snapshot() end)

    self:_EnsureOverlay()
    if p.overlay then p.overlay:Show() end

    ns.SlashCommand.Get():Register("xp", function() self:_PrintSession() end,
        "session XP / hour")
end

function Leveling:OnDisable()
    local p = self:_p()
    local bus = ns.EventBus.Get()
    for event, token in pairs(p.tokens) do bus:Off(event, token) end
    wipe(p.tokens)
    if p.overlay then
        p.overlay:Hide()
        if GameTooltip:IsOwned(p.overlay) then GameTooltip:Hide() end
    end
end

-- ---- xp tracking ----------------------------------------------------------
function Leveling:_Snapshot()
    local p = self:_p()
    p.lastLevel = UnitLevel("player")
    p.lastXP = UnitXP("player")
    p.lastMax = UnitXPMax("player")
end

function Leveling:_OnXP()
    local p = self:_p()
    local lvl = UnitLevel("player")
    local xp  = UnitXP("player")
    local max = UnitXPMax("player")

    if lvl == p.lastLevel then
        local delta = xp - p.lastXP
        if delta > 0 then p.sessionXP = p.sessionXP + delta end
    else
        -- leveled up: remainder of the previous level + progress into the new
        -- one (intervening full levels in a single update are vanishingly rare)
        p.sessionXP = p.sessionXP + math.max(0, p.lastMax - p.lastXP) + xp
    end

    p.lastLevel, p.lastXP, p.lastMax = lvl, xp, max
    if p.hovering then self:_ShowTooltip() end
end

-- Returns: cur, max, pct, remaining, rested, sessionXP, perHour, elapsed, ttl
function Leveling:_Stats()
    local p = self:_p()
    local cur, max = UnitXP("player"), UnitXPMax("player")
    local pct = (max > 0) and (cur / max * 100) or 0
    local remaining = math.max(0, max - cur)
    local rested = GetXPExhaustion()  -- nil if not rested
    local elapsed = p.startTime and (GetTime() - p.startTime) or 0
    local perHour = (elapsed > 1) and (p.sessionXP / (elapsed / 3600)) or 0
    local ttl = (perHour > 0) and (remaining / perHour * 3600) or nil
    return cur, max, pct, remaining, rested, p.sessionXP, perHour, elapsed, ttl
end

-- ---- tooltip / overlay ----------------------------------------------------
local function statLine(tt, label, value, valueKey)
    local lr, lg, lb = Theme.Unpack("textDim")
    local vr, vg, vb = Theme.Unpack(valueKey or "text")
    tt:AddDoubleLine(label, value, lr, lg, lb, vr, vg, vb)
end

function Leveling:_ShowTooltip()
    local p = self:_p()
    if not p.overlay then return end
    local tt = GameTooltip
    tt:SetOwner(p.overlay, "ANCHOR_TOP")
    tt:ClearLines()
    tt:AddLine("|cff" .. Theme.hex.accent .. "HagAIO|r  |cff" .. Theme.hex.gold .. "Leveling|r")

    if UnitLevel("player") >= maxLevel() or UnitXPMax("player") == 0 then
        tt:AddLine("Max level — no experience to track.", Theme.Unpack("textDim"))
        tt:Show()
        return
    end
    if IsXPUserDisabled and IsXPUserDisabled() then
        tt:AddLine("XP gain is disabled.", Theme.Unpack("warn"))
    end

    local cur, max, pct, remaining, rested, sessionXP, perHour, elapsed, ttl = self:_Stats()

    statLine(tt, "Level", UnitLevel("player"), "accent")
    statLine(tt, "XP", ("%s / %s  (%.1f%%)"):format(commafy(cur), commafy(max), pct))
    statLine(tt, "Remaining", commafy(remaining))
    if rested and rested > 0 then
        statLine(tt, "Rested", ("%s  (%.0f%%)"):format(commafy(rested), rested / max * 100), "gold")
    end

    tt:AddLine(" ")
    statLine(tt, "Session XP", commafy(sessionXP))
    statLine(tt, "XP / hour", perHour > 0 and commafy(perHour) or "—", "win")
    statLine(tt, "Time played", clock(elapsed))
    statLine(tt, "Time to level", clock(ttl), "accent")

    tt:Show()
end

function Leveling:_EnsureOverlay()
    local p = self:_p()
    if p.overlay then return end
    local bar = findXPBar()
    if not bar then
        self:LogWarn("XP bar not found; hover tooltip unavailable (max level?)")
        return
    end

    local overlay = CreateFrame("Frame", "HagAIOLevelingOverlay", bar)
    overlay:SetAllPoints(bar)
    overlay:SetFrameLevel(bar:GetFrameLevel() + 10)
    -- motion-only: hover works, clicks (bar right-click menu) pass through
    if overlay.EnableMouseMotion then
        overlay:EnableMouseMotion(true)
    else
        overlay:EnableMouse(true)
    end

    overlay:SetScript("OnEnter", function()
        p.hovering = true
        self:_ShowTooltip()
    end)
    overlay:SetScript("OnLeave", function()
        p.hovering = false
        if GameTooltip:IsOwned(overlay) then GameTooltip:Hide() end
    end)
    -- live-refresh XP/hour + time-to-level while hovering (throttled)
    overlay:SetScript("OnUpdate", function(_, dt)
        if not p.hovering then return end
        p.acc = (p.acc or 0) + dt
        if p.acc >= 0.5 then p.acc = 0; self:_ShowTooltip() end
    end)

    p.overlay = overlay
end

function Leveling:_PrintSession()
    local cur, max, pct, remaining, rested, sessionXP, perHour, elapsed, ttl = self:_Stats()
    if UnitLevel("player") >= maxLevel() or max == 0 then
        self:LogInfo("max level — no XP to track")
        return
    end
    self:LogInfo(("L%d  %s/%s (%.1f%%)  |  session %s  |  %s/hr  |  to level %s")
        :format(UnitLevel("player"), commafy(cur), commafy(max), pct,
            commafy(sessionXP), perHour > 0 and commafy(perHour) or "—", clock(ttl)))
end

-- Register with the manager so it appears in the settings window's Modules page.
ns.ModuleManager.Get():Register(Leveling:New("Leveling", {
    title = "Leveling (XP / hour)",
    defaultEnabled = true,
    color = ns.Theme.hex.gold,
}))
