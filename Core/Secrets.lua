local addonName, ns = ...
local Class = ns.Class

-- Core/Secrets.lua
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

local Secrets = Class.new("Secrets")

function Secrets:Initialize() end

-- True if v is a secret value. Safe when the API is absent (pre-12.0 / test paths).
function Secrets:Is(v)
    return (issecretvalue and issecretvalue(v)) or false
end

-- A usable Lua number, or nil. NEVER operates on a secret (issecretvalue first, since
-- tonumber on a secret string throws) and never errors. Accepts real numbers or
-- non-secret numeric strings -- action-button counts come back as strings.
function Secrets:Number(v)
    if v == nil or self:Is(v) then return nil end
    if type(v) == "number" then return v end
    return tonumber(v)
end

-- Are we under combat secret restrictions right now (instanced encounter / M+ / PvP)?
-- Lets a module choose a secret-safe UI path up front. False pre-12.0.
function Secrets:Restricted()
    if C_Secrets and C_Secrets.HasSecretRestrictions then
        return C_Secrets.HasSecretRestrictions()
    end
    return false
end

-- Paint a value that may be a secret string/number onto a FontString. SetText is the
-- one sink that swallows a secret string, so the engine renders a live value we're not
-- allowed to read. `prefix` (optional) is concatenated -- legal even on a secret.
-- Returns true if anything was shown.
function Secrets:Text(fontString, v, prefix)
    if not fontString then return false end
    if v == nil then fontString:SetText(""); return false end
    if prefix and prefix ~= "" then
        fontString:SetText(prefix .. v)   -- concat is allowed on secrets
    else
        fontString:SetText(v)
    end
    return true
end

ns.Secrets = Secrets
