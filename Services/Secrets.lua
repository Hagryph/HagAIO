local addonName, ns = ...
local Class = ns.Class

-- Services/Secrets.lua
-- Thin, allocation-free helpers around 12.0 Secret Values, so modules don't each
-- re-implement the issecretvalue dance (and the easy ways to crash on it).
--
-- The 12.0 rules that matter here:
--   * Tainted code may NOT do arithmetic, comparison, or boolean tests on a secret,
--     and may NOT tonumber() a secret string -- any of those throw.
--   * A secret value may still be STORED, passed to Lua functions, concatenated, and
--     handed to a small set of "secret-safe" widget sinks (FontString:SetText,
--     StatusBar:SetValue, Cooldown:SetCooldownFromDurationObject, ColorCurve, ...).
--   * Frame GEOMETRY (size / position / anchor offset) can never consume a secret.
--
--   local n = ns.Secrets:Number(maybeSecret)   -- number, or nil if secret/non-numeric
--   ns.Secrets:Text(fontString, maybeSecret)   -- paint a value we may not read
--   if ns.Secrets:Restricted() then ...        -- in M+/raid/PvP secret content?

local Secrets = Class.new("Secrets", ns.Service, {
    statics = {
        restrictionNames = { "Combat", "Encounter", "ChallengeMode", "PvPMatch", "Map" },
    },
})
local S = Class.statics(Secrets)

-- True if v is a secret value. Safe when the API is absent (pre-12.0 / test paths).
function Secrets:Is(v)
    return (issecretvalue and issecretvalue(v)) or false
end

-- A usable Lua number, or nil. NEVER operates on a secret (issecretvalue first, since
-- tonumber on a secret string throws) and never errors. Accepts real numbers or
-- non-secret numeric strings -- action-button counts come back as strings.
function Secrets:Number(v)
    -- A nil comparison is itself forbidden for a secret, so classification must be
    -- the first operation performed on the value.
    if self:Is(v) then return nil end
    if v == nil then return nil end
    if type(v) == "number" then return v end
    return tonumber(v)
end

-- Are any combat-data restriction scopes active right now? HasSecretRestrictions is
-- only a build-wide capability switch; the live state belongs to C_RestrictedActions.
-- False when the current client does not expose the restriction-state API.
function Secrets:Restricted()
    local isActive = C_RestrictedActions and C_RestrictedActions.IsAddOnRestrictionActive
    local restrictionTypes = Enum and Enum.AddOnRestrictionType
    if not (isActive and restrictionTypes) then return false end
    for _, name in ipairs(S.restrictionNames) do
        local restrictionType = restrictionTypes[name]
        if restrictionType ~= nil and isActive(restrictionType) then return true end
    end
    return false
end

-- Paint a value that may be a secret string/number onto a FontString. SetText is the
-- one sink that swallows a secret string, so the engine renders a live value we're not
-- allowed to read. `prefix` (optional) is concatenated -- legal even on a secret.
-- Returns true if anything was shown.
function Secrets:Text(fontString, v, prefix)
    if not fontString then return false end
    -- Check secrecy before comparing the value with nil. Unlike Number, a secret
    -- remains useful here because SetText and string/number concatenation accept it.
    local secret = self:Is(v)
    if not secret and v == nil then fontString:SetText(""); return false end
    if prefix and prefix ~= "" then
        fontString:SetText(prefix .. v)   -- concat is allowed on secrets
    else
        fontString:SetText(v)
    end
    return true
end

ns.ServiceManager:Register(Secrets:New("Secrets"))
