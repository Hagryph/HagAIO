local addonName, ns = ...
local Class = ns.Class
local Theme = ns.Theme
local W = ns.UI.Widgets
local Ledger = ns.ResetLedger
local clock = ns.Format.Clock   -- "3h 04m" duration formatter (Lib/Format.lua)

-- Modules/ResetRadar.lua
-- Account-wide, cross-character RESET dashboard. Every character snapshots its own reset-
-- timer state (Great Vault, M+ keystone + rating, raid/dungeon lockouts, item level) into a
-- shared account-wide saved table keyed by "Name-Realm"; a wide themed window then shows ALL
-- characters as rows with a category per column and a live "time until reset" header. No
-- addon-to-addon comms (cross-character state travels purely via SavedVariables), so the
-- 12.0 encounter comms throttle never applies. Secret Great-Vault progress (M+/raid) is read
-- through ns.Secrets and stored only when non-secret -- we never compute on a secret.
--
-- The pure shaping (the store key, reset-rollover detection, progress/keystone formatting)
-- lives in the unit-tested ns.ResetLedger (Lib/ResetLedger.lua); this module is the WoW-API
-- collectors + the window.

local ResetRadar = Class.new("ResetRadar", ns.Module)

local NAME_W = 124   -- the sticky first (character) column width

