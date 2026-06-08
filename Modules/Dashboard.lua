local addonName, ns = ...
local Class = ns.Class
local Theme = ns.Theme
local W = ns.UI.Widgets
local Ledger = ns.ResetLedger
local clock = ns.Format.Clock   -- "3h 04m" duration formatter (Lib/Format.lua)

-- Modules/Dashboard.lua
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

local Dashboard = Class.new("Dashboard", ns.Module)

local RAIL_W = 178            -- left category-tree / character-header rail
local AVATAR = 46            -- character portrait size

-- Raid difficulty -> short tag + rank (highest rank wins when a char is locked at several). enUS
-- names; an unknown locale falls back to the first letter, so it degrades, never breaks.
local DIFF = {
    ["Looking For Raid"] = { abbr = "LFR", rank = 1 }, ["Raid Finder"] = { abbr = "LFR", rank = 1 },
    Normal = { abbr = "N", rank = 2 }, Heroic = { abbr = "H", rank = 3 }, Mythic = { abbr = "M", rank = 4 },
}

-- Localized name of Mythic 0 (difficulty 23) -- matches a saved M0 dungeon lock's difficulty.
local M0 = (GetDifficultyInfo and GetDifficultyInfo(23)) or "Mythic"

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

-- The Home nav entry is icon-only (no text): a hearthstone (the game's "home" symbol) rendered
-- inline. Selecting it shows the overview -- an icon grid of every category.
local HOME_ICON = "|TInterface\\Icons\\INV_Misc_Rune_01:20:20|t"

-- The Encounter Journal crops its instance buttonImage1 art to this region (the rest is padding);
-- see Blizzard_EncounterJournal.xml "EncounterInstanceButtonTemplate" bgImage TexCoords. We reuse
-- it so our instance tiles fill the same way the journal's do (only used for the low-def banner
-- fallback, when an instance has no full-bleed scene).
local EJ_TILE_TC = { 0, 0.68359375, 0, 0.7421875 }
-- The banner crop lands on the art region but still carries a little padding, so we zoom in a touch
-- (zoom = fraction of the region shown; 0.8 = 20% in) to eat it. See TextureService for the model.
local EJ_TILE_ZOOM = 0.8
-- The scene (bgImage) is a 1024x512 file (px aspect 2) padded only on the RIGHT (~32%); it fills the
-- full height. The cover-fit auto-crops the WHOLE image to the tile by aspect, then we zoom in and
-- pan left to push the right-side padding out of view. Zoom = fraction of the fitted region shown
-- (1.0 = as-is, <1 = zoom in, >1 = zoom out); pan is in texcoord units (- x = shift the window left).
local EJ_BG_ASPECT = 2
local EJ_BG_ZOOM   = 0.74
local EJ_BG_PAN_X  = -0.16
local EJ_BG_PAN_Y  = 0

-- Copy an art descriptor ({texture, cover, texCoord, zoom, aspect, panX, panY} from _InstanceArt)
-- onto a tile.
local function applyArt(tile, art)
    tile.texture, tile.cover, tile.texCoord, tile.zoom =
        art.texture, art.cover, art.texCoord, art.zoom
    tile.aspect, tile.panX, tile.panY = art.aspect, art.panX, art.panY
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
    { key = "raids",    label = "Raids",    indent = true },   -- lockout columns resolved per-key below
    { key = "dungeons", label = "Dungeons", indent = true },
    { key = "weekly", label = "Weekly Quests",
      columns = function(chars) return questColumns(chars, "weekly") end },
    { key = "daily",  label = "Daily Quests",
      columns = function(chars) return questColumns(chars, "daily") end },
}

-- ---- lifecycle ------------------------------------------------------------
function Dashboard:OnInitialize()
    local p = self:_p()
    p.built = false
    p.shown = false
    p.category = "home"   -- open on the overview (an icon grid of every category)
end

function Dashboard:OnEnable()
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
end

-- A settings change (a category toggled on/off) re-renders so the nav tree reflects it.
function Dashboard:OnSettingChanged()
    self:_RenderIfShown()
end

function Dashboard:OnDisable()
    self:Hide()
end

