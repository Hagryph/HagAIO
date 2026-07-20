local addonName, ns = ...
local Class = ns.Class
local Ledger = ns.ResetLedger
local DB = ns.DB

-- Modules/Dashboard/CharacterStore.lua
-- The Dashboard's per-character DATA layer, extracted out of the 2.5k-line module so the module
-- itself stays UI + lifecycle. A plain COLLABORATOR class (the CooldownWatch / HookHandle house
-- style): built with CharacterStore:New(owner) where `owner` is the Dashboard module. The owner is
-- used only for a LIVE owner:DB() (the shared database is nil until built on PLAYER_LOGIN, and this
-- collaborator is constructed at OnInitialize while it is still nil -- so the handle is fetched per
-- call, NEVER cached). The self-curating lockout path also needs two catalog lookups (id-for-name +
-- instance record); those live on the sibling ExpansionCatalog collaborator, wired in via SetCatalog
-- (Dashboard builds both at OnInitialize, then hands this one the catalog).
--
-- It fronts five flat tables (the full doc is in the Dashboard module header):
--   dashboard_char     one row per character (scalars + the flattened keystone)
--   dashboard_vault    the character's Great-Vault slots          (child, cascades on char delete)
--   dashboard_lockout  the character's current raid/dungeon locks (child, cascades)
--   dashboard_quest    recorded weekly/daily quest turn-ins        (child, cascades)
--   dashboard_instance the "name|difficulty" registry (account-wide, not per character)
-- Chars() RECONSTRUCTS the document shape the renderers read ({ vault = { slots = {} }, lockouts =
-- {}, quests = { freq = { id = title } }, keystone = {} }) from these tables; the five collectors
-- ingest live game state. The keystone reference table (map id -> name) is rebuilt each session.

local CharacterStore = Class.new("CharacterStore")

function CharacterStore:Initialize(owner)
    self:_p().owner = owner
end

-- Wire the ExpansionCatalog collaborator (built after this one in Dashboard:OnInitialize). The
-- self-curating lockout path resolves an unseeded lock's journal id + record through it.
function CharacterStore:SetCatalog(catalog) self:_p().catalog = catalog end

-- The single shared Database, fetched LIVE through the owner on every call (nil until built; never
-- cached -- this collaborator is constructed pre-login while DB() is still nil).
function CharacterStore:DB() return self:_p().owner:DB() end

-- A projected column is the DB.NULL sentinel (not Lua nil) when absent; collapse it to nil so the
-- reconstructed documents read exactly like the old plain-Lua snapshots (l.progress or 0, etc.).
local denull = DB.denull
local function plainNum(v) return ns.DashboardData.PlainNum(v) end

function CharacterStore:SelfKey()
    local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName()
    return Ledger:CharKey(UnitName("player"), realm)
end

-- The raw dashboard_char row for a key (or nil).
function CharacterStore:_CharRow(key)
    local db = self:DB(); if not db then return nil end
    return db:Select("*"):From("dashboard_char"):Where("char_key", "=", key):Limit(1):Run()[1]
end

-- Upsert the viewing character's dashboard_char row, merging `changes` and stamping last_seen. Ensures
-- the row EXISTS first, so the child tables' FKs (vault/lockout/quest -> char) always resolve. This is
-- the relational stand-in for the old _SelfEntry() (which lazily created the nested entry + lastSeen).
function CharacterStore:_SetSelf(changes)
    local db = self:DB(); if not db then return end
    self:_p().charsCache = nil
    local key = self:SelfKey()
    changes = changes or {}
    changes.last_seen = (GetServerTime and GetServerTime()) or time()
    if self:_CharRow(key) then db:Update("dashboard_char", changes, { char_key = key })   -- PK map: index lookup
    else changes.char_key = key; db:Insert("dashboard_char", changes) end
end

-- Replace ALL of the viewing character's rows in a child table (dashboard_vault / dashboard_lockout)
-- with `rows` (each a column map already carrying the rest of its PK -- vault an `ordinal`, lockout an
-- `instance_key`). Delete-then-insert mirrors the old whole-substructure replacement.
function CharacterStore:_ReplaceSelfChildren(tname, rows)
    local db = self:DB(); if not db then return end
    self:_p().charsCache = nil
    local key = self:SelfKey()
    db:Delete(tname, { char_key = key })   -- PK-member map: index lookup, no scan
    if #rows == 0 then return end
    for _, r in ipairs(rows) do r.char_key = key end
    db:InsertAll(tname, rows)
end