-- One column = one reset category. get(entry) is PURE (reads only the stored snapshot, no
-- live API), so the same descriptor renders the current character and every offline alt.
local COLUMNS = {
    { key = "level", label = "Lvl",      width = 40,  get = function(e) return e.level and tostring(e.level) or "-" end },
    { key = "ilvl",  label = "iLvl",     width = 48,  get = function(e) return e.ilvl  and tostring(e.ilvl)  or "-" end },
    { key = "score", label = "M+",       width = 52,  get = function(e) return e.rating and tostring(e.rating) or "-" end },
    { key = "key",   label = "Keystone", width = 132, get = function(e)
        local k = e.keystone; return Ledger:KeystoneText(k and k.name, k and k.level) end },
    { key = "vault", label = "Vault",    width = 64,  get = function(e)
        local v = e.vault
        if not (v and v.slots and #v.slots > 0) then return "-" end
        local done = 0
        for _, s in ipairs(v.slots) do
            local _, isDone = Ledger:Progress(s.progress, s.threshold)
            if isDone then done = done + 1 end
        end
        return done .. "/" .. #v.slots
    end },
    { key = "locks", label = "Lockouts", width = 70,  get = function(e)
        local n = e.lockouts and #e.lockouts or 0
        return n > 0 and tostring(n) or "-"
    end },
}

-- ---- lifecycle ------------------------------------------------------------
function ResetRadar:OnInitialize()
    local p = self:_p()
    p.built = false
    p.rows = {}
    p.shown = false
end

function ResetRadar:OnEnable()
    -- Snapshot now, and on every event that changes a tracked value. Targeted collectors keep
    -- each fire cheap (per the never-debounce rule) -- a bag update only re-reads the keystone,
    -- not the whole snapshot.
    self:On("PLAYER_ENTERING_WORLD",    function() self:_Snapshot() end)
    self:On("PLAYER_LOGOUT",            function() self:_Snapshot() end)
    self:On("WEEKLY_REWARDS_UPDATE",    function() self:_CollectVault();    self:_RenderIfShown() end)
    self:On("CHALLENGE_MODE_COMPLETED", function() self:_CollectKeystone(); self:_RenderIfShown() end)
    self:On("CHALLENGE_MODE_MAPS_UPDATE", function() self:_CollectKeystone(); self:_RenderIfShown() end)
    self:On("BAG_UPDATE_DELAYED",       function() self:_CollectKeystone(); self:_RenderIfShown() end)
    self:On("UPDATE_INSTANCE_INFO",     function() self:_CollectLockouts(); self:_RenderIfShown() end)
    self:On("BOSS_KILL",                function() self:_CollectLockouts() end)
    self:_Snapshot()
    if RequestRaidInfo then RequestRaidInfo() end   -- async -> UPDATE_INSTANCE_INFO fills lockouts
    if self:GetSetting("openOnLogin") then self:Show() end
end

function ResetRadar:OnDisable()
    self:Hide()
end

-- ---- account-wide store ---------------------------------------------------
-- The shared (NOT per-character) table: every character writes its own snapshot here keyed by
-- "Name-Realm", so any character sees all the others.
function ResetRadar:_Chars()
    return ns.SavedVars:Namespace("resetradar", { chars = {} }).chars
end

function ResetRadar:_SelfKey()
    local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName()
    return Ledger:CharKey(UnitName("player"), realm)
end

-- This character's entry (created on first use); stamps lastSeen so reset-rollover works.
function ResetRadar:_SelfEntry()
    local chars = self:_Chars()
    local key = self:_SelfKey()
    local e = chars[key]
    if not e then e = {}; chars[key] = e end
    e.lastSeen = (GetServerTime and GetServerTime()) or time()
    return e
end

-- ---- collectors (each guarded so a missing API is a no-op, never an error) -
function ResetRadar:_CollectInfo()
    local e = self:_SelfEntry()
    e.name  = UnitName("player")
    e.realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName()
    local _, classFile = UnitClass("player")
    e.class = classFile
    e.level = UnitLevel("player")
    if GetAverageItemLevel then
        local _, equipped = GetAverageItemLevel()
        e.ilvl = equipped and math.floor(equipped + 0.5) or e.ilvl
    end
end

function ResetRadar:_CollectKeystone()
    local e = self:_SelfEntry()
    local mapID = C_MythicPlus and C_MythicPlus.GetOwnedKeystoneMapID and C_MythicPlus.GetOwnedKeystoneMapID()
    local level = C_MythicPlus and C_MythicPlus.GetOwnedKeystoneLevel and C_MythicPlus.GetOwnedKeystoneLevel()
    if mapID and level and level > 0 then
        local name = C_ChallengeMode and C_ChallengeMode.GetMapUIInfo and C_ChallengeMode.GetMapUIInfo(mapID)
        e.keystone = { mapID = mapID, level = level, name = name }
    else
        e.keystone = nil
    end
    local summary = C_PlayerInfo and C_PlayerInfo.GetPlayerMythicPlusRatingSummary
        and C_PlayerInfo.GetPlayerMythicPlusRatingSummary("player")
    if summary and summary.currentSeasonScore then e.rating = summary.currentSeasonScore end
end

function ResetRadar:_CollectVault()
    local e = self:_SelfEntry()
    local acts = C_WeeklyRewards and C_WeeklyRewards.GetActivities and C_WeeklyRewards.GetActivities()
    if not acts then return end
    local slots = {}
    for _, a in ipairs(acts) do
        -- progress/threshold can be secret in restricted content -- store only a plain number
        -- (ns.Secrets:Number returns nil for a secret), so the cross-char cell never computes
        -- on a secret. A nil here just reads as not-done until snapshotted out of restriction.
        local prog = ns.Secrets and ns.Secrets:Number(a.progress) or a.progress
        local thr  = ns.Secrets and ns.Secrets:Number(a.threshold) or a.threshold
        slots[#slots + 1] = { type = a.type, level = a.level, progress = prog, threshold = thr }
    end
    e.vault = { slots = slots,
        hasRewards = (C_WeeklyRewards.HasAvailableRewards and C_WeeklyRewards.HasAvailableRewards()) or false }
end

function ResetRadar:_CollectLockouts()
    local e = self:_SelfEntry()
    local n = (GetNumSavedInstances and GetNumSavedInstances()) or 0
    local locks = {}
    for i = 1, n do
        local name, _, reset, _, locked, _, _, isRaid, _, _, numEnc, prog = GetSavedInstanceInfo(i)
        if locked and reset and reset > 0 then
            locks[#locks + 1] = { name = name, total = numEnc, progress = prog, isRaid = isRaid }
        end
    end
    e.lockouts = locks
end

function ResetRadar:_Snapshot()
    self:_CollectInfo()
    self:_CollectKeystone()
    self:_CollectVault()
    self:_CollectLockouts()
    self:_RenderIfShown()
end

-- ---- window ---------------------------------------------------------------
function ResetRadar:_Build()
    local p = self:_p()
    if p.built then return end

    -- total width = sticky name column + every category column + side padding
    local gridW = NAME_W
    for _, c in ipairs(COLUMNS) do gridW = gridW + c.width end

    local f = W.Window({ name = "HagAIOResetRadar", width = gridW + 36, height = 420,
        strata = "HIGH", title = "Reset Radar", onClose = function() self:Hide() end })
    f:SetScript("OnHide", function() self:_p().shown = false end)
    p.frame = f

    -- live reset countdown header
    local header = W.Text(f.body, "", "textDim", "GameFontHighlightSmall")
    header:SetPoint("TOPLEFT", 16, -12)
    p.header = header

    -- column-label row (the sticky header for the grid)
    local labels = CreateFrame("Frame", nil, f.body)
    labels:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -10)
    labels:SetPoint("RIGHT", f.body, "RIGHT", -16, 0)
    labels:SetHeight(18)
    local nameHdr = W.SectionLabel(labels, "Character")
    nameHdr:SetPoint("LEFT", 0, 0)
    local x = NAME_W
    for _, c in ipairs(COLUMNS) do
        local h = W.SectionLabel(labels, c.label)
        h:SetPoint("LEFT", x, 0)
        x = x + c.width
    end

    local div = W.Divider(f.body)
    div:SetPoint("TOPLEFT", labels, "BOTTOMLEFT", 0, -4)
    div:SetPoint("RIGHT", f.body, "RIGHT", -16, 0)

    local sf = W.ScrollFrame(f.body, "HagAIOResetRadarScroll")
    sf:SetPoint("TOPLEFT", div, "BOTTOMLEFT", 0, -8)
    sf:SetPoint("BOTTOMRIGHT", f.body, "BOTTOMRIGHT", -28, 12)
    p.scroll = sf

    p.built = true
end

-- A sorted character list: the current character first, then the rest alphabetically.
function ResetRadar:_SortedChars()
    local chars = self:_Chars()
    local selfKey = self:_SelfKey()
    local keys = {}
    for k in pairs(chars) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        if a == selfKey ~= (b == selfKey) then return a == selfKey end
        return a < b
    end)
    return keys, chars, selfKey
end

-- One reusable character row: a class-coloured name + a cell per column.
function ResetRadar:_Row(index)
    local p = self:_p()
    local row = p.rows[index]
    if row then return row end
    row = CreateFrame("Frame", nil, p.scroll.content)
    row:SetHeight(22)
    row.name = W.Text(row, "", "text", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", 2, 0)
    row.name:SetWidth(NAME_W - 4)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.cells = {}
    local x = NAME_W
    for i, c in ipairs(COLUMNS) do
        local fs = W.Text(row, "", "textDim", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", x, 0)
        fs:SetWidth(c.width)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        row.cells[i] = fs
        x = x + c.width
    end
    p.rows[index] = row
    return row
end

function ResetRadar:_Render()
    local p = self:_p()
    if not p.built then return end
    local keys, chars = self:_SortedChars()
    local width = p.scroll:GetWidth(); if not width or width < 1 then width = 480 end
    p.scroll.content:SetWidth(width)

    local y = 0
    for i, key in ipairs(keys) do
        local e = chars[key]
        local row = self:_Row(i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, y)
        row:SetPoint("RIGHT", p.scroll.content, "RIGHT", 0, 0)

        row.name:SetText(e.name or key)
        local cc = e.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[e.class]
        if cc then row.name:SetTextColor(cc.r, cc.g, cc.b) else row.name:SetTextColor(Theme.Unpack("text")) end

        for ci, c in ipairs(COLUMNS) do
            row.cells[ci]:SetText(c.get(e) or "-")
        end
        row:Show()
        y = y - 24
    end
    for i = #keys + 1, #p.rows do p.rows[i]:Hide() end
    p.scroll.content:SetHeight(math.max(1, -y))
    self:_UpdateCountdown()
end

function ResetRadar:_RenderIfShown()
    if self:_p().shown then self:_Render() end
end

function ResetRadar:_UpdateCountdown()
    local p = self:_p()
    if not p.header then return end
    local weekly = C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset and C_DateAndTime.GetSecondsUntilWeeklyReset()
    local daily  = C_DateAndTime and C_DateAndTime.GetSecondsUntilDailyReset  and C_DateAndTime.GetSecondsUntilDailyReset()
    p.header:SetText(("Weekly reset in |cff%s%s|r      Daily reset in |cff%s%s|r")
        :format(Theme.hex.accent, clock(weekly), Theme.hex.accent, clock(daily)))
end

-- ---- show / hide ----------------------------------------------------------
function ResetRadar:Show()
    self:_Build()
    local p = self:_p()
    p.shown = true
    p.frame:Show()
    self:_Render()
    if p.ticker then p.ticker:Cancel() end
    p.ticker = C_Timer.NewTicker(1, function() if p.shown then self:_UpdateCountdown() end end)
    C_Timer.After(0, function() self:_Render() end)   -- re-measure once on screen
end

function ResetRadar:Hide()
    local p = self:_p()
    p.shown = false
    if p.ticker then p.ticker:Cancel(); p.ticker = nil end
    if p.frame then p.frame:Hide() end
end

function ResetRadar:Toggle()
    if self:_p().shown then self:Hide() else self:Show() end
end

-- ---- registration ---------------------------------------------------------
ns.ModuleManager:Register(ResetRadar:New("ResetRadar", {
    title = "Reset Radar",
    description = "A cross-character view of weekly/daily resets: Great Vault, M+ keystone, and lockouts.",
    defaultEnabled = false,
    color = ns.Theme.hex.accent,
    deps = { "SavedVars", "SlashCommand", "Secrets" },
    commands = {
        resets = { handler = "Toggle", help = "open the cross-character reset dashboard" },
    },
    settings = {
        { type = "header", text = "Reset Radar" },
        { type = "toggle", key = "openOnLogin", label = "Open automatically on login", default = false },
        { type = "note", text = "Each character you log into adds itself to the dashboard. Open it any time with /hag resets." },
    },
}))
