local addonName, ns = ...
local Class = ns.Class

-- Modules/Dashboard/ExpansionCatalog.lua
-- The Dashboard's instance + zone CATALOG layer, extracted out of the module so the module itself
-- stays UI + lifecycle. A plain COLLABORATOR class (the CharacterStore / CooldownWatch house style):
-- built with ExpansionCatalog:New(owner, charStore) where `owner` is the Dashboard module. It owns the
-- Encounter Journal walk + its reconstruction-from-DB, the seeded dashboard_instance / expansion /
-- zone catalogs, the per-instance art (splash/banner) resolution, and the season raid/dungeon pools.
-- The DB TABLES stay on the Dashboard module (this only reads/writes them through owner:DB()), so the
-- generated schema is unchanged. The owner is used for the LIVE owner:DB() (the shared database is nil
-- until built on PLAYER_LOGIN -- this collaborator is constructed pre-login, so the handle is fetched
-- per call, NEVER cached) and for the two versioning hooks the catalog build needs (the
-- ns.VersioningOwner mixin -- IsVersionCurrent / StampVersion -- stays on the Dashboard module).

local ExpansionCatalog = Class.new("ExpansionCatalog")

function ExpansionCatalog:Initialize(owner, charStore)
    local p = self:_p()
    p.owner = owner
    p.charStore = charStore
end

-- The single shared Database, fetched LIVE through the owner on every call (nil until built; never
-- cached -- this collaborator is constructed pre-login while DB() is still nil).
function ExpansionCatalog:DB() return self:_p().owner:DB() end

-- A projected column is the DB.NULL sentinel (not Lua nil) when absent; collapse it to nil so the
-- reconstructed documents read exactly like the old plain-Lua snapshots (l.progress or 0, etc.).
local function denull(v) return ns.DashboardData.Denull(v) end

-- Mythic 0 dungeon difficulty (id 23). M0 is the localized NAME (matches a saved M0 lock's difficulty
-- name); RaidDifficulty.MYTHIC_ZERO is the locale-proof difficulty id (stamped on seeded season-dungeon
-- entries). The enum is published in Lib/DashboardData.lua (loads before this collaborator).
local RaidDifficulty = ns.RaidDifficulty
local M0_ID = RaidDifficulty.MYTHIC_ZERO
local M0 = (GetDifficultyInfo and GetDifficultyInfo(M0_ID)) or "Mythic"

