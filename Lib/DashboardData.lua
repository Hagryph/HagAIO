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
--   * Denull           -- collapse the DB.NULL sentinel to Lua nil (typed-column reader).
--   * PlainNum         -- launder a value to a plain number, NULLing a secret (typed-column writer).

local DashboardData = {}

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

-- A projected column is the DB.NULL sentinel (not Lua nil) when absent; collapse it to nil so the
-- reconstructed documents read exactly like the old plain-Lua snapshots (l.progress or 0, etc.).
function DashboardData.Denull(v)
    if v == nil or ns.DB.isNull(v) then return nil end
    return v
end

-- Only a plain number is allowed into the typed columns: ns.Secrets:Number returns nil for a
-- SECRET value (restricted content), so a secret is stored as NULL rather than smuggled in as a
-- non-scalar. With no Secrets layer present the value passes through unchanged.
function DashboardData.PlainNum(v)
    if ns.Secrets then return ns.Secrets:Number(v) end   -- nil for a secret
    return v
end

ns.LibManager:RegisterValue("DashboardData", DashboardData)