-- Reconstruct every character's snapshot as a document keyed by char_key (one query per table; the
-- children + reference rows are bucketed in memory). The reference tables resolve the normalised
-- foreign keys back into the document fields the renderers read (keystone name, lockout instance
-- name/difficulty, quest title). Mirrors the old chars[key] = { ... nested ... } map exactly.
function CharacterStore:Chars()
    local p = self:_p()
    if p.charsCache then return p.charsCache end   -- assembled doc, cached until a writer invalidates it
    local db = self:DB(); if not db then return {} end   -- don't cache the pre-build empty result
    local ksName, inst = {}, self:Instances()
    for _, k in ipairs(db:Select("*"):From("keystone"):Run()) do ksName[k.mapid] = denull(k.name) end

    local chars = {}
    for _, c in ipairs(db:Select("*"):From("dashboard_char"):Run()) do
        local doc = {
            name = denull(c.name), realm = denull(c.realm), class = denull(c.class),
            level = denull(c.level), ilvl = denull(c.ilvl),
            lastSeen = denull(c.last_seen), rating = denull(c.rating),
            lockouts = {}, vault = { slots = {} }, quests = {},
        }
        local mapid = denull(c.ks_mapid)
        if mapid then doc.keystone = { mapID = mapid, level = denull(c.ks_level), name = ksName[mapid] } end
        chars[c.char_key] = doc
    end
    for _, v in ipairs(db:Select("*"):From("dashboard_vault"):Run()) do
        local doc = chars[v.char_key]
        if doc then
            local s = doc.vault.slots
            s[#s + 1] = { type = denull(v.type), level = denull(v.level),
                progress = denull(v.progress), threshold = denull(v.threshold) }
        end
    end
    for _, l in ipairs(db:Select("*"):From("dashboard_lockout"):Run()) do
        local doc, ref = chars[l.char_key], inst[l.instance_key]
        if doc and ref then
            local lk = doc.lockouts
            lk[#lk + 1] = { name = ref.name, diff = ref.diff, isRaid = ref.isRaid,
                total = denull(l.total), progress = denull(l.progress), reset = denull(l.reset) }
        end
    end
    for _, q in ipairs(db:Select("*"):From("dashboard_quest"):Run()) do
        local doc = chars[q.char_key]
        if doc then
            doc.quests[q.freq] = doc.quests[q.freq] or {}
            -- the LAST turn-in moment (0 = legacy row, never counts as done); titles live on `quest`
            doc.quests[q.freq][q.quest_id] = denull(q.done_at) or 0
        end
    end
    p.charsCache = chars
    return chars
end

-- Drop the cached cross-character document so the next Chars() rebuilds it. Called by every writer
-- below (so a collector write is reflected on the next render). The ExpansionCatalog seeds
-- dashboard_instance directly, but _RefreshNow always runs Snapshot() -- whose collectors invalidate
-- here -- right after a catalog build, so a seeded instance is picked up before the render.
function CharacterStore:InvalidateChars() self:_p().charsCache = nil end

-- Upsert the local keystone name table (map id -> display name); the keystone names are reference
-- data, rebuilt each session, that dashboard_char's ks_mapid FK points at.
function CharacterStore:SetKeystone(mapid, name)
    local db = self:DB(); if not (db and mapid) then return end
    self:_p().charsCache = nil   -- Chars() resolves keystone names from this table

    if db:Select("mapid"):From("keystone"):Where("mapid", "=", mapid):Limit(1):Run()[1] then
        db:Update("keystone", { name = name }, { mapid = mapid })
    else db:Insert("keystone", { mapid = mapid, name = name }) end
end

-- Ensure the local keystone table has a name for every map id any character holds, so an alt's
-- keystone (its map id persists on dashboard_char, but the local name table is rebuilt each session)
-- still renders a name. Cheap: GetMapUIInfo resolves any map id offline.
function CharacterStore:SeedKeystones()
    ns.Worker:Mark("seed keystones")
    local db = self:DB(); if not db then return end
    if not (C_ChallengeMode and C_ChallengeMode.GetMapUIInfo) then return end
    for _, c in ipairs(db:Select("ks_mapid"):From("dashboard_char"):Run()) do
        local mapid = denull(c.ks_mapid)
        if mapid and not db:Select("mapid"):From("keystone"):Where("mapid", "=", mapid):Limit(1):Run()[1] then
            self:SetKeystone(mapid, C_ChallengeMode.GetMapUIInfo(mapid))
        end
        ns.Worker:MaybeYield()
    end
end

-- Reconstruct the instance registry keyed by "name|difficulty". Read-only; the writers below mutate
-- dashboard_instance directly (the old code mutated this returned table in place).
function CharacterStore:Instances()
    local db = self:DB(); if not db then return {} end
    local out = {}
    for _, r in ipairs(db:Select("*"):From("dashboard_instance"):Run()) do
        out[r.key] = { id = denull(r.instance_id), name = denull(r.name), diff = denull(r.diff),
            isRaid = denull(r.is_raid), diffID = denull(r.diff_id), total = denull(r.total),
            expansion = denull(r.expansion), season = denull(r.current_season) and true or false }
    end
    return out