-- ---- account-wide store ---------------------------------------------------
-- `chars` = per-character snapshots; `instances` = a SELF-CURATING registry of every instance
-- ever locked (key "name|difficulty" -> { name, diff, isRaid, total, expansion }), so the
-- dashboard remembers and keeps showing a dungeon/raid even after its lockout expires.
function Dashboard:_Store()
    return ns.SavedVars:Namespace("dashboard", { chars = {}, instances = {} })
end
function Dashboard:_Chars()     return self:_Store().chars end
function Dashboard:_Instances() return self:_Store().instances end

function Dashboard:_SelfKey()
    local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName()
    return Ledger:CharKey(UnitName("player"), realm)
end

function Dashboard:_SelfEntry()
    local chars = self:_Chars()
    local key = self:_SelfKey()
    local e = chars[key]
    if not e then e = {}; chars[key] = e end
    e.lastSeen = (GetServerTime and GetServerTime()) or time()
    return e
end

-- ---- collectors (each guarded so a missing API is a no-op, never an error) -
function Dashboard:_CollectInfo()
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

function Dashboard:_CollectKeystone()
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

function Dashboard:_CollectVault()
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

-- All saved instances the character is locked to (raids AND dungeons, every difficulty, current
-- AND legacy). GetSavedInstanceInfo returns ONLY active locks, so "which difficulty has a lockout"
-- needs no curated table -- if it's locked it's here (with its difficulty + boss count), if not it
-- isn't. We capture the difficulty name so a multi-difficulty lock (e.g. LFR + Heroic of one raid)
-- shows as separate entries.
function Dashboard:_CollectLockouts()
    local e = self:_SelfEntry()
    local n = (GetNumSavedInstances and GetNumSavedInstances()) or 0
    local locks, inst = {}, self:_Instances()
    for i = 1, n do
        local name, _, reset, _, locked, _, _, isRaid, _, diff, numEnc, prog = GetSavedInstanceInfo(i)
        if locked and reset and reset > 0 then
            locks[#locks + 1] = { name = name, diff = diff, total = numEnc, progress = prog,
                isRaid = isRaid, reset = reset }
            -- remember this instance forever in the self-curating registry
            local key = name .. "|" .. (diff or "")
            local r = inst[key]
            if not r then r = { name = name, diff = diff, isRaid = isRaid and true or false }; inst[key] = r end
            r.total = numEnc or r.total
            local exp = self:_InstanceExpansion(name)
            if exp ~= "Other" then r.expansion = exp end   -- fill the tier once the journal map is ready
        end
    end
    e.lockouts = locks
end

-- Record a turned-in quest under its reset frequency (daily/weekly), so the dashboard shows
-- which alt did which recurring quest this reset. Non-recurring quests are ignored.
function Dashboard:_RecordQuest(questID)
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

function Dashboard:_Snapshot()
    self:_CollectInfo()
    self:_CollectKeystone()
    self:_CollectVault()
    self:_CollectLockouts()
    self:_PruneRegistry()   -- drop M0 entries that have rotated out of the current season
    self:_RenderIfShown()
end