-- The current M+ season dungeon entry's label. Also used to DEDUPE the dungeon overview: the journal
-- exposes the current dungeons under a "Current Season" pseudo-tier, so a per-expansion tile carrying
-- this same label would just duplicate this entry (with no expansion logo) -- we drop it. (enUS, like
-- the rest of this module's journal labels.)
local SEASON_LABEL = "Current Season"

-- Raid difficulty ids CHECKED PER RAID against the journal (EJ_IsValidInstanceDifficulty), so a raid
-- is seeded ONLY the difficulties it actually offers -- not every raid has LFR or Mythic, and legacy
-- raids use 10/25/40-player ids. Built from the shared enum in this exact probe order.
local RD = RaidDifficulty
local RAID_DIFF_CANDIDATES = {
    RD.LFR, RD.RAID_FINDER, RD.LEGACY_10, RD.LEGACY_25, RD.LEGACY_40, RD.LEGACY_20,
    RD.NORMAL, RD.LEGACY_10_HEROIC, RD.LEGACY_25_HEROIC, RD.HEROIC, RD.MYTHIC,
}

-- The raid list's world-boss / world-event meta entries aren't real raids but carry no lockout. The
-- name==tier check in _ExpansionMap catches the ones named after the expansion; these are named after
-- the CONTINENT (Dragon Isles / Khaz Algar / Broken Isles) or a world EVENT (Legion's "Invasion
-- Points"), so map each to its tier to drop it too. (enUS, like the other journal labels.)
local WORLD_RAID_ALIASES = {
    ["Dragon Isles"]    = "Dragonflight",
    ["Khaz Algar"]      = "The War Within",
    ["Broken Isles"]    = "Legion",
    ["Invasion Points"] = "Legion",
}

-- The Encounter Journal crops its instance buttonImage1 art to this region (the rest is padding);
-- see Blizzard_EncounterJournal.xml "EncounterInstanceButtonTemplate" bgImage TexCoords. We reuse
-- it so our instance tiles fill the same way the journal's do (only used for the low-def banner
-- fallback, when an instance has no full-bleed scene).
local EJ_TILE_TC = { 0, 0.68359375, 0, 0.7421875 }
-- The banner crop lands on the art region but still carries a little padding, so we zoom in a touch
-- (zoom = fraction of the region shown; 0.8 = 20% in) to eat it. See Widgets.Texture for the model.
local EJ_TILE_ZOOM = 0.8
-- The instance SPLASH (loreImage) -- the big scene the journal shows on the RIGHT when you open an
-- instance. It's a 1024x1024 (square) file with the art in the top-left ~76% x 66%; the right and
-- bottom are transparent padding (the journal crops to {0,0.7617,0,0.65625}). The cover-fit treats
-- the whole square file, then we zoom in and pan UP-LEFT onto the art region. Zoom = fraction of the
-- fitted region shown (1.0 = as-is, <1 = zoom in, >1 = zoom out); pan is in texcoord units (- = up/left).
local EJ_LORE_ASPECT = 1
local EJ_LORE_ZOOM   = 0.65
local EJ_LORE_PAN_X  = -0.12
local EJ_LORE_PAN_Y  = -0.23

-- The CURRENT expansion's level. LE_EXPANSION_LEVEL_CURRENT is deprecated in Midnight, so prefer the
-- live getters (the displayable client max), falling back through to the old constant.
local function currentExpacLevel()
    return ns.DashboardData.CurrentExpacLevel(GetClientDisplayExpansionLevel, GetExpansionLevel, LE_EXPANSION_LEVEL_CURRENT)
end

-- The data-version domain of the ZONE CATALOG (the full uiMapID sweep below): rebuilt once per
-- patch, reconstructed from the persisted `zone` rows on a same-build login -- exactly like the
-- instance catalog. (Not via the VersioningOwner mixin -- that binds this module's ONE domain to
-- the instance catalog -- so this asks ns.Versioning directly.)
local ZONE_DOMAIN = "zone_catalog"

-- ---- zone typography styles -------------------------------------------------------------------
-- A zone WITHOUT its own loading screen renders as a TYPOGRAPHY tile: a two-stop gradient plate +
-- the zone name in the fantasy serif, coloured to evoke the place. Resolution order (_ZoneStyle):
--   1. ZONE_STYLE   -- hand-curated for the RECOGNISABLE zones (each researched: Elwynn's sunlit
--                      canopy, Durotar's red dust, Crystalsong's violet crystal, ...)
--   2. BIOME_STYLE  -- keyword inference from the name (Desert/Frost/Marsh/... -> biome palette)
--   3. expansion tint (EXP_STYLE) on the neutral plate
-- A style is { bg = {r,g,b} top, bg2 = {r,g,b} bottom, fg = {r,g,b} type } -- backgrounds stay
-- dark so tiles sit in the theme; the HUE carries the zone, the type colour carries the light.
local function zs(bg, bg2, fg) return { bg = bg, bg2 = bg2, fg = fg } end

local ZONE_STYLE = {
    -- Eastern Kingdoms / Kalimdor classics
    ["Elwynn Forest"]       = zs({0.10,0.18,0.08}, {0.04,0.09,0.03}, {0.95,0.85,0.55}),  -- sunlit canopy gold on green
    ["Westfall"]            = zs({0.24,0.18,0.08}, {0.12,0.08,0.03}, {0.95,0.82,0.50}),  -- wheat under harvest light
    ["Duskwood"]            = zs({0.05,0.07,0.05}, {0.01,0.02,0.01}, {0.70,0.78,0.62}),  -- lantern-pale in black forest
    ["Deadwind Pass"]       = zs({0.10,0.08,0.09}, {0.03,0.02,0.03}, {0.62,0.58,0.66}),  -- ashen storm over Karazhan
    ["Stranglethorn Vale"]  = zs({0.06,0.16,0.08}, {0.02,0.07,0.03}, {0.65,0.92,0.55}),  -- dense jungle leaf-light
    ["Durotar"]             = zs({0.26,0.10,0.05}, {0.12,0.04,0.02}, {0.95,0.70,0.45}),  -- red dust and dry sun
    ["Mulgore"]             = zs({0.20,0.16,0.06}, {0.08,0.08,0.03}, {0.95,0.85,0.60}),  -- golden plains
    ["The Barrens"]         = zs({0.22,0.16,0.08}, {0.10,0.07,0.03}, {0.92,0.78,0.52}),  -- savanna tan
    ["Tirisfal Glades"]     = zs({0.08,0.10,0.07}, {0.03,0.04,0.02}, {0.68,0.80,0.58}),  -- sickly forsaken green
    ["Ashenvale"]           = zs({0.06,0.10,0.14}, {0.02,0.04,0.07}, {0.70,0.85,0.95}),  -- moonlit silver-blue
    ["Felwood"]             = zs({0.08,0.12,0.04}, {0.03,0.05,0.01}, {0.60,0.95,0.35}),  -- corrupted fel glow
    ["Winterspring"]        = zs({0.14,0.18,0.26}, {0.06,0.08,0.14}, {0.92,0.96,1.00}),  -- snowfield night
    ["Tanaris"]             = zs({0.28,0.20,0.08}, {0.14,0.09,0.03}, {1.00,0.88,0.55}),  -- open desert glare
    ["Un'Goro Crater"]      = zs({0.07,0.15,0.06}, {0.03,0.06,0.02}, {0.70,0.95,0.50}),  -- primordial jungle
    ["Silithus"]            = zs({0.18,0.13,0.08}, {0.06,0.04,0.03}, {0.90,0.70,0.45}),  -- dusk sand, silithid dark
    -- Outland
    ["Hellfire Peninsula"]  = zs({0.24,0.07,0.04}, {0.10,0.02,0.01}, {1.00,0.55,0.30}),  -- fel-scorched red rock
    ["Zangarmarsh"]         = zs({0.04,0.13,0.14}, {0.01,0.05,0.06}, {0.55,0.95,0.90}),  -- giant mushroom glow
    ["Nagrand"]             = zs({0.09,0.16,0.09}, {0.03,0.07,0.04}, {0.75,0.95,0.70}),  -- floating-isle grassland
    ["Netherstorm"]         = zs({0.12,0.07,0.16}, {0.05,0.02,0.08}, {0.85,0.60,1.00}),  -- shattered arcane sky
    ["Shadowmoon Valley"]   = zs({0.08,0.06,0.12}, {0.03,0.02,0.06}, {0.75,0.70,0.95}),  -- night-violet moonglow
    -- Northrend
    ["Howling Fjord"]       = zs({0.06,0.13,0.13}, {0.02,0.05,0.06}, {0.65,0.92,0.88}),  -- deep teal fjord
    ["Grizzly Hills"]       = zs({0.18,0.12,0.05}, {0.08,0.05,0.02}, {0.95,0.70,0.40}),  -- autumn timber amber
    ["Dragonblight"]        = zs({0.16,0.19,0.23}, {0.07,0.09,0.12}, {0.90,0.94,1.00}),  -- bone-white snowfield
    ["Crystalsong Forest"]  = zs({0.11,0.08,0.18}, {0.04,0.03,0.09}, {0.85,0.75,1.00}),  -- violet crystal trees
    ["Icecrown"]            = zs({0.08,0.11,0.17}, {0.02,0.04,0.08}, {0.80,0.92,1.00}),  -- cold steel and saronite
    ["The Storm Peaks"]     = zs({0.08,0.10,0.16}, {0.03,0.04,0.08}, {0.85,0.90,1.00}),  -- titan night-blue
    ["Sholazar Basin"]      = zs({0.08,0.16,0.07}, {0.03,0.07,0.02}, {0.75,0.98,0.55}),  -- lifebloom jungle
    -- Cataclysm
    ["Mount Hyjal"]         = zs({0.10,0.14,0.06}, {0.05,0.05,0.02}, {1.00,0.65,0.35}),  -- green crown, ember edge
    ["Uldum"]               = zs({0.26,0.20,0.10}, {0.11,0.08,0.04}, {0.55,0.80,1.00}),  -- gold sand, lapis accents
    ["Deepholm"]            = zs({0.10,0.09,0.12}, {0.04,0.03,0.05}, {0.80,0.65,1.00}),  -- amethyst stone heart
    ["Twilight Highlands"]  = zs({0.12,0.09,0.13}, {0.05,0.03,0.06}, {0.85,0.70,0.95}),  -- twilight dragon dusk
    -- Pandaria
    ["The Jade Forest"]     = zs({0.06,0.15,0.10}, {0.02,0.06,0.04}, {0.60,0.95,0.75}),  -- jade mist
    ["Valley of the Four Winds"] = zs({0.18,0.16,0.06}, {0.08,0.07,0.02}, {0.98,0.88,0.55}), -- golden grain
    ["Kun-Lai Summit"]      = zs({0.15,0.18,0.22}, {0.06,0.08,0.11}, {0.95,0.97,1.00}),  -- white summit air
    ["Dread Wastes"]        = zs({0.08,0.11,0.06}, {0.03,0.04,0.02}, {0.70,0.90,0.50}),  -- mantid amber-green
    -- Draenor
    ["Frostfire Ridge"]     = zs({0.16,0.10,0.10}, {0.06,0.03,0.04}, {1.00,0.60,0.35}),  -- lava through snow
    ["Talador"]             = zs({0.18,0.14,0.07}, {0.08,0.06,0.03}, {0.98,0.85,0.55}),  -- autumn gold arakkoa light
    ["Spires of Arak"]      = zs({0.12,0.08,0.12}, {0.05,0.03,0.05}, {0.95,0.75,0.45}),  -- dusk cliffs, amber sky
    ["Gorgrond"]            = zs({0.10,0.13,0.06}, {0.04,0.05,0.02}, {0.75,0.90,0.50}),  -- overgrowth vs iron
    -- Legion
    ["Azsuna"]              = zs({0.06,0.11,0.16}, {0.02,0.04,0.08}, {0.55,0.85,1.00}),  -- azure ley-ruins
    ["Val'sharah"]          = zs({0.07,0.14,0.08}, {0.02,0.06,0.03}, {0.65,0.95,0.65}),  -- emerald dream edge
    ["Highmountain"]        = zs({0.14,0.11,0.07}, {0.06,0.04,0.02}, {0.90,0.75,0.50}),  -- tauren stone and pine
    ["Stormheim"]           = zs({0.10,0.12,0.14}, {0.04,0.05,0.06}, {0.78,0.88,0.95}),  -- vrykul storm cliffs
    ["Suramar"]             = zs({0.12,0.06,0.16}, {0.05,0.02,0.08}, {0.95,0.60,1.00}),  -- nightborne arcwine glow
    -- Battle for Azeroth
    ["Tiragarde Sound"]     = zs({0.07,0.10,0.14}, {0.02,0.04,0.06}, {0.90,0.80,0.55}),  -- harbour brass on navy
    ["Drustvar"]            = zs({0.10,0.11,0.11}, {0.04,0.04,0.04}, {0.88,0.90,0.92}),  -- witch-fog and bone
    ["Stormsong Valley"]    = zs({0.08,0.13,0.11}, {0.03,0.05,0.04}, {0.70,0.92,0.85}),  -- tidesage green-blue
    ["Zuldazar"]            = zs({0.14,0.12,0.04}, {0.06,0.05,0.02}, {0.98,0.85,0.45}),  -- golden troll empire
    ["Nazmir"]              = zs({0.07,0.10,0.08}, {0.02,0.04,0.03}, {0.60,0.85,0.70}),  -- blood-swamp mist
    ["Vol'dun"]             = zs({0.24,0.17,0.09}, {0.11,0.07,0.03}, {0.98,0.82,0.55}),  -- exile desert
    ["Nazjatar"]            = zs({0.04,0.09,0.14}, {0.01,0.03,0.06}, {0.50,0.90,0.95}),  -- abyssal naga deep
    -- Shadowlands
    ["Bastion"]             = zs({0.14,0.16,0.20}, {0.06,0.07,0.10}, {0.95,0.90,0.70}),  -- kyrian white-gold
    ["Maldraxxus"]          = zs({0.08,0.11,0.05}, {0.03,0.04,0.01}, {0.70,0.95,0.40}),  -- necropolis bile-green
    ["Ardenweald"]          = zs({0.05,0.08,0.15}, {0.02,0.03,0.07}, {0.60,0.80,1.00}),  -- star-lit faerie blue
    ["Revendreth"]          = zs({0.12,0.05,0.06}, {0.05,0.01,0.02}, {0.95,0.45,0.45}),  -- venthyr crimson gothic
    ["Zereth Mortis"]       = zs({0.15,0.15,0.13}, {0.07,0.07,0.06}, {0.95,0.92,0.75}),  -- progenitor pearl-gold
    -- Dragonflight
    ["The Waking Shores"]   = zs({0.18,0.08,0.05}, {0.08,0.03,0.02}, {1.00,0.60,0.35}),  -- volcanic dragonfire
    ["Ohn'ahran Plains"]    = zs({0.10,0.15,0.08}, {0.04,0.06,0.03}, {0.80,0.95,0.65}),  -- windswept centaur grass
    ["The Azure Span"]      = zs({0.07,0.11,0.16}, {0.02,0.04,0.08}, {0.60,0.85,1.00}),  -- blue frost-forest
    ["Thaldraszus"]         = zs({0.14,0.11,0.07}, {0.06,0.04,0.02}, {0.95,0.78,0.45}),  -- bronze titan stone
    ["The Emerald Dream"]   = zs({0.06,0.14,0.07}, {0.02,0.06,0.02}, {0.60,1.00,0.60}),  -- vivid dream green
    -- The War Within
    ["Isle of Dorn"]        = zs({0.13,0.14,0.08}, {0.05,0.06,0.03}, {0.95,0.85,0.55}),  -- mediterranean earthen gold
    ["The Ringing Deeps"]   = zs({0.09,0.07,0.05}, {0.03,0.02,0.01}, {1.00,0.70,0.35}),  -- machine-amber in the dark
    ["Hallowfall"]          = zs({0.10,0.13,0.18}, {0.04,0.05,0.09}, {1.00,0.85,0.55}),  -- Beledar's light in cavern dusk
    ["Azj-Kahet"]           = zs({0.09,0.06,0.11}, {0.03,0.02,0.05}, {0.80,0.60,0.95}),  -- web-violet nerubian dark
    -- Midnight
    ["Eversong Woods"]      = zs({0.16,0.11,0.05}, {0.07,0.04,0.02}, {1.00,0.80,0.45}),  -- radiant autumn-spring gold
    ["Zul'Aman"]            = zs({0.07,0.13,0.07}, {0.02,0.05,0.02}, {0.85,0.95,0.55}),  -- amani rainforest
    ["Harandar"]            = zs({0.06,0.10,0.12}, {0.02,0.04,0.05}, {0.55,0.95,0.85}),  -- bioluminescent fungal roots
    ["Voidstorm"]           = zs({0.09,0.05,0.13}, {0.03,0.01,0.06}, {0.80,0.50,1.00}),  -- void gorges and pylons
    ["Naigtal"]             = zs({0.08,0.06,0.12}, {0.03,0.02,0.05}, {0.70,0.60,1.00}),  -- fungal-arcane haze
    ["Val"]                 = zs({0.12,0.14,0.18}, {0.05,0.06,0.08}, {0.85,0.92,1.00}),  -- frozen legion wasteland
}

-- Biome inference for everything not curated: the FIRST keyword hit (checked in order, darkest
-- moods before generic terrain so "Deadwood Forest" reads dark, not forest) picks the palette.
local BIOME_STYLE = {
    dark     = zs({0.07,0.07,0.08}, {0.02,0.02,0.03}, {0.72,0.74,0.70}),
    volcanic = zs({0.20,0.08,0.04}, {0.09,0.03,0.01}, {1.00,0.60,0.32}),
    snow     = zs({0.13,0.16,0.22}, {0.05,0.07,0.11}, {0.92,0.96,1.00}),
    desert   = zs({0.25,0.18,0.08}, {0.11,0.08,0.03}, {0.98,0.84,0.52}),
    swamp    = zs({0.07,0.11,0.08}, {0.02,0.04,0.03}, {0.62,0.88,0.70}),
    jungle   = zs({0.06,0.14,0.07}, {0.02,0.06,0.02}, {0.68,0.95,0.50}),
    forest   = zs({0.08,0.14,0.07}, {0.03,0.06,0.02}, {0.85,0.92,0.60}),
    coast    = zs({0.06,0.10,0.15}, {0.02,0.04,0.07}, {0.60,0.88,0.95}),
    mountain = zs({0.13,0.11,0.08}, {0.05,0.04,0.03}, {0.88,0.78,0.58}),
    plains   = zs({0.15,0.14,0.06}, {0.06,0.06,0.02}, {0.95,0.88,0.58}),
    arcane   = zs({0.10,0.06,0.15}, {0.04,0.02,0.07}, {0.85,0.65,1.00}),
}
local BIOME_WORDS = {
    { "dark",     { "shadow", "dusk", "dark", "dread", "dead", "grim", "blight", "plague", "maw" } },
    { "volcanic", { "fire", "molten", "burning", "cinder", "searing", "lava", "crater", "scorch" } },
    { "snow",     { "frost", "ice", "winter", "snow", "glacier", "tundra", "chill" } },
    { "desert",   { "desert", "sand", "dune", "waste", "scarab", "sun" } },
    { "swamp",    { "marsh", "swamp", "bog", "mire", "fen" } },
    { "jungle",   { "jungle", "wilds", "basin", "thorn" } },
    { "forest",   { "forest", "wood", "grove", "glade", "vale" } },
    { "coast",    { "isle", "island", "shore", "coast", "bay", "sea", "tide", "reef", "depth", "sound" } },
    { "mountain", { "mount", "peak", "ridge", "highland", "cliff", "summit", "crag", "spire" } },
    { "plains",   { "plain", "steppe", "field", "meadow", "prairie" } },
    { "arcane",   { "crystal", "arcane", "moon", "star", "storm", "void", "nether" } },
}

-- The neutral plate the expansion tint colours when neither curation nor biome matches.
local PLATE_BG, PLATE_BG2 = { 0.08, 0.10, 0.14 }, { 0.04, 0.05, 0.08 }

-- Typography palette: each expansion's signature colour -- the zone plate's LAST-RESORT tint when
-- neither curation nor biome matches (keyed by expansion level == EJ tier level).
local EXP_STYLE = {
    [0]  = { 0.85, 0.71, 0.38 },   -- Classic: aged gold / parchment
    [1]  = { 0.55, 0.85, 0.35 },   -- Burning Crusade: fel green
    [2]  = { 0.55, 0.78, 0.95 },   -- Wrath: glacial blue
    [3]  = { 0.95, 0.45, 0.15 },   -- Cataclysm: molten orange
    [4]  = { 0.35, 0.80, 0.55 },   -- Mists: jade
    [5]  = { 0.80, 0.50, 0.25 },   -- Draenor: savage bronze
    [6]  = { 0.45, 0.90, 0.30 },   -- Legion: fel
    [7]  = { 0.30, 0.55, 0.90 },   -- Battle for Azeroth: war-sea navy
    [8]  = { 0.78, 0.86, 1.00 },   -- Shadowlands: pale anima
    [9]  = { 0.90, 0.65, 0.30 },   -- Dragonflight: dragon bronze
    [10] = { 0.95, 0.75, 0.40 },   -- The War Within: earthen gold
    [11] = { 0.70, 0.45, 0.95 },   -- Midnight: void violet
}
local EXP_STYLE_DEFAULT = { 0.85, 0.80, 0.65 }

-- The modern flexible RAID difficulties (ids), used to seed one catalog row per raid per difficulty.
-- Resolved to LOCALE names via GetDifficultyInfo so a row's `diff` matches a lockout's difficulty
-- name (which is likewise derived from its id in CharacterStore:CollectLockouts).
local RAID_DIFF_IDS = { RD.RAID_FINDER, RD.NORMAL, RD.HEROIC, RD.MYTHIC }   -- Raid Finder, Normal, Heroic, Mythic

-- Populate dashboard_instance with the full catalog the dashboard shows -- every raid (one row per
-- difficulty) and the latest expansion's + current season's dungeons -- and drop rows whose instance
-- or difficulty no longer exists. The whole catalog (journal walk, seed, prune, season, keystone) is
-- static within a client, so it builds exactly ONCE per session. The only reason a pass can repeat is
-- readiness: the journal must have loaded AND the M+ season pool must have finalised (it can lag login
-- a moment); until both are ready `catalogBuilt` stays false and a later trigger retries. After that
-- it's a cheap no-op -- zone changes never rebuild it.
function ExpansionCatalog:_BuildCatalog()
    local p = self:_p()
    if p.catalogBuilt then return end    -- built once per session
    self:_ExpansionMap()                 -- reconstruct from the DB cache, OR walk the journal (new patch)
    if not p.ejInst then return end      -- journal not ready yet -- retry on the next trigger
    -- The heavy raid/dungeon seed + prune only run on the WALK path (a new patch / first run). A
    -- same-patch login reconstructs the maps from the catalog, which is already correct -- nothing to seed.
    if not p.seededCatalog and not p.ejReconstructed then
        self:_SeedInstances()            -- one row per (journal instance, difficulty) + its art / order
        self:_PruneInstances()           -- drop instances/difficulties Blizzard removed + legacy name-keyed rows
        p.seededCatalog = true
    end
    self:_SeedSeasonDungeons()           -- current M+ season pool (cheap; the M+ rotation is live, not journal)
    self:_MarkSeasonFlags()              -- refresh current_season after the prune has cleared orphans
    self:_p().charStore:SeedKeystones()                -- fill local keystone names for every alt's stored map id
    if self:_SeasonDungeons() then
        p.catalogBuilt = true                                  -- done once the M+ season pool is available
        self:_p().owner:StampVersion()                                    -- next same-build login reconstructs, no re-walk
    end
end

-- Rebuild the runtime journal maps (p.ejInst / ejByName / ejImage / ejLore / ejRaidsByTier / ... ) from
-- the PERSISTED catalog instead of walking the Encounter Journal -- no LoadAddOn, no EJ_* calls. Used on
-- a normal login: the catalog is static within a patch, so once it's saved we just read it back. On an
-- empty or pre-art catalog it bails WITHOUT setting p.ejInst (returns false) -- the caller commits to the
-- cache with no re-walk, so an incomplete cache renders nothing (a visible failure, not a silent re-walk).
function ExpansionCatalog:_ReconstructFromDB()
    local p = self:_p()
    ns.Worker:Mark("reconstruct catalog")
    local db = self:DB(); if not db then return false end
    local rows = db:Select("*"):From("dashboard_instance"):Run()
    if #rows == 0 then return false end
    local inst, byName, image, lore, raidDiffs = {}, {}, {}, {}, {}
    local raidsByTier, dungeonsByTier, season, seasonList, ordOf = {}, {}, {}, {}, {}
    local haveArt = false
    for _, r in ipairs(rows) do
        local id = denull(r.instance_id)
        if id then
            local name, isRaid, tier = denull(r.name), denull(r.is_raid) and true or false, denull(r.expansion)
            if not inst[id] then
                inst[id] = { id = id, name = name, tier = tier, isRaid = isRaid }
                byName[name] = byName[name] or {}; byName[name][#byName[name] + 1] = id
                ordOf[id] = denull(r.ord) or 0
                local li, bi = denull(r.lore_id), denull(r.button_id)
                if li and name then lore[name] = li; haveArt = true end
                if bi and name then image[name] = bi end
                if tier then
                    local b = isRaid and raidsByTier or dungeonsByTier
                    b[tier] = b[tier] or {}; b[tier][#b[tier] + 1] = id
                end
                if isRaid and denull(r.current_season) then season[id] = true; seasonList[#seasonList + 1] = id end
            end
            local did = denull(r.diff_id)
            if isRaid and did then raidDiffs[id] = raidDiffs[id] or {}; raidDiffs[id][#raidDiffs[id] + 1] = did end
        end
        ns.Worker:MaybeYield()                  -- whole-catalog walk: chunk to the pump budget
    end
    if not haveArt then return false end                       -- pre-art catalog -> re-walk to fill it in
    local byOrd = function(a, b) return (ordOf[a] or 0) < (ordOf[b] or 0) end
    for _, list in pairs(raidsByTier)    do table.sort(list, byOrd) end
    for _, list in pairs(dungeonsByTier) do table.sort(list, byOrd) end
    table.sort(seasonList, byOrd)
    local tierLevel, tierOrder = {}, {}
    for _, e in ipairs(db:Select("name", "level"):From("expansion"):Run()) do
        local nm = denull(e.name); if nm then tierLevel[nm] = denull(e.level) end
    end
    for nm in pairs(tierLevel) do tierOrder[#tierOrder + 1] = nm end
    table.sort(tierOrder, function(a, b) return (tierLevel[a] or -1) > (tierLevel[b] or -1) end)
    p.ejInst, p.ejByName, p.ejImage, p.ejLore = inst, byName, image, lore
    p.ejRaidsByTier, p.ejDungeonsByTier, p.ejRaidDiffs = raidsByTier, dungeonsByTier, raidDiffs
    p.ejSeasonRaids, p.ejSeasonRaidList = season, seasonList
    p.ejTierLevel, p.ejTierOrder = tierLevel, tierOrder
    -- current expansion = the tier owning the newest raids (highest level among raid-having tiers),
    -- recomputed from the rebuilt maps exactly as the walk does -- so it need not be persisted.
    local curTier, curLvl
    for tier in pairs(raidsByTier) do
        local l = tierLevel[tier]
        if l and (not curLvl or l > curLvl) then curTier, curLvl = tier, l end
    end
    p.currentExpansion = curTier or tierOrder[1]
    p.ejReconstructed = true
    return true
end

-- ---- expansion mapping (Encounter Journal) --------------------------------
-- Map a raid NAME -> its expansion by walking the Encounter Journal tiers (one tier per
-- expansion). Built lazily and cached on first success; name-matching is locale-consistent
-- within a client. A raid the journal doesn't list (or before the journal data loads) resolves
-- to "Other". The reference addons hand-curate this; we derive it dynamically instead.
function ExpansionCatalog:_ExpansionMap()
    local p = self:_p()
    if p.ejInst then return p.ejInst end
    -- CACHE PATH: this patch's catalog is already saved -> rebuild the maps from the DB and COMMIT to it.
    -- No fallback to a re-walk: if the saved catalog is empty/incomplete the dashboard renders nothing,
    -- which surfaces a broken cache instead of silently masking it with an expensive re-walk. The walk
    -- below runs only on the FIRST build ever / after a NEW patch (no stamp, or stamp.build mismatched).
    if self:_p().owner:IsVersionCurrent() then
        self:_ReconstructFromDB()
        return p.ejInst
    end
    p.ejReconstructed = false
    if not (EJ_GetNumTiers and EJ_SelectTier and EJ_GetInstanceByIndex and EJ_GetTierInfo) then return nil end
    ns.Worker:Mark("load Blizzard_EncounterJournal")   -- synchronous addon load: the one unavoidable big step
    if C_AddOns and C_AddOns.LoadAddOn then pcall(C_AddOns.LoadAddOn, "Blizzard_EncounterJournal") end
    ns.Worker:MaybeYield()                             -- the load likely spent the budget: fresh pump for the walk
    ns.Worker:Mark("journal walk")
    -- Instances are tracked by their EJ journal INSTANCE ID, not their name -- two distinct journal
    -- instances can share a name (e.g. a Burning Crusade dungeon and a reworked current-season one),
    -- and only the id keeps them apart with their own home expansion. Art stays keyed by NAME (a shared
    -- picture for same-named instances is harmless; the journal exposes art per name).
    local inst, byName = {}, {}            -- id -> { id, name, tier(home), isRaid } ; name -> { ids, newest first }
    local raidsByTier, dungeonsByTier, tierOrder, found = {}, {}, {}, false
    local tierLevel = {}   -- tier name -> expansionLevel (EJ tier index 1 = Classic = expansion 0)
    local image, lore = {}, {}             -- instance NAME -> EJ buttonImage1 / loreImage
    local prev = EJ_GetCurrentTier and EJ_GetCurrentTier()
    local function walk(tier, tierName, isRaid, sink, isSeason)
        EJ_SelectTier(tier)                   -- can load tier data (a hitchy C call) ...
        ns.Worker:MaybeYield()                -- ... so offer the frame back before iterating it
        local i = 1
        while true do
            local instID, name, _, _, buttonImage, loreImage = EJ_GetInstanceByIndex(i, isRaid)
            if not instID then break end
            if name == "Keystone Dungeons" then name = nil end   -- dungeon meta-entry, never a real instance
            -- Drop the RAID list's world-boss "meta" entry (no weekly lockout). On a normal tier it's
            -- named after the expansion (e.g. "Pandaria", "Draenor", "Midnight") -- matched exactly,
            -- by trailing word for long names ("Mists of Pandaria" -> "Pandaria"), or by continent /
            -- world-event alias (WORLD_RAID_ALIASES). On the "Current Season" tier it's named after the
            -- LIVE expansion instead, so match that there.
            if isRaid and name then
                if isSeason then
                    local cur = self:_CurrentExpansionName()
                    if cur and (name == cur or WORLD_RAID_ALIASES[name] == cur) then name = nil end
                elseif tierName and (name == tierName or tierName:match("(%S+)%s*$") == name
                                     or WORLD_RAID_ALIASES[name] == tierName) then
                    name = nil
                end
            end
            if name then
                if buttonImage and not image[name] then image[name] = buttonImage end
                if loreImage  and not lore[name]  then lore[name]  = loreImage  end
                local rec = inst[instID]
                if not rec then
                    rec = { id = instID, name = name, isRaid = isRaid and true or false }
                    inst[instID] = rec
                    byName[name] = byName[name] or {}
                    byName[name][#byName[name] + 1] = instID         -- walked newest-first => newest id first
                end
                if not isSeason and tierName then
                    rec.tier = tierName; found = true                -- last write wins => OLDEST tier = home
                end
                if sink then sink[#sink + 1] = instID end
            end
            i = i + 1
            ns.Worker:MaybeYield()                -- spread the walk across frames (Worker-budgeted build)
        end
    end
    local seasonRaidList = {}                 -- ids of raids on the journal's "Current Season" page
    for tier = EJ_GetNumTiers(), 1, -1 do   -- newest tier first
        local tierName = EJ_GetTierInfo(tier)
        -- "World Raids" is a cross-expansion world-boss bucket, not a real expansion -- drop it.
        if tierName == "World Raids" then tierName = nil end
        if tierName == SEASON_LABEL then
            -- The "Current Season" tier is a journal PAGE, not an expansion: record which raids are in
            -- the live season (its world-boss entry dropped) but skip the tier/expansion bookkeeping --
            -- those raids keep their real home expansion (set when their own tier is walked) plus a flag.
            walk(tier, tierName, true, seasonRaidList, true)
            tierName = nil
        end
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
    -- Which difficulties each raid ACTUALLY offers (the journal's truth, keyed by instance id) -- so
    -- seeding skips an LFR / Mythic a raid never had, and legacy raids get their 10/25/40-player ids.
    -- The per-raid EJ_SelectInstance probe is the heaviest step and its result only changes across
    -- PATCHES. We only ever reach this WALK path on a first run / a new patch (a same-patch login
    -- reconstructs from the DB above and never gets here), so probe every raid -- the result is then
    -- persisted and reused until the next patch.
    local raidDiffs = {}
    ns.Worker:Mark("raid difficulty probe")
    if EJ_SelectInstance and EJ_IsValidInstanceDifficulty then
        for id, rec in pairs(inst) do
            if rec.isRaid then
                pcall(EJ_SelectInstance, id)
                local ids = {}
                for _, d in ipairs(RAID_DIFF_CANDIDATES) do if EJ_IsValidInstanceDifficulty(d) then ids[#ids + 1] = d end end
                if #ids > 0 then raidDiffs[id] = ids end
                ns.Worker:MaybeYield()
            end
        end
    end
    if prev then pcall(EJ_SelectTier, prev) end   -- restore the journal's selected tier
    if found then
        p.ejInst = inst                       -- id -> { id, name, tier, isRaid } (the identity record)
        p.ejByName = byName                   -- name -> { ids, newest first } (resolve season/lockout names)
        p.ejRaidsByTier = raidsByTier         -- tier -> { instance ids } (journal order)
        p.ejDungeonsByTier = dungeonsByTier   -- tier -> { instance ids }
        p.ejTierOrder = tierOrder             -- tiers with raids, newest first
        p.ejTierLevel = tierLevel             -- tier name -> expansionLevel (for native logos)
        p.ejImage = image                     -- instance NAME -> EJ tile art (buttonImage1; banner fallback)
        p.ejLore = lore                       -- instance NAME -> EJ splash (loreImage; preferred art)
        -- journal order per instance (index within its tier), persisted so reconstruction can re-sort tiles
        local ord = {}
        for _, ids in pairs(raidsByTier)    do for i2, id2 in ipairs(ids) do ord[id2] = i2 end end
        for _, ids in pairs(dungeonsByTier) do for i2, id2 in ipairs(ids) do ord[id2] = i2 end end
        p.ejOrd = ord
        p.ejSeasonRaidList = seasonRaidList   -- season raid ids, newest tier first (tile order)
        local seasonSet = {}
        for _, id in ipairs(seasonRaidList) do seasonSet[id] = true end
        p.ejSeasonRaids = seasonSet           -- instance id -> true for the live season's raids
        p.ejRaidDiffs = raidDiffs             -- instance id -> { difficulty ids it actually offers }
        self:_SeedExpansions()                -- materialise the expansion FK targets now the tier levels are known
        -- The CURRENT raid tier is the expansion that OWNS the newest raids -- the newest home tier
        -- across all raids (a new tier can re-list the prior expansion's raids before its own ship).
        local curTier, curLvl
        for _, rec in pairs(inst) do
            if rec.isRaid and rec.tier then
                local l = tierLevel[rec.tier]
                if l and (not curLvl or l > curLvl) then curTier, curLvl = rec.tier, l end
            end
        end
        p.currentExpansion = curTier or tierOrder[1] or EJ_GetTierInfo(EJ_GetNumTiers())
    end
    return p.ejInst
end

-- Newest journal instance id recorded for a name (instances are stored newest-tier-first), or nil.
function ExpansionCatalog:_IdForName(name)
    local b = self:_p().ejByName
    local ids = name and b and b[name]
    return ids and ids[1] or nil
end

-- The home expansion of the (newest) journal instance with this name; "Other" until the map is built.
function ExpansionCatalog:_InstanceExpansion(name)
    local id = self:_IdForName(name)
    local rec = id and self:_p().ejInst and self:_p().ejInst[id]
    return (rec and rec.tier) or "Other"
end

-- Seed the expansion registry from the journal tier levels: one row per tier with the banner logo
-- (a fileID from GetExpansionDisplayInfo) the tiles display. Insert-if-missing; runs the moment the
-- map is built so the dashboard_instance.expansion FK target always exists before any instance seeds.
function ExpansionCatalog:_SeedExpansions()
    local db = self:DB(); if not db then return end
    for name, level in pairs(self:_p().ejTierLevel or {}) do
        if not db:Select("name"):From("expansion"):Where("name", "=", name):Limit(1):Run()[1] then
            local info = GetExpansionDisplayInfo and GetExpansionDisplayInfo(level)
            local logo = info and info.logo
            db:Insert("expansion", { name = name, level = level,
                logo = (type(logo) == "number") and logo or ns.DB.NULL })
        end
    end
end

-- The native expansion banner texture for a tier (the icon WoW ships per expansion), or nil. Reads
-- the stored fileID from the expansion table (the registry the tiles are driven from); falls back to
-- the live GetExpansionDisplayInfo(expansionLevel) before the registry is seeded.
function ExpansionCatalog:_ExpansionLogo(tierName)
    local db = self:DB()
    if db then
        local r = db:Select("logo"):From("expansion"):Where("name", "=", tierName):Limit(1):Run()[1]
        local logo = r and denull(r.logo)
        if logo then return logo end
    end
    local lvl = self:_p().ejTierLevel and self:_p().ejTierLevel[tierName]
    if not (lvl and GetExpansionDisplayInfo) then return nil end
    local info = GetExpansionDisplayInfo(lvl)
    return info and info.logo or nil
end

-- The current expansion's display name (e.g. "The War Within"), from the game's expansion strings, or
-- nil. EXPANSION_NAME<level> is the localized name Blizzard also uses for the journal's tier label.
function ExpansionCatalog:_CurrentExpansionName()
    local lvl = currentExpacLevel()
    local n = lvl and _G["EXPANSION_NAME" .. lvl]
    return (n and n ~= "") and n or nil
end

-- The current expansion's emblem texture (the same picture the raid tiles use), or nil.
function ExpansionCatalog:_CurrentExpansionLogo()
    local lvl = currentExpacLevel()
    local info = lvl and GetExpansionDisplayInfo and GetExpansionDisplayInfo(lvl)
    return info and info.logo or nil
end

-- The Encounter Journal DUNGEON tier for the current EXPANSION -- i.e. every dungeon released in it,
-- which is a SUPERSET of (and distinct from) the "Current Season" M+ subset. Found by the expansion's
-- name (the journal names that tier after the expansion); if the name doesn't line up, fall back to
-- the dungeon tier whose journal level matches the current expansion level. nil if none is found.
function ExpansionCatalog:_CurrentExpansionTier()
    local p = self:_p()
    local dbt = p.ejDungeonsByTier
    if not dbt then return nil end
    local name = self:_CurrentExpansionName()
    if name and dbt[name] then return name end
    local lvl = currentExpacLevel()
    if lvl and p.ejTierLevel then
        for tierName in pairs(dbt) do
            if tierName ~= SEASON_LABEL and p.ejTierLevel[tierName] == lvl then return tierName end
        end
    end
    return nil
end

-- An art descriptor for an instance tile. Prefer the big SPLASH (loreImage) -- the scene the journal
-- shows on the right when you open the instance -- cover-fitted + zoomed/panned onto its art region.
-- The low-def buttonImage1 banner is only a fallback (cropped + zoomed) for an instance with no splash.
-- Per-kind ("raid"/"dungeon") cover zoom + pan for the splash, seeded from the code defaults. These
-- are RUNTIME (per session): the Dev module live-tunes them via SetArtTune; they reset to the
-- EJ_LORE_* defaults every load. On a normal character nothing changes them, so the art is identical.
function ExpansionCatalog:_ArtTune(kind)
    local p = self:_p()
    if not p.artTune then
        p.artTune = {
            raid    = { zoom = EJ_LORE_ZOOM, panX = EJ_LORE_PAN_X, panY = EJ_LORE_PAN_Y },
            dungeon = { zoom = EJ_LORE_ZOOM, panX = EJ_LORE_PAN_X, panY = EJ_LORE_PAN_Y },
        }
    end
    return p.artTune[kind] or p.artTune.dungeon
end

-- Read / live-update the splash art tuning for a kind. SetArtTune re-renders if the Dashboard is open
-- so a Dev slider drag is reflected immediately. field is "zoom" | "panX" | "panY".
function ExpansionCatalog:GetArtTune(kind) return self:_ArtTune(kind) end

function ExpansionCatalog:SetArtTune(kind, field, value)
    self:_ArtTune(kind)[field] = value
end

function ExpansionCatalog:_InstanceArt(name, kind)
    local p = self:_p()
    if not name then return nil end
    if p.ejLore and p.ejLore[name] then
        local t = self:_ArtTune(kind or "dungeon")
        return { texture = p.ejLore[name], cover = true, aspect = EJ_LORE_ASPECT,
                 zoom = t.zoom, panX = t.panX, panY = t.panY }
    end
    if p.ejImage and p.ejImage[name] then return { texture = p.ejImage[name], texCoord = EJ_TILE_TC, zoom = EJ_TILE_ZOOM } end
    return nil
end

-- The last (newest) raid / dungeon in the current expansion's catalog -- the picture used for the
-- current-tier tile, so it shows the real instance art instead of the generic expansion logo.
function ExpansionCatalog:_LatestRaidArt()
    local p = self:_p()
    local r = p.ejRaidsByTier and p.currentExpansion and p.ejRaidsByTier[p.currentExpansion]
    local rec = r and r[#r] and p.ejInst and p.ejInst[r[#r]]
    if rec then return self:_InstanceArt(rec.name, "raid") end
end

function ExpansionCatalog:_LatestDungeonArt()
    local p = self:_p()
    local d = p.ejDungeonsByTier and p.currentExpansion and p.ejDungeonsByTier[p.currentExpansion]
    local rec = d and d[#d] and p.ejInst and p.ejInst[d[#d]]
    if rec then return self:_InstanceArt(rec.name, "dungeon") end
end

-- Season dungeons that actually have art, in season order -- the pool the Current Season tile draws
-- from (and the Dev "next dungeon" button steps through). Cached once the journal map is ready.
function ExpansionCatalog:_SeasonArtPool()
    local p = self:_p()
    if p.seasonPool then return p.seasonPool end
    local s = self:_SeasonDungeons()
    if not s then return nil end
    local cand = {}
    for _, name in ipairs(s.list) do
        if (p.ejLore and p.ejLore[name]) or (p.ejImage and p.ejImage[name]) then cand[#cand + 1] = name end
    end
    if #cand == 0 then return nil end
    p.seasonPool = cand
    return cand
end

-- A current-season dungeon's art for the Current Season tile. Starts on a RANDOM one, then sticks to
-- whatever the Dev "next dungeon" button last stepped to (p.seasonIdx).
function ExpansionCatalog:_SeasonDungeonArt()
    local p = self:_p()
    local pool = self:_SeasonArtPool()
    if not pool then return nil end
    if not p.seasonIdx then p.seasonIdx = math.random(#pool) end
    return self:_InstanceArt(pool[p.seasonIdx], "dungeon")
end

-- Dev tooling: step the Current Season tile to the NEXT season dungeon's image (wraps), so every
-- dungeon's splash can be inspected/tuned. Returns the now-showing dungeon name, or nil if no pool.
function ExpansionCatalog:NextSeasonDungeon()
    local pool = self:_SeasonArtPool()
    if not pool then return nil end
    local p = self:_p()
    p.seasonIdx = ((p.seasonIdx or 0) % #pool) + 1
    return pool[p.seasonIdx]
end

-- The dungeon name currently shown on the Current Season tile (for the Dev panel's readout), or nil.
function ExpansionCatalog:CurrentSeasonDungeon()
    local pool = self:_SeasonArtPool()
    if not (pool and self:_p().seasonIdx) then return nil end
    return pool[self:_p().seasonIdx]
end

-- Distinct expansions in the registry for one kind (raids if wantRaid, else dungeons), ordered by
-- EXPANSION RELEASE DATE -- newest first, like the raid list -- via the journal tier level. Tiers with
-- no known level (e.g. "Other") sort last, then alphabetically. Persists: an expansion stays listed
-- once anything in it is known.
function ExpansionCatalog:_KnownExpansions(wantRaid)
    local set = {}
    for _, r in pairs(self:_p().charStore:Instances()) do
        if r.isRaid == wantRaid then set[r.expansion or "Other"] = true end
    end
    local lvl = self:_p().ejTierLevel or {}
    local list = {}
    for exp in pairs(set) do list[#list + 1] = exp end
    table.sort(list, function(a, b)
        local la, lb = lvl[a], lvl[b]
        if la and lb then if la ~= lb then return la > lb end return a < b end
        if la ~= lb then return la ~= nil end   -- a known-level tier sorts before an unknown one
        return a < b
    end)
    return list
end

-- ---- raids: the FULL catalog (every raid has a weekly lockout, so show them all) -----------
-- Raid tiers, newest first -- now read from the seeded dashboard_instance catalog (not the live
-- journal), so the nav reflects exactly what's in the table.
function ExpansionCatalog:_RaidExpansions()
    return self:_KnownExpansions(true)
end

-- Distinct instances in a catalog group, as { id, name } descriptors, NEWEST FIRST. `pred(entry)`
-- selects the rows; `orderList` (journal order of instance ids, oldest->newest) positions them
-- reversed, any leftover sorted by name after. Keyed by journal id, so two same-named instances stay
-- separate. Sourced from the seeded catalog, so it reflects exactly what's stored.
function ExpansionCatalog:_InstanceList(pred, orderList)
    local nameById = {}
    for _, r in pairs(self:_p().charStore:Instances()) do
        if r.id and pred(r) then nameById[r.id] = r.name end
    end
    local out, seen = {}, {}
    if orderList then
        for i = #orderList, 1, -1 do
            local id = orderList[i]
            if nameById[id] and not seen[id] then out[#out + 1] = { id = id, name = nameById[id] }; seen[id] = true end
        end
    end
    local rest = {}
    for id in pairs(nameById) do if not seen[id] then rest[#rest + 1] = id end end
    table.sort(rest, function(a, b) return (nameById[a] or "") < (nameById[b] or "") end)
    for _, id in ipairs(rest) do out[#out + 1] = { id = id, name = nameById[id] } end
    return out
end

-- Raids / dungeons in one expansion (by FK), newest first -- each drives its tile grid. A season
-- instance keeps its home expansion, so it lists under both its expansion AND Current Season.
function ExpansionCatalog:_RaidsInExpansion(exp)
    return self:_InstanceList(function(r) return r.isRaid and (r.expansion or "Other") == exp end,
        self:_p().ejRaidsByTier and self:_p().ejRaidsByTier[exp])
end

function ExpansionCatalog:_DungeonsInExpansion(exp)
    return self:_InstanceList(function(r) return (not r.isRaid) and (r.expansion or "Other") == exp end,
        self:_p().ejDungeonsByTier and self:_p().ejDungeonsByTier[exp])
end

-- Whether a catalog raid is in the live season. Prefers the journal set built this session (by id),
-- falling back to the stored flag.
function ExpansionCatalog:_IsSeasonRaid(r)
    if not r.isRaid then return false end
    local season = self:_p().ejSeasonRaids
    if season and next(season) and r.id then return season[r.id] and true or false end
    return r.season and true or false
end

function ExpansionCatalog:_SeasonRaidNames()
    return self:_InstanceList(function(r) return self:_IsSeasonRaid(r) end, self:_p().ejSeasonRaidList)
end

function ExpansionCatalog:_HasSeasonRaids() return self:_SeasonRaidNames()[1] ~= nil end

-- The live Mythic+ season's dungeons -- catalog dungeons whose name is in the C_ChallengeMode rotation
-- (or carry the stored flag). Each is a distinct journal instance, so the season pick is locked to it.
function ExpansionCatalog:_SeasonDungeonNames()
    local s = self:_SeasonDungeons(); local set = s and s.set
    return self:_InstanceList(function(r) return (not r.isRaid) and ((set and set[r.name]) or r.season) end)
end

-- ONE pass per patch: sweep every uiMapID for zone-type maps and upsert the full zone registry --
-- name, uiMapID, world map instance id (GetWorldPosFromMapPos). Runs inside the Worker job
-- (MaybeYield per id); rows are added/updated only (flight_master FKs zone names).
function ExpansionCatalog:_BuildZoneCatalog()
    local p = self:_p()
    if p.zoneCatalogBuilt then return end
    if not (C_Map and C_Map.GetMapInfo) then return end
    if ns.Versioning and ns.Versioning:IsCurrent(ZONE_DOMAIN) then p.zoneCatalogBuilt = true; return end
    local db = self:DB(); if not db then return end
    ns.Worker:Mark("zone catalog")
    local zoneType = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3
    local centre = CreateVector2D and CreateVector2D(0.5, 0.5)
    for id = 1, 3200 do
        local mi = C_Map.GetMapInfo(id)
        if mi and mi.mapType == zoneType and mi.name and mi.name ~= "" then
            local mapID
            if centre and C_Map.GetWorldPosFromMapPos then
                local instance = C_Map.GetWorldPosFromMapPos(id, centre)
                if instance and instance >= 0 then mapID = instance end
            end
            local fields = { ui_map_id = id, map_id = mapID }
            if db:Select("name"):From("zone"):Where("name", "=", mi.name):Limit(1):Run()[1] then
                db:Update("zone", fields, { name = mi.name })
            else
                fields.name = mi.name
                db:Insert("zone", fields)
            end
        end
        ns.Worker:MaybeYield()
    end
    p.zoneCatalogBuilt = true
    if ns.Versioning then ns.Versioning:Stamp(ZONE_DOMAIN) end
end

-- Resolve a zone's typography style: curated -> biome keywords -> the expansion tint on the
-- neutral plate (see the style tables above).
function ExpansionCatalog:_ZoneStyle(name, expId)
    local s = ZONE_STYLE[name]
    if s then return s end
    local lower = tostring(name or ""):lower()
    for _, entry in ipairs(BIOME_WORDS) do
        for _, word in ipairs(entry[2]) do
            if lower:find(word, 1, true) then return BIOME_STYLE[entry[1]] end
        end
    end
    return { bg = PLATE_BG, bg2 = PLATE_BG2, fg = EXP_STYLE[expId] or EXP_STYLE_DEFAULT }
end

-- The newest season raid's splash, for the Current Season overview tile (else nil).
function ExpansionCatalog:_LatestSeasonRaidArt()
    local list = self:_SeasonRaidNames()
    if list[1] then return self:_InstanceArt(list[1].name, "raid") end
end

-- ---- dungeons: the CURRENT M+ SEASON (always shown with Mythic 0) --------------------------
-- The current M+ season's dungeon lineup -- can include legacy-expansion dungeons, and they ALL
-- carry a Mythic 0 lockout while in season. From C_ChallengeMode.GetMapTable(); cached + a set.
function ExpansionCatalog:_SeasonDungeons()
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

-- The expansion the Current Season belongs to, derived from the dungeons IN the season: the NEWEST
-- expansion represented among them. A season can fold in legacy dungeons, so we take the highest tier
-- level present rather than assuming the live expansion. Returns a tier NAME (for the logo/grouping),
-- or nil before the journal map is ready (or if none of the season's dungeons are mapped yet).
function ExpansionCatalog:_SeasonExpansionTier()
    local s = self:_SeasonDungeons()
    local lvl = self:_p().ejTierLevel
    if not (s and lvl) then return nil end
    local bestTier, bestLvl
    for _, name in ipairs(s.list) do
        local tier = self:_InstanceExpansion(name)   -- "Other" (no level) if unmapped
        local l = lvl[tier]
        if l and (not bestLvl or l > bestLvl) then bestTier, bestLvl = tier, l end
    end
    return bestTier
end

-- Upsert a catalog row (insert if missing, else update the given fields). Seeding only runs on the
-- WALK path -- a first run or a new patch -- so refreshing existing rows (art / order / expansion /
-- difficulty) here keeps the persisted catalog current when the journal changes. (A same-patch login
-- reconstructs from the DB and never seeds.) Lock state lives on dashboard_lockout, untouched.
function ExpansionCatalog:_SeedInstance(key, fields)
    local db = self:DB(); if not db then return end
    if db:Select("key"):From("dashboard_instance"):Where("key", "=", key):Limit(1):Run()[1] then
        db:Update("dashboard_instance", fields, { key = key })
    else
        fields.key = key
        db:Insert("dashboard_instance", fields)
    end
end

-- Seed the instance CATALOG into dashboard_instance from the Encounter Journal: every raid (one row
-- per difficulty) and every dungeon of the latest expansion (Mythic 0). The current M+ season pool is
-- seeded separately (_SeedSeasonDungeons). Insert-if-missing; needs the journal map (caller guards).
function ExpansionCatalog:_SeedInstances()
    local p = self:_p()
    ns.Worker:Mark("seed instances")
    if not (GetDifficultyInfo and p.ejInst) then return end
    self:_SeedExpansions()                                   -- the FK target rows, before any instance
    local season, raidDiffs = p.ejSeasonRaids or {}, p.ejRaidDiffs or {}
    -- one row per (raid instance, difficulty it offers); keyed by journal id so two same-named raids
    -- stay distinct, each under its own home expansion.
    local lore, image, ord = p.ejLore or {}, p.ejImage or {}, p.ejOrd or {}
    for id, rec in pairs(p.ejInst) do
        if rec.isRaid then
            local cs = season[id] and true or false
            for _, did in ipairs(raidDiffs[id] or RAID_DIFF_IDS) do   -- only the difficulties this raid offers
                local diffName = GetDifficultyInfo(did)
                if diffName then
                    self:_SeedInstance(id .. "|" .. did,
                        { instance_id = id, name = rec.name, diff = diffName, diff_id = did,
                          is_raid = true, expansion = rec.tier, current_season = cs,
                          lore_id = lore[rec.name], button_id = image[rec.name], ord = ord[id] })
                end
            end
            ns.Worker:MaybeYield()                               -- spread the inserts across frames
        end
    end
    -- every dungeon of the current expansion (Mythic 0), keyed by journal id
    local cur = self:_CurrentExpansionTier()
    for _, id in ipairs((p.ejDungeonsByTier or {})[cur] or {}) do
        local rec = p.ejInst[id]
        if rec then
            self:_SeedInstance(id .. "|" .. M0_ID,
                { instance_id = id, name = rec.name, diff = M0, diff_id = M0_ID, is_raid = false,
                  expansion = cur, current_season = self:_IsSeasonDungeon(rec.name),
                  lore_id = lore[rec.name], button_id = image[rec.name], ord = ord[id] })
        end
        ns.Worker:MaybeYield()
    end
end

-- True if a dungeon is in the live Mythic+ season rotation (the addon's "Current Season" set).
function ExpansionCatalog:_IsSeasonDungeon(name)
    local s = self:_SeasonDungeons()
    return (s and s.set[name]) and true or false
end

-- Refresh the current_season flag on the catalog each pass (the season set can finalise after login,
-- and pre-existing rows seeded before the flag existed default to false). Updates ONLY rows whose
-- expansion is null or a known registry entry, so a stray orphan (e.g. a not-yet-pruned legacy row)
-- can't trip the FK recheck Update runs; the `~=` guards skip rows already in the right state.
function ExpansionCatalog:_MarkSeasonFlags()
    ns.Worker:Mark("season flags")
    local db = self:DB(); if not db then return end
    local valid = {}
    for _, e in ipairs(db:Select("name"):From("expansion"):Run()) do valid[denull(e.name)] = true end
    local function safe(r) local e = denull(r.expansion); return e == nil or valid[e] end
    local sr = self:_p().ejSeasonRaids or {}                  -- season RAIDS by journal id
    local sd = self:_SeasonDungeons(); local sdset = (sd and sd.set) or {}   -- season DUNGEONS by name (M+ rotation)
    db:Update("dashboard_instance", { current_season = true },
        function(r) return safe(r) and r.is_raid == true and sr[denull(r.instance_id)] and r.current_season ~= true end)
    ns.Worker:MaybeYield()                       -- each pass scans the catalog: chunk between them
    db:Update("dashboard_instance", { current_season = false },
        function(r) return safe(r) and r.is_raid == true and not sr[denull(r.instance_id)] and r.current_season ~= false end)
    ns.Worker:MaybeYield()
    db:Update("dashboard_instance", { current_season = true },
        function(r) return safe(r) and r.is_raid ~= true and sdset[denull(r.name)] and r.current_season ~= true end)
    ns.Worker:MaybeYield()
    db:Update("dashboard_instance", { current_season = false },
        function(r) return safe(r) and r.is_raid ~= true and not sdset[denull(r.name)] and r.current_season ~= false end)
end

-- Drop catalog rows whose INSTANCE or DIFFICULTY no longer exists: the difficulty id no longer
-- resolves (GetDifficultyInfo), or the instance name is gone from the Encounter Journal catalog
-- (raids + dungeons across every tier). Only runs once the journal is loaded (else the existence set
-- would be empty and wipe everything); a deleted instance cascades to every character's lockout row.
function ExpansionCatalog:_PruneInstances()
    local p = self:_p()
    ns.Worker:Mark("prune instances")
    if not (GetDifficultyInfo and p.ejInst) then return end
    local exists = {}
    for id in pairs(p.ejInst) do exists[id] = true end
    if not next(exists) then return end   -- journal somehow empty -- never prune against nothing
    -- which difficulty ids each raid offers (clears rows over-seeded before per-raid difficulties existed)
    local validDiff = {}
    for id, ids in pairs(p.ejRaidDiffs or {}) do
        local s = {}; for _, d in ipairs(ids) do s[d] = true end; validDiff[id] = s
    end
    local db = self:DB(); if not db then return end
    -- predicate runs on the RAW stored row (absent field = nil, not the NULL sentinel)
    db:Delete("dashboard_instance", function(r)
        if r.instance_id == nil then return true end                            -- legacy name-keyed row (pre-id)
        if r.diff_id and not GetDifficultyInfo(r.diff_id) then return true end   -- difficulty retired
        if not exists[r.instance_id] then return true end                       -- instance gone from the journal
        local vd = r.is_raid and validDiff[r.instance_id]
        return (vd and r.diff_id and not vd[r.diff_id]) and true or false        -- a difficulty this raid never had
    end)
end

-- Sort the current M+ season's dungeons into the registry under their HOME expansion (Mythic 0), so a
-- season dungeon from a PAST expansion (e.g. Magister's Terrace) makes that expansion appear as a tile
-- and renders under it -- not only under Current Season. Idempotent; needs the journal map for the
-- home lookup (skips a dungeon whose expansion isn't known yet); _PruneInstances removes these again
-- if the dungeon's difficulty is ever retired.
function ExpansionCatalog:_SeedSeasonDungeons()
    ns.Worker:Mark("seed season dungeons")
    local s = self:_SeasonDungeons()
    if not s then return end
    local p = self:_p()
    local lore, image, ord = p.ejLore or {}, p.ejImage or {}, p.ejOrd or {}
    for _, name in ipairs(s.list) do
        ns.Worker:MaybeYield()
        local id = self:_IdForName(name)              -- the newest journal instance of this name (locks identity)
        local rec = id and p.ejInst and p.ejInst[id]
        if rec and rec.tier then
            self:_p().charStore:SetInstance(id .. "|" .. M0_ID,
                { instance_id = id, name = rec.name, diff = M0, diff_id = M0_ID, is_raid = false,
                  expansion = rec.tier, current_season = true,   -- in the season pool by definition
                  lore_id = lore[rec.name], button_id = image[rec.name], ord = ord[id] })
        end
    end
end

-- ---- public catalog accessors (the Dashboard reads catalog STATE through these) ---------------
-- The current expansion tier name (the one owning the newest raids), set by the journal walk /
-- reconstruction.
function ExpansionCatalog:CurrentExpansion() return self:_p().currentExpansion end

-- The journal tier level for an expansion name (for native logo lookup / ordering), or nil.
function ExpansionCatalog:TierLevel(exp) return (self:_p().ejTierLevel or {})[exp] end

-- The journal instance record for an EJ id (or nil) -- the CharacterStore's self-curating lockout
-- path reaches it through the catalog.
function ExpansionCatalog:_InstRecord(id)
    local inst = self:_p().ejInst
    return inst and inst[id] or nil
end

ns.ExpansionCatalog = ExpansionCatalog
