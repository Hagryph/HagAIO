local addonName, ns = ...
local Class = ns.Class
local Theme = ns.Theme
local W = ns.UI.Widgets
local Ledger = ns.ResetLedger
local clock = ns.Format.Clock   -- "3h 04m" duration formatter (Lib/Format.lua)

-- Modules/ResetRadar.lua
-- Account-wide, cross-character RESET dashboard. Every character snapshots its own reset-timer
-- state (Great Vault, M+ keystone + rating, raid/dungeon lockouts, weekly/daily quest turn-ins,
-- item level) into a shared account-wide saved table keyed by "Name-Realm"; a themed window
-- with a LEFT CATEGORY TREE + a character header then shows ALL characters as rows, the selected
-- category's items as columns. No addon-to-addon comms (cross-character state travels purely via
-- SavedVariables), so the 12.0 encounter comms throttle never applies. Secret Great-Vault
-- progress (M+/raid) is read through ns.Secrets and stored only when non-secret.
--
-- Pure shaping (store key, reset-rollover, progress/keystone formatting) lives in the unit-tested
-- ns.ResetLedger (Lib/ResetLedger.lua). Data approach (verified by reading SavedInstances /
-- AlterEgo / Altoholic source): lockouts come dynamically from GetSavedInstanceInfo (every
-- instance the character is locked to, incl. legacy raids), and weekly/daily quests are RECORDED
-- as they're turned in (QUEST_TURNED_IN) and classified by frequency -- no curated ID tables.

local ResetRadar = Class.new("ResetRadar", ns.Module)

local RAIL_W = 178            -- left category-tree / character-header rail
local AVATAR = 46            -- character portrait size