-- ---- expansion mapping (Encounter Journal) --------------------------------
-- Map a raid NAME -> its expansion by walking the Encounter Journal tiers (one tier per
-- expansion). Built lazily and cached on first success; name-matching is locale-consistent
-- within a client. A raid the journal doesn't list (or before the journal data loads) resolves
-- to "Other". The reference addons hand-curate this; we derive it dynamically instead.
function Dashboard:_ExpansionMap()
    local p = self:_p()
    if p.ejMap then return p.ejMap end
    if not (EJ_GetNumTiers and EJ_SelectTier and EJ_GetInstanceByIndex and EJ_GetTierInfo) then return nil end
    if C_AddOns and C_AddOns.LoadAddOn then pcall(C_AddOns.LoadAddOn, "Blizzard_EncounterJournal") end
    local map, raidsByTier, dungeonsByTier, tierOrder, found = {}, {}, {}, {}, false
    local tierLevel = {}   -- tier name -> expansionLevel (EJ tier index 1 = Classic = expansion 0)
    local image = {}       -- instance name -> EJ buttonImage1 (compact tile art)
    local bg = {}          -- instance name -> EJ bgImage (full-bleed scene; fills a wide tile)
    local prev = EJ_GetCurrentTier and EJ_GetCurrentTier()
    local function walk(tier, tierName, isRaid, sink)
        EJ_SelectTier(tier)
        local i = 1
        while true do
            local instID, name, _, bgImage, buttonImage = EJ_GetInstanceByIndex(i, isRaid)
            if not instID then break end
            if name == "Keystone Dungeons" then name = nil end   -- meta-entry, never a real instance
            if name and tierName then
                map[name] = tierName; found = true
                if buttonImage then image[name] = buttonImage end
                if bgImage then bg[name] = bgImage end
                if sink then sink[#sink + 1] = name end
            end
            i = i + 1
        end
    end
    for tier = EJ_GetNumTiers(), 1, -1 do   -- newest tier first
        local tierName = EJ_GetTierInfo(tier)
        if tierName then
            tierLevel[tierName] = tier - 1   -- EJ tier 1 == Classic == expansion level 0
            local raids, dungeons = {}, {}
            walk(tier, tierName, true, raids)
            walk(tier, tierName, false, dungeons)
            if #raids > 0 then
                raidsByTier[tierName] = raids
                tierOrder[#tierOrder + 1] = tierName
            end
            if #dungeons > 0 then dungeonsByTier[tierName] = dungeons end
        end
    end
    if prev then pcall(EJ_SelectTier, prev) end   -- restore the journal's selected tier
    if found then
        p.ejMap = map
        p.ejRaidsByTier = raidsByTier         -- tier -> { all raid names } (every raid has a weekly lock)
        p.ejDungeonsByTier = dungeonsByTier   -- tier -> { all dungeon names }
        p.ejTierOrder = tierOrder             -- tiers with raids, newest first
        p.ejTierLevel = tierLevel             -- tier name -> expansionLevel (for native logos)
        p.ejImage = image                     -- instance name -> EJ tile art (buttonImage1)
        p.ejBg = bg                           -- instance name -> EJ full-bleed scene (bgImage)
        p.currentExpansion = tierOrder[1] or EJ_GetTierInfo(EJ_GetNumTiers())   -- newest raid tier = current
    end
    return p.ejMap
end

-- The expansion an instance (raid OR dungeon) belongs to (cache read only; "Other" until built).
function Dashboard:_InstanceExpansion(name)
    local m = self:_p().ejMap
    return (m and m[name]) or "Other"
end

-- The native expansion logo texture for a tier (the icon WoW ships per expansion), or nil. Used
-- for the overview's icon tiles. GetExpansionDisplayInfo(expansionLevel) -> { logo, banner }.
function Dashboard:_ExpansionLogo(tierName)
    local lvl = self:_p().ejTierLevel and self:_p().ejTierLevel[tierName]
    if not (lvl and GetExpansionDisplayInfo) then return nil end
    local info = GetExpansionDisplayInfo(lvl)
    return info and info.logo or nil
end

-- The art for an instance as (texture, texCoord). The buttonImage1 banner (the picture the journal
-- shows in its instance list, names baked in) cropped with the journal's own EJ_TILE_TC fills the
-- tile edge-to-edge -> preferred. bgImage is only a fallback (it's a centred scene with padding, so
-- it leaves a margin) for the rare instance with no banner.
-- An art descriptor for an instance tile. Prefer the full-bleed, high-def SCENE (bgImage) and
-- cover-crop it to the box -- it has no padding, so it fills crisply. The low-def buttonImage1
-- banner is only a fallback (cropped + zoomed) for an instance that has no scene.
-- Per-kind ("raid"/"dungeon") cover zoom + pan for the scene art, seeded from the code defaults.
-- These are RUNTIME (per session): the Dev module live-tunes them via SetArtTune; they reset to the
-- EJ_BG_* defaults every load. On a normal character nothing changes them, so the art is identical.
function Dashboard:_ArtTune(kind)
    local p = self:_p()
    if not p.artTune then
        p.artTune = {
            raid    = { zoom = EJ_BG_ZOOM, panX = EJ_BG_PAN_X, panY = EJ_BG_PAN_Y },
            dungeon = { zoom = EJ_BG_ZOOM, panX = EJ_BG_PAN_X, panY = EJ_BG_PAN_Y },
        }
    end
    return p.artTune[kind] or p.artTune.dungeon
end

-- Read / live-update the scene art tuning for a kind. SetArtTune re-renders if the Dashboard is open
-- so a Dev slider drag is reflected immediately. field is "zoom" | "panX" | "panY".
function Dashboard:GetArtTune(kind) return self:_ArtTune(kind) end
function Dashboard:SetArtTune(kind, field, value)
    self:_ArtTune(kind)[field] = value
    self:_RenderIfShown()
end

function Dashboard:_InstanceArt(name, kind)
    local p = self:_p()
    if not name then return nil end
    if p.ejBg and p.ejBg[name] then
        local t = self:_ArtTune(kind or "dungeon")
        return { texture = p.ejBg[name], cover = true, aspect = EJ_BG_ASPECT,
                 zoom = t.zoom, panX = t.panX, panY = t.panY }
    end
    if p.ejImage and p.ejImage[name] then return { texture = p.ejImage[name], texCoord = EJ_TILE_TC, zoom = EJ_TILE_ZOOM } end
    return nil
end

-- The last (newest) raid / dungeon in the current expansion's catalog -- the picture used for the
-- current-tier tile, so it shows the real instance art instead of the generic expansion logo.
function Dashboard:_LatestRaidArt()
    local p = self:_p()
    local r = p.ejRaidsByTier and p.currentExpansion and p.ejRaidsByTier[p.currentExpansion]
    if r and #r > 0 then return self:_InstanceArt(r[#r], "raid") end
end

function Dashboard:_LatestDungeonArt()
    local p = self:_p()
    local d = p.ejDungeonsByTier and p.currentExpansion and p.ejDungeonsByTier[p.currentExpansion]
    if d and #d > 0 then return self:_InstanceArt(d[#d], "dungeon") end
end

-- A RANDOM current-season dungeon's art for the Current Season tile. Picked once, then cached.
function Dashboard:_SeasonDungeonArt()
    local p = self:_p()
    if p.seasonPicName then return self:_InstanceArt(p.seasonPicName, "dungeon") end
    local s = self:_SeasonDungeons()
    if not s then return nil end
    local cand = {}
    for _, name in ipairs(s.list) do
        if (p.ejImage and p.ejImage[name]) or (p.ejBg and p.ejBg[name]) then cand[#cand + 1] = name end
    end
    if #cand == 0 then return nil end
    p.seasonPicName = cand[math.random(#cand)]
    return self:_InstanceArt(p.seasonPicName, "dungeon")
end

-- Distinct expansions in the registry for one kind (raids if wantRaid, else dungeons), the
-- current expansion first then A-Z. Persists -- an expansion stays once anything in it is known.
function Dashboard:_KnownExpansions(wantRaid)
    local set = {}
    for _, r in pairs(self:_Instances()) do
        if r.isRaid == wantRaid then set[r.expansion or "Other"] = true end
    end
    local list, cur = {}, self:_p().currentExpansion
    for exp in pairs(set) do list[#list + 1] = exp end
    table.sort(list, function(a, b)
        if (a == cur) ~= (b == cur) then return a == cur end
        return a < b
    end)
    return list
end

-- ---- raids: the FULL catalog (every raid has a weekly lockout, so show them all) -----------
-- Tiers that have raids, newest first (from the Encounter Journal catalog).
function Dashboard:_RaidExpansions()
    return self:_p().ejTierOrder or {}
end

-- One column per instance in `tierName`'s catalog (raids if isRaid, else dungeons; defaults to
-- the current tier). Cell = the character's highest-difficulty lock for it, or "-".
function Dashboard:_CatalogColumns(tierName, isRaid)
    local byTier = isRaid and self:_p().ejRaidsByTier or self:_p().ejDungeonsByTier
    tierName = tierName or self:_p().currentExpansion
    local list = (byTier and byTier[tierName]) or {}
    local cols = {}
    for _, name in ipairs(list) do
        local nm = name
        cols[#cols + 1] = { label = nm, width = 130, cell = function(e) return self:_BestLockText(e, nm, isRaid) end }
    end
    return cols
end

-- A character's lockout for one instance: the HIGHEST difficulty it's saved at, as "D x/y", else "-".
function Dashboard:_BestLockText(e, name, isRaid)
    local best, bestRank
    for _, l in ipairs(e.lockouts or {}) do
        if (l.isRaid and true or false) == isRaid and l.name == name then
            local rank = (DIFF[l.diff] and DIFF[l.diff].rank) or 0
            if not best or rank > bestRank then best, bestRank = l, rank end
        end
    end
    if not best then return "-" end
    local d = (DIFF[best.diff] and DIFF[best.diff].abbr) or (best.diff and best.diff:sub(1, 1)) or ""
    return (d ~= "" and d .. " " or "") .. (best.progress or 0) .. "/" .. (best.total or "?")
end

-- ---- dungeons: the CURRENT M+ SEASON (always shown with Mythic 0) --------------------------
-- The current M+ season's dungeon lineup -- can include legacy-expansion dungeons, and they ALL
-- carry a Mythic 0 lockout while in season. From C_ChallengeMode.GetMapTable(); cached + a set.
function Dashboard:_SeasonDungeons()
    local p = self:_p()
    if p.season then return p.season end
    if not (C_ChallengeMode and C_ChallengeMode.GetMapTable and C_ChallengeMode.GetMapUIInfo) then return nil end
    local ids = C_ChallengeMode.GetMapTable()
    if not ids or #ids == 0 then return nil end
    local list, set = {}, {}
    for _, mapID in ipairs(ids) do
        local name = C_ChallengeMode.GetMapUIInfo(mapID)
        if name and name ~= "Keystone Dungeons" then list[#list + 1] = name; set[name] = true end
    end
    table.sort(list)
    p.season = { list = list, set = set }
    return p.season
end

-- One column per current-season dungeon; cell = the character's Mythic 0 lock ("x/y") or "-".
function Dashboard:_SeasonColumns()
    local s = self:_SeasonDungeons()
    if not s then return {} end
    local cols = {}
    for _, name in ipairs(s.list) do
        local dname = name
        cols[#cols + 1] = { label = dname, width = 130, cell = function(e)
            for _, l in ipairs(e.lockouts or {}) do
                if l.name == dname and l.diff == M0 then return (l.progress or 0) .. "/" .. (l.total or "?") end
            end
            return "-"
        end }
    end
    return cols
end

-- A dungeon's Mythic 0 exists only while it's in the current season; once it rotates out it has no
-- Mythic difficulty, so on snapshot we drop any stale M0 registry entry no longer in the lineup.
function Dashboard:_PruneRegistry()
    local s = self:_SeasonDungeons()
    if not s then return end   -- season not known yet -> leave the registry untouched
    local inst = self:_Instances()
    for key, r in pairs(inst) do
        if (not r.isRaid) and r.diff == M0 and not s.set[r.name] then inst[key] = nil end
    end
end

-- Columns from the self-curating registry, filtered by predicate(registryEntry). Each cell is the
-- character's CURRENT lock for that instance (boss progress) or "-" when not currently locked.
function Dashboard:_LockoutColumns(predicate)
    local cols = {}
    for _, r in pairs(self:_Instances()) do
        if predicate(r) then
            local name, diff, total = r.name, r.diff, r.total
            cols[#cols + 1] = { label = diff and (name .. " (" .. diff .. ")") or name,
                width = 110, cell = function(e)
                    for _, l in ipairs(e.lockouts or {}) do
                        if l.name == name and l.diff == diff then
                            return (l.progress or 0) .. "/" .. (l.total or total or "?")
                        end
                    end
                    return "-"
                end }
        end
    end
    table.sort(cols, function(a, b) return a.label < b.label end)
    return cols
end

-- ===========================================================================
-- Window: left rail (avatar + char header + a 1-column nav GRID) | content (reset header +
-- title + an N-column data GRID). BOTH panels are ns.UI.Widgets.Grid instances, so the sidebar
-- items, section headers and the data columns all align through ONE layout engine -- no
-- hand-computed offsets, so headers and cells can't drift apart.
-- ===========================================================================
local NAME_COL = 150   -- the sticky character-name column (shared by the data grid)

function Dashboard:_Build()
    local p = self:_p()
    if p.built then return end

    local f = W.Window(100, { name = "HagAIODashboard", width = 860, height = 520,
        strata = "HIGH", title = "Dashboard", onClose = function() self:Hide() end,
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

    -- the category tree is a Navigation widget; selecting a category re-renders the data grid
    local nav = W.Nav(rail, {
        items = self:_NavItems(),
        scroll = true, name = "HagAIODashboardNav",   -- themed scrollbar; bounded to the rail
        cellPad = 7,   -- 3px bar + 4px gap, so the label clears the active bar
        onSelect = function(key)
            p.category = key
            self:_Render()
            if p.grid then p.grid:ScrollTop() end   -- a new category starts at the top
        end,
    })
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

    local grid = W.Grid(content, { name = "HagAIODashboardGrid", header = true, striped = true })
    grid:SetPoint("TOPLEFT", catTitle, "BOTTOMLEFT", 0, -12)
    grid:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -10, 12)
    p.grid = grid

    -- the overview: a journal-style icon grid (one tile per expansion) shown over the same area
    -- as the data grid; selecting Raids/Dungeons shows this, picking a tile drills into the grid.
    local iconGrid = W.IconGrid(content, { name = "HagAIODashboardIcons" })
    iconGrid:SetPoint("TOPLEFT", catTitle, "BOTTOMLEFT", 0, -12)
    iconGrid:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -10, 12)
    iconGrid:Hide()
    p.iconGrid = iconGrid

    p.built = true
    p.nav:Select(p.category)   -- highlight the default category + render it via onSelect
end

-- Is a category enabled in the settings? Dynamic "raid:<exp>" keys follow the Raids toggle.
function Dashboard:_CategoryVisible(key)
    if key:match("^raid:") then return self:GetSetting("show_raids") ~= false end
    return self:GetSetting("show_" .. key) ~= false
end

-- The navigation items: a section header per group, a selectable (indented) item otherwise.
-- Categories the player has hidden in the settings are skipped, and a section header with no
-- visible items beneath it is dropped.
function Dashboard:_NavItems()
    local cat = self:_p().category or ""
    -- expansion sub-nodes stay COLLAPSED until that category (or one of its sub-keys) is active
    local raidsOpen = cat == "raids" or cat:match("^raid:") ~= nil
    local dungeonsOpen = cat == "dungeons" or cat:match("^dungeon:") ~= nil
    local items = { { key = "home", label = HOME_ICON } }   -- icon-only Home, above everything
    for _, c in ipairs(CATEGORIES) do
        if c.header then
            items[#items + 1] = { section = c.label }
        elseif self:_CategoryVisible(c.key) then
            items[#items + 1] = { key = c.key, label = c.label, indent = c.indent and 1 or 0 }
            -- a deeper sub-node per expansion, only while this category is open (collapsible tree)
            if c.key == "raids" and raidsOpen then
                for _, exp in ipairs(self:_RaidExpansions()) do      -- all raid tiers (full catalog)
                    items[#items + 1] = { key = "raid:" .. exp, label = exp, indent = 2 }
                end
            elseif c.key == "dungeons" and dungeonsOpen then
                if self:_SeasonDungeons() then
                    items[#items + 1] = { key = "dungeon:current", label = "Current Season", indent = 2 }
                end
                -- the current expansion's FULL dungeon catalog (not just the M+ season subset)
                local cur, dbt = self:_p().currentExpansion, self:_p().ejDungeonsByTier
                if cur and dbt and dbt[cur] then
                    items[#items + 1] = { key = "dungeon:" .. cur, label = cur, indent = 2 }
                end
                for _, exp in ipairs(self:_KnownExpansions(false)) do
                    if exp ~= cur then items[#items + 1] = { key = "dungeon:" .. exp, label = exp, indent = 2 } end
                end
            end
        end
    end
    local out = {}
    for i, it in ipairs(items) do
        if it.section then
            local nxt = items[i + 1]
            if nxt and not nxt.section then out[#out + 1] = it end  -- keep only non-empty sections
        else
            out[#out + 1] = it
        end
    end
    return out
end

-- Resolve a nav key to (title, columns()). "raids"/"dungeons" show every known instance of that
-- kind; "raid:<exp>"/"dungeon:<exp>" filter to one expansion; the rest are static CATEGORIES.
function Dashboard:_ResolveCategory(key)
    if key == "raids" then
        return "Raids", function() return self:_CatalogColumns(nil, true) end       -- current tier
    elseif key == "dungeons" then
        return "Dungeons", function() return self:_CatalogColumns(nil, false) end    -- current expansion
    end
    local rexp = key and key:match("^raid:(.+)$")
    if rexp then
        return rexp .. " Raids", function() return self:_CatalogColumns(rexp, true) end
    end
    local dexp = key and key:match("^dungeon:(.+)$")
    if dexp == "current" then
        return "Current Season", function() return self:_SeasonColumns() end
    elseif dexp == self:_p().currentExpansion then
        return dexp .. " Dungeons", function() return self:_CatalogColumns(dexp, false) end   -- full catalog
    elseif dexp then
        return dexp .. " Dungeons", function()
            local s = self:_SeasonDungeons()
            return self:_LockoutColumns(function(r)
                if r.isRaid or (r.expansion or "Other") ~= dexp then return false end
                return not (r.diff == M0 and s and s.set[r.name])   -- season M0 lives in Current Season
            end)
        end
    end
    for _, c in ipairs(CATEGORIES) do
        if c.key == key then return c.label, c.columns end
    end
    return CATEGORIES[1].label, CATEGORIES[1].columns
end

-- Sorted character keys: the current character first, then alphabetical.
function Dashboard:_SortedChars()
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

-- The Home overview tiles: one per top-level category (image + name), 3 per row. Raids/Dungeons
-- use the latest instance art; the quest/keystone categories use a contained native icon. Hidden
-- categories (settings) are skipped. Clicking a tile selects that category in the nav.
function Dashboard:_CategoryTiles()
    local p = self:_p()
    local function go(key) return function() p.nav:Select(key) end end
    local logo = self:_ExpansionLogo(p.currentExpansion)
    local raidArt = self:_LatestRaidArt()
    local dunArt = self:_SeasonDungeonArt() or self:_LatestDungeonArt()
    local defs = {
        { key = "mplus",    label = "Mythic+",       contain = true,
          texture = "Interface\\Icons\\Achievement_ChallengeMode_Gold" },
        { key = "raids",    label = "Raids",         art = raidArt, fallback = logo },
        { key = "dungeons", label = "Dungeons",      art = dunArt,  fallback = logo },
        { key = "weekly",   label = "Weekly Quests", contain = true,
          texture = "Interface\\Icons\\Achievement_Quests_Completed_06" },
        { key = "daily",    label = "Daily Quests",  contain = true,
          texture = "Interface\\Icons\\INV_Misc_PocketWatch_01" },
    }
    local tiles = {}
    for _, d in ipairs(defs) do
        if self:_CategoryVisible(d.key) then
            local tile = { label = d.label, contain = d.contain,
                texture = d.texture or d.fallback, onClick = go(d.key) }
            if d.art then applyArt(tile, d.art) end
            tiles[#tiles + 1] = tile
        end
    end
    return tiles
end

-- The overview's icon tiles: one per expansion (native logo + name), clicking drills into that
-- expansion's data grid. "raids" lists every raid tier; "dungeons" lists Current Season, the
-- current expansion, then the legacy expansions we hold dungeon records for.
function Dashboard:_OverviewTiles(key)
    local p = self:_p()
    local tiles = {}
    local function tile(label, logoTier, navKey)
        tiles[#tiles + 1] = {
            texture = self:_ExpansionLogo(logoTier),
            label = label,
            onClick = function() p.nav:Select(navKey) end,
        }
    end
    if key == "raids" then
        for _, exp in ipairs(self:_RaidExpansions()) do
            tile(exp, exp, "raid:" .. exp)
            -- the current tier's tile shows the latest raid's picture, not the expansion logo
            if exp == p.currentExpansion then
                local art = self:_LatestRaidArt()
                if art then applyArt(tiles[#tiles], art) end
            end
        end
    elseif key == "dungeons" then
        if self:_SeasonDungeons() then
            tile("Current Season", p.currentExpansion, "dungeon:current")
            -- Current Season shows a random season-dungeon scene, distinct from the expansion logo
            local art = self:_SeasonDungeonArt()
            if art then applyArt(tiles[#tiles], art) end
        end
        local cur, dbt = p.currentExpansion, p.ejDungeonsByTier
        if cur and dbt and dbt[cur] then tile(cur, cur, "dungeon:" .. cur) end
        for _, exp in ipairs(self:_KnownExpansions(false)) do
            if exp ~= cur then tile(exp, exp, "dungeon:" .. exp) end
        end
    end
    return tiles
end

function Dashboard:_Render()
    local p = self:_p()
    if not p.built then return end
    self:_UpdateHeader()
    self:_UpdateCountdown()
    self:_ExpansionMap()                 -- build the raid->expansion map (no-op once cached)
    -- backfill the tier on any registry entry recorded before the journal map was ready
    local map = self:_p().ejMap
    if map then
        for _, r in pairs(self:_Instances()) do
            if (not r.expansion or r.expansion == "Other") and map[r.name] then r.expansion = map[r.name] end
        end
    end

    local items = self:_NavItems()
    -- keep the selection valid: if the active category was hidden, fall back to the first one
    local valid
    for _, it in ipairs(items) do if it.key == p.category then valid = true; break end end
    if not valid then
        for _, it in ipairs(items) do if it.key then p.category = it.key; break end end
    end
    p.nav:SetItems(items)
    p.nav:Select(p.category, true)       -- reflect the (possibly changed) active selection silently

    local keys, chars = self:_SortedChars()
    local label, columnsFn = self:_ResolveCategory(p.category)

    -- the Home/Raids/Dungeons overviews are journal-style icon grids, not the data grid
    if p.category == "home" or p.category == "raids" or p.category == "dungeons" then
        p.grid:Hide()
        p.iconGrid:Show()
        if p.category == "home" then
            p.catTitle:SetText("Overview")
            p.iconGrid:SetTiles(self:_CategoryTiles())
        else
            p.catTitle:SetText(label)
            p.iconGrid:SetTiles(self:_OverviewTiles(p.category))
        end
        p.iconGrid:ScrollTop()
        return
    end
    p.catTitle:SetText(label)
    p.iconGrid:Hide()
    p.grid:Show()

    local cols = (columnsFn and columnsFn(chars)) or {}

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

function Dashboard:_UpdateHeader()
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

function Dashboard:_RenderIfShown()
    if self:_p().shown then self:_Render() end
end

function Dashboard:_UpdateCountdown()
    local p = self:_p()
    if not p.resetHdr then return end
    local weekly = C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset and C_DateAndTime.GetSecondsUntilWeeklyReset()
    local daily  = C_DateAndTime and C_DateAndTime.GetSecondsUntilDailyReset  and C_DateAndTime.GetSecondsUntilDailyReset()
    p.resetHdr:SetText(("Weekly reset in |cff%s%s|r      Daily reset in |cff%s%s|r")
        :format(Theme.hex.accent, clock(weekly), Theme.hex.accent, clock(daily)))
end

-- ---- show / hide ----------------------------------------------------------
function Dashboard:Show()
    self:_Build()
    local p = self:_p()
    p.shown = true
    p.frame:Show()
    self:_Render()
    if p.ticker then p.ticker:Cancel() end
    p.ticker = C_Timer.NewTicker(1, function() if p.shown then self:_UpdateCountdown() end end)
    C_Timer.After(0, function() self:_Render() end)   -- re-measure once on screen
end

function Dashboard:Hide()
    local p = self:_p()
    p.shown = false
    if p.ticker then p.ticker:Cancel(); p.ticker = nil end
    if p.frame then p.frame:Hide() end
end

function Dashboard:Toggle()
    if self:_p().shown then self:Hide() else self:Show() end
end

-- ---- registration ---------------------------------------------------------
ns.ModuleManager:Register(Dashboard:New("Dashboard", {
    title = "Dashboard",
    description = "A cross-character view of weekly/daily resets: Great Vault, M+ keystone, lockouts and recurring quests.",
    defaultEnabled = false,
    color = ns.Theme.hex.accent,
    deps = { "SavedVars", "SlashCommand", "Secrets" },
    commands = {
        dashboard = { handler = "Toggle", help = "open the cross-character Dashboard" },
    },
    settings = {
        { type = "header", text = "Categories" },
        { type = "toggle", key = "show_mplus",    label = "Mythic+",       default = true },
        { type = "toggle", key = "show_raids",    label = "Raids",         default = true },
        { type = "toggle", key = "show_dungeons", label = "Dungeons",      default = true },
        { type = "toggle", key = "show_weekly",   label = "Weekly Quests", default = true },
        { type = "toggle", key = "show_daily",    label = "Daily Quests",  default = true },
        { type = "note", text = "Choose which categories appear in the Dashboard. Open it with /hag dashboard." },
    },
}))
