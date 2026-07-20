local addonName, ns = ...

-- Lib/DashboardData.lua
-- Pure data-shaping helpers extracted from the Dashboard module + its CharacterStore /
-- ExpansionCatalog collaborators, so the bits that guard typed columns and read the catalog
-- are unit-testable. These touch NO WoW API: the WoW-API reads (the expansion-level getters)
-- stay in the module and are handed in; the only addon-internal sentinels used are
-- ns.DB.isNull (the DB NULL marker) and ns.Secrets:Number (the secret -> number launder),
-- both available headless.
--   * VaultDone        -- "done/total" Great Vault slot count (or "-"), via ResetLedger:Progress.
--   * CurrentExpacLevel-- the current expansion level via a 3-way API fallback chain.
--   * PlainNum         -- launder a value to a plain number, NULLing a secret (typed-column writer).

local DashboardData = {}

-- Raid/dungeon difficulty ids (GetDifficultyInfo ids). One frozen member per id the dashboard
-- knows: a typo'd member ERRORS instead of yielding nil. Values are the raw ids verbatim, so every
-- read (candidate probe, seed-time diff_id, DIFF_META[r.diffID] lookup, M0 key/compare) stays
-- numerically identical. Defined here in Lib (loads after Core/Enum + before the Dashboard files),
-- so the Dashboard module and its ExpansionCatalog collaborator share the one definition.
local RaidDifficulty = ns.Enum.new("RaidDifficulty", {
    LFR              = 7,    -- legacy Looking For Raid
    RAID_FINDER      = 17,   -- flexible Raid Finder (modern LFR)
    LEGACY_10        = 3,    -- 10-player
    LEGACY_25        = 4,    -- 25-player
    LEGACY_40        = 9,    -- 40-player
    LEGACY_20        = 148,  -- 20-player
    NORMAL           = 14,   -- flexible Normal
    LEGACY_10_HEROIC = 5,    -- 10-player Heroic
    LEGACY_25_HEROIC = 6,    -- 25-player Heroic
    HEROIC           = 15,   -- flexible Heroic
    MYTHIC           = 16,   -- flexible Mythic
    MYTHIC_ZERO      = 23,   -- dungeon Mythic 0
})
ns.RaidDifficulty = RaidDifficulty

-- The inline-column metadata (short tag + sort rank) for a difficulty id. An immutable value type so
-- the metadata hangs off the enum instead of a parallel id->{abbr,rank} array; read via :Abbr()/:Rank().
local DiffMeta = ns.Type.new("DiffMeta", { "abbr", "rank" })
ns.DiffMeta = DiffMeta

-- DiffMeta per difficulty, keyed by the enum VALUE (the id) so a runtime `DiffMetaFor[r.diffID]`
-- lookup is byte-identical to the old DIFF_META[r.diffID]. Built from the enum members so the ids
-- can't drift from the enum. An id the dashboard doesn't tag is simply absent (falls back to name).
local RD = RaidDifficulty
local DiffMetaFor = {
    [RD.LFR]              = DiffMeta:New("LFR", 1), [RD.RAID_FINDER] = DiffMeta:New("LFR", 1),
    [RD.LEGACY_10]        = DiffMeta:New("10",  2), [RD.LEGACY_25]   = DiffMeta:New("25",  2),
    [RD.LEGACY_40]        = DiffMeta:New("40",  2),
    [RD.LEGACY_20]        = DiffMeta:New("20",  2), [RD.NORMAL]      = DiffMeta:New("N",   2),
    [RD.LEGACY_10_HEROIC] = DiffMeta:New("10H", 3), [RD.LEGACY_25_HEROIC] = DiffMeta:New("25H", 3),
    [RD.HEROIC]           = DiffMeta:New("H",   3),
    [RD.MYTHIC]           = DiffMeta:New("M",   4),
    [RD.MYTHIC_ZERO]      = DiffMeta:New("M0",  5),   -- dungeon Mythic 0
}

-- The metadata (abbr + sort rank) for a difficulty id, or nil for an untagged id.
function DashboardData.DiffMeta(diffID) return DiffMetaFor[diffID] end

-- A vault document's "done/total" slot count for the cross-character cell, or "-" when there
-- are no slots. A slot is done by ResetLedger:Progress(progress, threshold) (the same rule the
-- detail uses), so a partially-filled slot doesn't count.
function DashboardData.VaultDone(vault)
    local v = vault
    if not (v and v.slots and #v.slots > 0) then return "-" end
    local done = 0
    for _, s in ipairs(v.slots) do
        local _, isDone = ns.ResetLedger:Progress(s.progress, s.threshold)
        if isDone then done = done + 1 end
    end
    return done .. "/" .. #v.slots
end

-- The CURRENT expansion's level. LE_EXPANSION_LEVEL_CURRENT is deprecated in Midnight, so prefer
-- the live getters (the displayable client max), falling back through to the old constant. The
-- three sources are passed in (the module reads the WoW globals) so this stays pure: the display
-- getter, the level getter, and the constant fallback. Each getter may be nil (API absent).
function DashboardData.CurrentExpacLevel(getDisplay, getLevel, fallback)
    if getDisplay then return getDisplay() end
    if getLevel then return getLevel() end
    return fallback
end

-- Only a plain number is allowed into the typed columns: ns.Secrets:Number returns nil for a
-- SECRET value (restricted content), so a secret is stored as NULL rather than smuggled in as a
-- non-scalar. With no Secrets layer present the value passes through unchanged.
function DashboardData.PlainNum(v)
    if ns.Secrets then return ns.Secrets:Number(v) end   -- nil for a secret
    return v
end

ns.LibManager:RegisterValue("DashboardData", DashboardData)