-- ===========================================================================
-- Category descriptors. Each yields the COLUMNS for the selected dataset; a column's cell(entry)
-- is PURE (reads only a stored snapshot) so it renders the current character and every alt the
-- same way. `indent` draws it as a sub-item in the tree.
-- ===========================================================================
local function vaultDone(e)
    local v = e.vault
    if not (v and v.slots and #v.slots > 0) then return "-" end
    local done = 0
    for _, s in ipairs(v.slots) do
        local _, isDone = Ledger:Progress(s.progress, s.threshold)
        if isDone then done = done + 1 end
    end
    return done .. "/" .. #v.slots
end

-- A lockout column-set built from the union of every character's saved instances matching
-- `predicate(lockout)`; each cell shows that character's boss progress for the instance.
local function lockoutColumns(chars, predicate)
    local seen, cols = {}, {}
    for _, e in pairs(chars) do
        for _, lk in ipairs(e.lockouts or {}) do
            if predicate(lk) and not seen[lk.name] then
                seen[lk.name] = true
                local name = lk.name
                cols[#cols + 1] = { label = name, width = 96, cell = function(entry)
                    for _, l in ipairs(entry.lockouts or {}) do
                        if l.name == name then
                            return (l.progress or 0) .. "/" .. (l.total or "?")
                        end
                    end
                    return "-"
                end }
            end
        end
    end
    table.sort(cols, function(a, b) return a.label < b.label end)
    return cols
end

-- A quest column-set from the union of recorded weekly/daily turn-ins of the given `freq`.
local function questColumns(chars, freq)
    local seen, cols = {}, {}
    for _, e in pairs(chars) do
        local recorded = e.quests and e.quests[freq]
        if recorded then
            for id, title in pairs(recorded) do
                if not seen[id] then
                    seen[id] = true
                    local qid = id
                    cols[#cols + 1] = { label = title or ("Quest " .. id), width = 120, cell = function(entry)
                        local r = entry.quests and entry.quests[freq]
                        return (r and r[qid]) and "done" or "-"
                    end }
                end
            end
        end
    end
    table.sort(cols, function(a, b) return a.label < b.label end)
    return cols
end

local CATEGORIES = {
    { key = "mplus", label = "Mythic+", columns = function()
        return {
            { label = "Keystone", width = 150, cell = function(e)
                local k = e.keystone; return Ledger:KeystoneText(k and k.name, k and k.level) end },
            { label = "Rating", width = 64, cell = function(e) return e.rating and tostring(e.rating) or "-" end },
            { label = "Vault",  width = 64, cell = vaultDone },
        }
    end },
    { key = "lockouts", label = "Lockouts", header = true },
    { key = "raids",    label = "Raids",    indent = true,
      columns = function(chars) return lockoutColumns(chars, function(lk) return lk.isRaid end) end },
    { key = "dungeons", label = "Dungeons", indent = true,
      columns = function(chars) return lockoutColumns(chars, function(lk) return not lk.isRaid end) end },
    { key = "weekly", label = "Weekly Quests",
      columns = function(chars) return questColumns(chars, "weekly") end },
    { key = "daily",  label = "Daily Quests",
      columns = function(chars) return questColumns(chars, "daily") end },
}

-- ---- lifecycle ------------------------------------------------------------
function ResetRadar:OnInitialize()
    local p = self:_p()
    p.built = false
    p.shown = false
    p.category = "mplus"
end

function ResetRadar:OnEnable()
    -- Targeted collectors keep each fire cheap (the never-debounce rule): a bag update only
    -- re-reads the keystone, a quest turn-in only records that quest.
    self:On("PLAYER_ENTERING_WORLD",      function() self:_Snapshot() end)
    self:On("PLAYER_LOGOUT",              function() self:_Snapshot() end)
    self:On("WEEKLY_REWARDS_UPDATE",      function() self:_CollectVault();    self:_RenderIfShown() end)
    self:On("CHALLENGE_MODE_COMPLETED",   function() self:_CollectKeystone(); self:_RenderIfShown() end)
    self:On("CHALLENGE_MODE_MAPS_UPDATE", function() self:_CollectKeystone(); self:_RenderIfShown() end)
    self:On("BAG_UPDATE_DELAYED",         function() self:_CollectKeystone(); self:_RenderIfShown() end)
    self:On("UPDATE_INSTANCE_INFO",       function() self:_CollectLockouts(); self:_RenderIfShown() end)
    self:On("BOSS_KILL",                  function() self:_CollectLockouts() end)
    self:On("QUEST_TURNED_IN",            function(_, questID) self:_RecordQuest(questID) end)
    self:_Snapshot()
    if RequestRaidInfo then RequestRaidInfo() end   -- async -> UPDATE_INSTANCE_INFO fills lockouts
    if self:GetSetting("openOnLogin") then self:Show() end
end

function ResetRadar:OnDisable()
    self:Hide()
end

-- ---- account-wide store ---------------------------------------------------
function ResetRadar:_Chars()
    return ns.SavedVars:Namespace("resetradar", { chars = {} }).chars
end

function ResetRadar:_SelfKey()
    local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName()
    return Ledger:CharKey(UnitName("player"), realm)
end

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
        -- (ns.Secrets:Number returns nil for a secret), so a cross-char cell never computes on one.
        local prog = ns.Secrets and ns.Secrets:Number(a.progress) or a.progress
        local thr  = ns.Secrets and ns.Secrets:Number(a.threshold) or a.threshold
        slots[#slots + 1] = { type = a.type, level = a.level, progress = prog, threshold = thr }
    end
    e.vault = { slots = slots }
end

-- All saved instances the character is locked to (raids AND dungeons, current AND legacy) --
-- GetSavedInstanceInfo returns every active lock, so legacy raids you're saved to are captured
-- without any curated per-expansion list.
function ResetRadar:_CollectLockouts()
    local e = self:_SelfEntry()
    local n = (GetNumSavedInstances and GetNumSavedInstances()) or 0
    local locks = {}
    for i = 1, n do
        local name, _, reset, _, locked, _, _, isRaid, _, _, numEnc, prog = GetSavedInstanceInfo(i)
        if locked and reset and reset > 0 then
            locks[#locks + 1] = { name = name, total = numEnc, progress = prog, isRaid = isRaid, reset = reset }
        end
    end
    e.lockouts = locks
end

-- Record a turned-in quest under its reset frequency (daily/weekly), so the dashboard shows
-- which alt did which recurring quest this reset. Non-recurring quests are ignored.
function ResetRadar:_RecordQuest(questID)
    if not questID then return end
    local freq
    local info = C_QuestLog and C_QuestLog.GetQuestInfo  -- title fallback; frequency below
    local f = C_QuestLog and C_QuestLog.GetQuestFrequency and C_QuestLog.GetQuestFrequency(questID)
    if f == (Enum and Enum.QuestFrequency and Enum.QuestFrequency.Daily) then freq = "daily"
    elseif f == (Enum and Enum.QuestFrequency and Enum.QuestFrequency.Weekly) then freq = "weekly" end
    if not freq then return end
    local e = self:_SelfEntry()
    e.quests = e.quests or {}
    e.quests[freq] = e.quests[freq] or {}
    local title = (C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID))
        or (info and info(questID)) or ("Quest " .. questID)
    e.quests[freq][questID] = title
    self:_RenderIfShown()
end

function ResetRadar:_Snapshot()
    self:_CollectInfo()
    self:_CollectKeystone()
    self:_CollectVault()
    self:_CollectLockouts()
    self:_RenderIfShown()
end

-- ===========================================================================
-- Window: left rail (avatar + char header + a 1-column nav GRID) | content (reset header +
-- title + an N-column data GRID). BOTH panels are ns.UI.Widgets.Grid instances, so the sidebar
-- items, section headers and the data columns all align through ONE layout engine -- no
-- hand-computed offsets, so headers and cells can't drift apart.
-- ===========================================================================
local NAME_COL = 150   -- the sticky character-name column (shared by the data grid)

function ResetRadar:_Build()
    local p = self:_p()
    if p.built then return end

    local f = W.Window({ name = "HagAIOResetRadar", width = 860, height = 520,
        strata = "HIGH", title = "Reset Radar", onClose = function() self:Hide() end,
        autoClose = true,
        onAutoShow = function() self:Show() end,
        onAutoHide = function() self:Hide() end })
    f:SetScript("OnHide", function() self:_p().shown = false end)
    p.frame = f

    -- left rail: character card + category nav grid
    local rail = W.Panel(f.body, "bg0", "border")
    rail:SetWidth(RAIL_W)
    rail:SetPoint("TOPLEFT", 0, 0)
    rail:SetPoint("BOTTOMLEFT", 0, 0)

    -- character card: avatar (portrait on the bordered frame's ARTWORK layer, above its
    -- backdrop so the fill never hides it) + name / level-ilvl / rating.
    local avFrame = CreateFrame("Frame", nil, rail, "BackdropTemplate")
    avFrame:SetSize(AVATAR, AVATAR)
    avFrame:SetPoint("TOPLEFT", 14, -14)
    W.Style(avFrame, "panel2", "borderStrong")
    local av = avFrame:CreateTexture(nil, "ARTWORK")
    av:SetPoint("TOPLEFT", 2, -2)
    av:SetPoint("BOTTOMRIGHT", -2, 2)
    av:SetTexCoord(0.08, 0.92, 0.08, 0.92)   -- trim the portrait's baked-in ring
    p.avatar = av

    local hName = W.Text(rail, "", "text", "GameFontNormal")
    hName:SetPoint("TOPLEFT", avFrame, "TOPRIGHT", 10, -1)
    hName:SetWidth(RAIL_W - AVATAR - 30); hName:SetJustifyH("LEFT"); hName:SetWordWrap(false)
    local hInfo = W.Text(rail, "", "textDim", "GameFontHighlightSmall")
    hInfo:SetPoint("TOPLEFT", hName, "BOTTOMLEFT", 0, -5)
    local hRating = W.Text(rail, "", "accent", "GameFontHighlightSmall")
    hRating:SetPoint("TOPLEFT", hInfo, "BOTTOMLEFT", 0, -3)
    p.hName, p.hInfo, p.hRating = hName, hInfo, hRating

    local div = W.Divider(rail)
    div:SetPoint("TOPLEFT", avFrame, "BOTTOMLEFT", 0, -14)
    div:SetPoint("RIGHT", rail, "RIGHT", -12, 0)

    -- the category tree IS a 1-column grid (section + selectable nav rows)
    local nav = W.Grid(rail, { columns = { {} }, scroll = false, rowHeight = 30 })
    nav:SetPoint("TOPLEFT", div, "BOTTOMLEFT", 6, -10)
    nav:SetPoint("BOTTOMRIGHT", rail, "BOTTOMRIGHT", -6, 8)
    p.nav = nav

    -- content: reset header + category title + the data grid
    local content = W.Panel(f.body, "panel", "border")
    content:SetPoint("TOPLEFT", rail, "TOPRIGHT", 1, 0)
    content:SetPoint("BOTTOMRIGHT", f.body, "BOTTOMRIGHT", 0, 0)

    local resetHdr = W.Text(content, "", "textDim", "GameFontHighlightSmall")
    resetHdr:SetPoint("TOPLEFT", 16, -12); resetHdr:SetPoint("RIGHT", content, "RIGHT", -16, 0)
    resetHdr:SetJustifyH("LEFT")
    p.resetHdr = resetHdr

    local catTitle = W.Text(content, "", "text", "GameFontNormalLarge")
    catTitle:SetPoint("TOPLEFT", resetHdr, "BOTTOMLEFT", 0, -10)
    p.catTitle = catTitle

    local grid = W.Grid(content, { name = "HagAIOResetRadarGrid", header = true, striped = true })
    grid:SetPoint("TOPLEFT", catTitle, "BOTTOMLEFT", 0, -12)
    grid:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -10, 12)
    p.grid = grid

    p.built = true
    self:_Select(p.category)
end

-- The sidebar rows: a section header for a group, a selectable (indented) nav row otherwise.
function ResetRadar:_SidebarRows()
    local p = self:_p()
    local rows = {}
    for _, cat in ipairs(CATEGORIES) do
        if cat.header then
            rows[#rows + 1] = { section = cat.label }
        else
            local key = cat.key
            rows[#rows + 1] = {
                cells = { cat.label }, indent = cat.indent and 1 or 0,
                active = (key == p.category),
                onClick = function() self:_Select(key) end,
            }
        end
    end
    return rows
end

function ResetRadar:_Select(key)
    local p = self:_p()
    p.category = key
    p.nav:SetRows(self:_SidebarRows())   -- rebuild to reflect the active row
    self:_Render()
end

function ResetRadar:_Category()
    for _, c in ipairs(CATEGORIES) do if c.key == self:_p().category then return c end end
    return CATEGORIES[1]
end

-- Sorted character keys: the current character first, then alphabetical.
function ResetRadar:_SortedChars()
    local chars = self:_Chars()
    local selfKey = self:_SelfKey()
    local keys = {}
    for k in pairs(chars) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        if (a == selfKey) ~= (b == selfKey) then return a == selfKey end
        return a < b
    end)
    return keys, chars
end

function ResetRadar:_Render()
    local p = self:_p()
    if not p.built then return end
    self:_UpdateHeader()
    self:_UpdateCountdown()

    local cat = self:_Category()
    p.catTitle:SetText(cat.label)
    local keys, chars = self:_SortedChars()
    local cols = (cat.columns and cat.columns(chars)) or {}

    -- one sticky Character column + one column per category item; the grid aligns header+cells
    local columns = { { width = NAME_COL, label = "Character" } }
    for _, c in ipairs(cols) do columns[#columns + 1] = { width = c.width, label = c.label } end
    p.grid:SetColumns(columns)

    -- one row per character: cell 1 = class-coloured name, then a value per item column
    local rows = {}
    for _, key in ipairs(keys) do
        local e = chars[key]
        local cells = { e.name or key }
        for _, c in ipairs(cols) do cells[#cells + 1] = c.cell(e) or "-" end
        local cc = e.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[e.class]
        local nameColor = cc and { cc.r, cc.g, cc.b } or "text"
        rows[#rows + 1] = { cells = cells, cellColor = function(ci)
            if ci == 1 then return nameColor end
            return cells[ci] == "-" and "textFaint" or "text"
        end }
    end
    p.grid:SetRows(rows)
end

function ResetRadar:_UpdateHeader()
    local p = self:_p()
    local chars = self:_Chars()
    local e = chars[self:_SelfKey()]
    if not e then return end
    p.hName:SetText(e.name or "?")
    local cc = e.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[e.class]
    if cc then p.hName:SetTextColor(cc.r, cc.g, cc.b) end
    p.hInfo:SetText(("Level %s   iLvl %s"):format(tostring(e.level or "-"), tostring(e.ilvl or "-")))
    p.hRating:SetText(e.rating and ("Mythic+ " .. e.rating) or "")
    if SetPortraitTexture and p.avatar then
        SetPortraitTexture(p.avatar, "player")   -- the viewing character's portrait
    end
end

function ResetRadar:_RenderIfShown()
    if self:_p().shown then self:_Render() end
end

function ResetRadar:_UpdateCountdown()
    local p = self:_p()
    if not p.resetHdr then return end
    local weekly = C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset and C_DateAndTime.GetSecondsUntilWeeklyReset()
    local daily  = C_DateAndTime and C_DateAndTime.GetSecondsUntilDailyReset  and C_DateAndTime.GetSecondsUntilDailyReset()
    p.resetHdr:SetText(("Weekly reset in |cff%s%s|r      Daily reset in |cff%s%s|r")
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
    description = "A cross-character view of weekly/daily resets: Great Vault, M+ keystone, lockouts and recurring quests.",
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
