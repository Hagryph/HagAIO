local addonName, ns = ...
local Class = ns.Class

-- Services/Cooldowns.lua
-- Watch a spell's cooldown WITHOUT reading secret values. In 12.0 the live
-- start/duration are secret, but `isActive`/`isOnGCD` are non-secret booleans and
-- GetSpellBaseCooldown is static. So we flip ON only on a real cast
-- (UNIT_SPELLCAST_SUCCEEDED) and drive an internal timer off the base cooldown to
-- flip OFF -- immune to GCD/stun (which never put the spell on cooldown). A
-- SPELL_UPDATE_COOLDOWN poll only ever flips OFF early (CDR/reset), never ON.
--
--   local w = ns.Cooldowns:Watch(spellID, function(onCooldown) ... end)
--   w:IsOnCooldown()   -- current state
--   w:Cancel()         -- stop watching (drops its subscriptions + timer)

local Cooldowns = Class.new("Cooldowns", ns.Service)

local function baseCooldown(spellID)
    if not GetSpellBaseCooldown then return nil end
    local ms = GetSpellBaseCooldown(spellID)
    if not ms or (issecretvalue and issecretvalue(ms)) or ms <= 0 then return nil end
    return ms / 1000
end

local function isActive(spellID)
    local cd = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(spellID)
    return cd and cd.isActive, cd and cd.isOnGCD
end

-- ---- CooldownWatch: the live handle Watch() returns ----------------------------------------
-- A small class (private state behind :_p(), methods over a raw record) -- the house style
-- (Logger -> LogChannel, Cache -> CacheStore). It owns its EventBus subscriptions + the base-
-- cooldown timer and tears them down on :Cancel().
local CooldownWatch = Class.new("CooldownWatch")

function CooldownWatch:Initialize(spellID, onChange)
    local p = self:_p()
    p.spellID = spellID
    p.onChange = onChange
    p.onCooldown = false
    local bus = ns.EventBus
    -- Filter to the PLAYER at the engine (RegisterUnitEvent) rather than the shared bus:
    -- UNIT_SPELLCAST_SUCCEEDED fires for every visible unit (hundreds/sec in a raid), and
    -- we only care about the player's casts. The unit is therefore always "player".
    p.castTok = bus:OnUnit("UNIT_SPELLCAST_SUCCEEDED", function(_, _, _, sid)
        if sid == spellID then self:_Start() end
    end, "player")
    p.pollTok = bus:On("SPELL_UPDATE_COOLDOWN", function() self:_Poll() end)
    -- Reloaded mid-cooldown (not just a GCD): the real remaining is secret, so we
    -- can't run a precise internal timer -- just mark it on cooldown and let the
    -- SPELL_UPDATE_COOLDOWN poll flip it OFF when the cooldown actually ends.
    local active, onGCD = isActive(spellID)
    if active and not onGCD then self:_Set(true) end
end

function CooldownWatch:IsOnCooldown() return self:_p().onCooldown end

function CooldownWatch:_Set(onCooldown)
    local p = self:_p()
    if p.onCooldown == onCooldown then return end
    p.onCooldown = onCooldown
    if p.onChange then p.onChange(onCooldown) end
end

function CooldownWatch:_Start()
    local p = self:_p()
    self:_Set(true)
    if p.timer then p.timer:Cancel() end
    local dur = baseCooldown(p.spellID)
    if dur then
        p.timer = C_Timer.NewTimer(dur, function()
            p.timer = nil
            self:_Set(false)
        end)
    end
end

-- Backup flip-OFF only: a plain GCD also reports isActive=true, so we never flip ON from polling.
function CooldownWatch:_Poll()
    local p = self:_p()
    if not p.onCooldown then return end
    if isActive(p.spellID) then return end
    if p.timer then p.timer:Cancel(); p.timer = nil end
    self:_Set(false)
end

function CooldownWatch:Cancel()
    local p = self:_p()
    local bus = ns.EventBus
    bus:OffUnit(p.castTok)
    bus:Off("SPELL_UPDATE_COOLDOWN", p.pollTok)
    if p.timer then p.timer:Cancel(); p.timer = nil end
    p.onCooldown = false
end

ns.CooldownWatch = CooldownWatch

-- ---- the service: a thin factory for watches ----------------------------------------------
-- The watch owns its own state (watch:IsOnCooldown()) and teardown (watch:Cancel()).
function Cooldowns:Watch(spellID, onChange)
    return CooldownWatch:New(spellID, onChange)
end

ns.ServiceManager:Register(Cooldowns:New("Cooldowns", { deps = { "EventBus" } }))
