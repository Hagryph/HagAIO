local addonName, ns = ...
local Class = ns.Class

-- Services/ActionBars.lua
-- Service for locating action buttons by what they cast and annotating them.
-- Enumerates the standard action bars, resolves each button's effective spell
-- (a direct spell, an override, or the spell a macro casts) and returns the live
-- button FRAMES, so features can grey / highlight them. Consumers watch the bar
-- events themselves (ACTIONBAR_SLOT_CHANGED, etc.) and re-query on change.

local ActionBars = Class.new("ActionBars", ns.Service)
local GlowClaim = Class.new("ActionButtonGlowClaim")

-- Public, typo-safe effect choices for RegisterGlow(..., { effect = ... }).
ns.ActionButtonGlowEffect = ns.Enum.new("ActionButtonGlowEffect", {
    STEADY = "steady",
    PULSE = "pulse",
    FLASH = "flash",
})

-- The standard retail action bars (8 x 12 buttons). Pet/stance bars are excluded
-- (class abilities don't live there).
local BAR_PREFIXES = {
    "ActionButton",
    "MultiBarBottomLeftButton",
    "MultiBarBottomRightButton",
    "MultiBarRightButton",
    "MultiBarLeftButton",
    "MultiBar5Button",
    "MultiBar6Button",
    "MultiBar7Button",
}
local SLOTS_PER_BAR = 12

-- One independent registration returned to a glow owner. Registration and activation are separate:
-- callers create the frame/style once, then only flip a plain active bit in their hot paths.
function GlowClaim:Initialize(actionBars, button, owner, opts)
    local p = self:_p()
    p.actionBars = actionBars
    p.button = button
    p.owner = owner
    p.activationOrder = nil
    p.priority = opts.priority
    p.effect = opts.effect
    p.color = opts.color
    p.alpha = 1
    p.active = false
    p.registered = true
end

function GlowClaim:Priority() return self:_p().priority end
function GlowClaim:ActivationOrder() return self:_p().activationOrder end
function GlowClaim:Effect() return self:_p().effect end
function GlowClaim:Color() return self:_p().color end
function GlowClaim:Alpha() return self:_p().alpha end
function GlowClaim:IsActive() return self:_p().active end
function GlowClaim:IsRegistered() return self:_p().registered end

function GlowClaim:SetAlpha(alpha)
    local p = self:_p()
    if p.registered then p.actionBars:_SetGlowAlpha(self, alpha) end
    return self
end

function GlowClaim:Activate()
    local p = self:_p()
    if p.registered then p.actionBars:_SetGlowActive(self, true) end
    return self
end

function GlowClaim:Deactivate()
    local p = self:_p()
    if p.registered then p.actionBars:_SetGlowActive(self, false) end
    return self
end

function GlowClaim:Unregister()
    local p = self:_p()
    if p.registered then p.actionBars:_UnregisterGlowClaim(self) end
    return self
end

local function buttonSlot(btn)
    if not btn then return nil end
    if btn.action then return btn.action end
    return btn.GetAttribute and btn:GetAttribute("action")
end

-- The action-button FRAMES are created once by Blizzard and never change, so resolve the
-- 96 _G[name] lookups a single time and cache the frame list. (The slot each button shows
-- still varies -- that's read live per visit.) Cached only once the bars exist.
function ActionBars:_Buttons()
    local p = self:_p()
    if p.buttons then return p.buttons end
    local list = {}
    for _, prefix in ipairs(BAR_PREFIXES) do
        for i = 1, SLOTS_PER_BAR do
            local btn = _G[prefix .. i]
            if btn then list[#list + 1] = btn end
        end
    end
    if #list > 0 then p.buttons = list end   -- don't cache an empty pre-load result
    return list
end

-- Visit every known action button as fn(buttonFrame, slot).
function ActionBars:_Each(fn)
    for _, btn in ipairs(self:_Buttons()) do
        local slot = buttonSlot(btn)
        if slot then fn(btn, slot) end
    end
end

-- The spell a slot effectively casts (direct, or via a macro), or nil.
local function slotSpell(slot)
    if not (HasAction and HasAction(slot)) then return nil end
    local actionType, id = GetActionInfo(slot)
    if actionType == "spell" then return id end
    if actionType == "macro" then return GetMacroSpell and GetMacroSpell(id) end
end

local function spellMatches(id, target)
    if not id then return false end
    if id == target then return true end
    local base = FindBaseSpellByID and FindBaseSpellByID(id)
    return base == target
end

-- All live button frames currently showing `spellID` (incl. a macro that casts
-- it, or an override of it).
function ActionBars:FindSpell(spellID)
    local out = {}
    self:_Each(function(btn, slot)
        if spellMatches(slotSpell(slot), spellID) then out[#out + 1] = btn end
    end)
    return out
end

-- All button frames running macro `nameOrIndex` (a macro name string or index).
function ActionBars:FindMacro(nameOrIndex)
    local out = {}
    self:_Each(function(btn, slot)
        local actionType, id = GetActionInfo(slot)
        if actionType == "macro" then
            local name = GetMacroInfo and GetMacroInfo(id)
            if id == nameOrIndex or name == nameOrIndex then out[#out + 1] = btn end
        end
    end)
    return out
end

-- The count the game paints on a spell's action button (e.g. Brewmaster Gift of
-- the Ox orbs shown on Expel Harm). Returns a STRING (use count / charges text) --
-- and a SECRET string in restricted content (GetActionDisplayCount is
-- SecretWhenCooldownsRestricted): you can SetText it, but tonumber/arithmetic/compare
-- throw (route through ns.Secrets). nil if the spell isn't on a bar.
function ActionBars:DisplayCount(spellID)
    if not (C_ActionBar and C_ActionBar.FindSpellActionButtons and C_ActionBar.GetActionDisplayCount) then
        return nil
    end
    local slots = C_ActionBar.FindSpellActionButtons(spellID)
    if slots and slots[1] then return C_ActionBar.GetActionDisplayCount(slots[1]) end
    return nil
end

function ActionBars:_GlowOptions(opts, current)
    opts = opts or {}
    local priority = opts.priority
    local prioritySecret = issecretvalue and issecretvalue(priority)
    assert(not prioritySecret, "ActionBars:RegisterGlow: priority cannot be secret")
    if priority == nil then priority = current and current:Priority() or 0 end
    assert(type(priority) == "number", "ActionBars:RegisterGlow: priority must be a number")

    local effect = opts.effect
    local effectSecret = issecretvalue and issecretvalue(effect)
    assert(not effectSecret, "ActionBars:RegisterGlow: effect cannot be secret")
    if effect == nil then effect = current and current:Effect() or ns.ActionButtonGlowEffect.PULSE end
    assert(ns.Enum.has(ns.ActionButtonGlowEffect, effect), "ActionBars:RegisterGlow: unknown effect")

    local color = opts.color
    local colorSecret = issecretvalue and issecretvalue(color)
    assert(not colorSecret, "ActionBars:RegisterGlow: color cannot be secret")
    if color == nil then color = current and current:Color() or ns.Theme.rgb.accent end
    assert(ns.Color.Is(color), "ActionBars:RegisterGlow: color must be an ns.Color")
    return { priority = priority, effect = effect, color = color }
end

function ActionBars:_GlowState(button)
    local p = self:_p()
    p.glows = p.glows or setmetatable({}, { __mode = "k" })
    local state = p.glows[button]
    if state then return state end
    state = {
        claims = {},
        view = ns.UI.Widgets.ActionButtonGlow:New(button, button.icon or button),
    }
    p.glows[button] = state
    return state
end

function ActionBars:_GlowWinner(state)
    local winner
    for _, claim in pairs(state.claims) do
        if claim:IsActive() and (not winner or claim:Priority() > winner:Priority()
            or (claim:Priority() == winner:Priority()
                and claim:ActivationOrder() < winner:ActivationOrder())) then
            winner = claim
        end
    end
    return winner
end

function ActionBars:_ResolveGlow(state, changedClaim)
    local previous = state.winner
    local winner = self:_GlowWinner(state)
    state.winner = winner
    if not winner then
        state.view:Hide()
    elseif winner ~= previous or winner == changedClaim then
        state.view:SetEffect(winner:Effect())
        state.view:SetColor(winner:Color())
        state.view:SetAlpha(winner:Alpha())
        state.view:Show()
    end
end

-- Pre-register or update one owner's glow claim for a button. This is the ONLY path that creates the
-- visual. Higher numeric priority wins; ties follow the order the CURRENT claims were activated.
-- opts = { priority = number (0), effect = ns.ActionButtonGlowEffect.*, color = ns.Color }
function ActionBars:RegisterGlow(button, owner, opts)
    assert(button ~= nil, "ActionBars:RegisterGlow: button is required")
    assert(type(owner) == "table", "ActionBars:RegisterGlow: owner must be an instance")
    local states = self:_p().glows
    local state = states and states[button]
    local claim = state and state.claims[owner]
    local normalized = self:_GlowOptions(opts, claim)
    state = state or self:_GlowState(button)
    if claim then
        local p = claim:_p()
        p.priority, p.effect, p.color = normalized.priority, normalized.effect, normalized.color
    else
        claim = GlowClaim:New(self, button, owner, normalized)
        state.claims[owner] = claim
    end
    self:_ResolveGlow(state, claim)
    return claim
end

function ActionBars:_RegisteredGlow(button, owner)
    local states = self:_p().glows
    local state = states and states[button]
    return state and state.claims[owner]
end

-- Runtime actions: activate/deactivate an EXISTING registration without allocating a frame or claim.
function ActionBars:Glow(button, owner)
    local claim = self:_RegisteredGlow(button, owner)
    assert(claim, "ActionBars:Glow: owner has no registered glow for this button")
    claim:Activate()
    return claim
end

function ActionBars:Unglow(button, owner)
    local claim = button and owner and self:_RegisteredGlow(button, owner)
    if claim then claim:Deactivate() end
    return claim
end

function ActionBars:_SetGlowActive(claim, active)
    local cp = claim:_p()
    if not cp.registered then return end
    local states = self:_p().glows
    local state = states and states[cp.button]
    if not (state and state.claims[cp.owner] == claim) then return end
    active = active and true or false
    if cp.active == active then return end
    cp.active = active
    if active then
        local p = self:_p()
        p.nextGlowActivation = (p.nextGlowActivation or 0) + 1
        cp.activationOrder = p.nextGlowActivation
    else
        cp.activationOrder = nil
    end
    self:_ResolveGlow(state, claim)
end

-- Teardown removes the registration entirely. Removing an active winner immediately reveals the
-- next active priority/activation-order candidate; removing an inactive or losing registration is inert.
function ActionBars:UnregisterGlow(button, owner)
    local claim = button and owner and self:_RegisteredGlow(button, owner)
    if claim then claim:Unregister() end
    return claim
end

function ActionBars:_UnregisterGlowClaim(claim)
    local cp = claim:_p()
    if not cp.registered then return end
    local states = self:_p().glows
    local state = states and states[cp.button]
    if state and state.claims[cp.owner] == claim then state.claims[cp.owner] = nil end
    cp.active = false
    cp.activationOrder = nil
    cp.registered = false
    if state then self:_ResolveGlow(state) end
end

-- Alpha is a separate operation so a current Unit*Percent curve result can travel from Blizzard
-- directly to Frame:SetAlpha without Lua comparing or branching on the secret value.
function ActionBars:_SetGlowAlpha(claim, alpha)
    local secret = issecretvalue and issecretvalue(alpha)
    if not secret then
        assert(type(alpha) == "number" and alpha >= 0 and alpha <= 1,
            "ActionButtonGlowClaim:SetAlpha: alpha must be between 0 and 1")
    end
    local cp = claim:_p()
    cp.alpha = alpha
    local states = self:_p().glows
    local state = states and states[cp.button]
    if state and state.winner == claim then state.view:SetAlpha(alpha) end
end

-- Grey/un-grey a button with a reusable dark overlay (doesn't fight Blizzard's own
-- icon desaturation/range colouring, unlike SetDesaturated).
function ActionBars:SetGrey(button, on)
    if not button then return end
    -- Cache the reusable overlay in a WEAK-KEYED map in our OWN private state, keyed by button,
    -- rather than stamping it onto the Blizzard button (a frame we don't own).
    local p = self:_p()
    p.greyOverlay = p.greyOverlay or setmetatable({}, { __mode = "k" })
    local ov = p.greyOverlay[button]
    if on then
        if not ov then
            ov = ns.UI.Widgets.Fill:New(button, { layer = "OVERLAY", sublevel = 6 })
            ov:SetAllPoints(button.icon or button)
            ov:SetColorTexture(0, 0, 0, 0.55)
            p.greyOverlay[button] = ov
        end
        ov:Show()
    elseif ov then
        ov:Hide()
    end
end

ns.ServiceManager:Register(ActionBars:New("ActionBars"))