end

-- Upsert one dashboard_instance row (key = "name|difficulty"), merging `changes` (omitted keys keep
-- their stored value -- so a later sighting with a nil diffID/total never clobbers a known one).
function CharacterStore:SetInstance(key, changes)
    local db = self:DB(); if not db then return end
    self:_p().charsCache = nil   -- Chars() resolves lockout name/diff from this registry
    local exists = db:Select("key"):From("dashboard_instance"):Where("key", "=", key):Limit(1):Run()[1]
    if exists then db:Update("dashboard_instance", changes, { key = key })
    else changes.key = key; db:Insert("dashboard_instance", changes) end
end

-- ---- collectors (each guarded so a missing API is a no-op, never an error) -
function CharacterStore:CollectInfo()
    local changes = {
        name  = UnitName("player"),
        realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName(),
        level = UnitLevel("player"),
    }
    local _, classFile = UnitClass("player")
    changes.class = classFile
    if GetAverageItemLevel then
        local _, equipped = GetAverageItemLevel()
        if equipped then changes.ilvl = math.floor(equipped + 0.5) end   -- else keep the stored ilvl
    end
    self:_SetSelf(changes)
end

function CharacterStore:CollectKeystone()
    local changes = {}
    local mapID = C_MythicPlus and C_MythicPlus.GetOwnedKeystoneMapID and C_MythicPlus.GetOwnedKeystoneMapID()
    local level = C_MythicPlus and C_MythicPlus.GetOwnedKeystoneLevel and C_MythicPlus.GetOwnedKeystoneLevel()
    if mapID and level and level > 0 then
        local name = C_ChallengeMode and C_ChallengeMode.GetMapUIInfo and C_ChallengeMode.GetMapUIInfo(mapID)
        self:SetKeystone(mapID, name)   -- the FK target must exist before ks_mapid points at it
        changes.ks_mapid, changes.ks_level = mapID, level
    else
        changes.ks_mapid, changes.ks_level = ns.DB.NULL, ns.DB.NULL   -- clear
    end
    local summary = C_PlayerInfo and C_PlayerInfo.GetPlayerMythicPlusRatingSummary
        and C_PlayerInfo.GetPlayerMythicPlusRatingSummary("player")
    if summary and summary.currentSeasonScore then changes.rating = summary.currentSeasonScore end
    self:_SetSelf(changes)
end

function CharacterStore:CollectVault()
    self:_SetSelf({})   -- ensure the char row (FK target) + last_seen, as the old _SelfEntry() did
    local acts = C_WeeklyRewards and C_WeeklyRewards.GetActivities and C_WeeklyRewards.GetActivities()
    if not acts then return end
    local slots = {}
    for i, a in ipairs(acts) do
        -- progress/threshold can be secret in restricted content -- store only a plain number, so a
        -- cross-char cell never computes on a secret (see plainNum; a secret is stored as NULL).
        slots[#slots + 1] = { ordinal = i, type = a.type, level = a.level,
            progress = plainNum(a.progress), threshold = plainNum(a.threshold) }
    end
    self:_ReplaceSelfChildren("dashboard_vault", slots)
end

-- All saved instances the character is locked to (raids AND dungeons, every difficulty, current
-- AND legacy). GetSavedInstanceInfo returns ONLY active locks, so "which difficulty has a lockout"
-- needs no curated table -- if it's locked it's here (with its difficulty + boss count), if not it
-- isn't. We capture the difficulty name so a multi-difficulty lock (e.g. LFR + Heroic of one raid)
-- shows as separate entries.
-- Map a saved-instance (name, difficulty id) to its catalog row KEY. Built from the seeded catalog,
-- so a lock resolves to the exact journal instance + difficulty (two same-named instances differ by
-- difficulty). A lock with no matching catalog row (e.g. an unseeded legacy dungeon) is skipped.
function CharacterStore:_LockKeyMap()
    local db = self:DB(); local out = {}
    if not db then return out end
    for _, r in ipairs(db:Select("key", "name", "diff_id"):From("dashboard_instance"):Run()) do
        local nm, did = denull(r.name), denull(r.diff_id)
        if nm and did then out[nm] = out[nm] or {}; out[nm][did] = r.key end
        ns.Worker:MaybeYield()
    end
    return out
end

function CharacterStore:CollectLockouts()
    self:_SetSelf({})   -- ensure the char row (FK target) + last_seen, as the old _SelfEntry() did
    local cat = self:_p().catalog
    local key2 = self:_LockKeyMap()
    local n = (GetNumSavedInstances and GetNumSavedInstances()) or 0
    local locks, seen = {}, {}
    for i = 1, n do
        local name, _, reset, diffID, locked, _, _, _, _, _, numEnc, prog = GetSavedInstanceInfo(i)
        if locked and reset and reset > 0 and name and diffID then
            local instKey = key2[name] and key2[name][diffID]   -- the catalog row for this instance+difficulty
            if not instKey then
                -- SELF-CURATE: a lock for an instance/difficulty the seeded catalog doesn't cover (e.g. a
                -- dungeon at a non-M0 difficulty, or one outside the current expansion / season). Register
                -- it under its journal id so the lock still has a row and is gathered as you play. The
                -- catalog lookups (id-for-name + instance record) live on the ExpansionCatalog collaborator.
                local id = cat:_IdForName(name)
                local rec = id and cat:_InstRecord(id)
                local diffName = GetDifficultyInfo and GetDifficultyInfo(diffID)
                if rec and diffName then
                    instKey = id .. "|" .. diffID
                    self:SetInstance(instKey, { instance_id = id, name = rec.name, diff = diffName,
                        diff_id = diffID, is_raid = rec.isRaid, expansion = rec.tier })
                    key2[name] = key2[name] or {}; key2[name][diffID] = instKey
                end
            end
            if instKey and not seen[instKey] then          -- one lock row per instance (PK is char + instance_key)
                seen[instKey] = true
                locks[#locks + 1] = { instance_key = instKey, total = numEnc,
                    progress = plainNum(prog), reset = reset }
            end
        end
        ns.Worker:MaybeYield()                             -- per saved instance: chunk to the pump budget
    end
    self:_ReplaceSelfChildren("dashboard_lockout", locks)
end

-- Record a turned-in quest under its reset frequency (daily/weekly), so the dashboard shows
-- which alt did which recurring quest this reset. Non-recurring quests are ignored. The caller
-- re-renders (this no longer touches the UI).
function CharacterStore:RecordQuest(questID)
    if not questID then return end
    local freq
    local info = C_QuestLog and C_QuestLog.GetQuestInfo  -- title fallback; frequency below
    local f = C_QuestLog and C_QuestLog.GetQuestFrequency and C_QuestLog.GetQuestFrequency(questID)
    if f == (Enum and Enum.QuestFrequency and Enum.QuestFrequency.Daily) then freq = "daily"
    elseif f == (Enum and Enum.QuestFrequency and Enum.QuestFrequency.Weekly) then freq = "weekly" end
    if not freq then return end
    local title = (C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID))
        or (info and info(questID)) or ("Quest " .. questID)
    self:_SetSelf({})   -- ensure the char row exists (FK target for dashboard_quest) + last_seen
    local db = self:DB()
    if db then
        -- record the title + AUTO-DISCOVERED home (zone + expansion) on the shared `quest` table (the
        -- FK target), preserving any `time` Questing learned; the per-character row then references
        -- the quest id under its frequency with the turn-in moment (reset-aware doneness).
        local changes = { title = title }
        local mapID = C_QuestLog and C_QuestLog.GetQuestUiMapID and C_QuestLog.GetQuestUiMapID(questID)
        if not mapID or mapID == 0 then     -- quest carries no map -> the player's zone at turn-in
            mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
        end
        if mapID and mapID > 0 then
            changes.zone_map_id = mapID
            local mi = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
            if mi and mi.name then changes.zone_name = mi.name end
        end
        local lvl = GetQuestExpansion and GetQuestExpansion(questID)
        local expName = lvl and _G["EXPANSION_NAME" .. lvl]   -- localized, matches the EJ tier names
        if expName then changes.expansion = expName end
        if db:Select("quest_id"):From("quest"):Where("quest_id", "=", questID):Limit(1):Run()[1] then
            db:Update("quest", changes, { quest_id = questID })
        else changes.quest_id = questID; db:Insert("quest", changes) end
        local key = self:SelfKey()
        local now = (GetServerTime and GetServerTime()) or time()
        local exists = db:Select("quest_id"):From("dashboard_quest")
            :Where("char_key", "=", key):AndWhere("freq", "=", freq):AndWhere("quest_id", "=", questID):Limit(1):Run()[1]
        if exists then db:Update("dashboard_quest", { done_at = now }, { char_key = key, freq = freq, quest_id = questID })
        else db:Insert("dashboard_quest", { char_key = key, freq = freq, quest_id = questID, done_at = now }) end
    end
end

-- Snapshot this character into the store (info, keystone, vault, lockouts). The caller re-renders
-- after (this no longer touches the UI).
function CharacterStore:Snapshot()
    ns.Worker:Mark("collect info");     self:CollectInfo()
    ns.Worker:Mark("collect keystone"); self:CollectKeystone()
    ns.Worker:Mark("collect vault");    self:CollectVault()
    ns.Worker:Mark("collect lockouts"); self:CollectLockouts()
end

ns.CharacterStore = CharacterStore
