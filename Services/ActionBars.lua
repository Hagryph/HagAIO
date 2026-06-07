local addonName, ns = ...
local Class = ns.Class

-- Services/ActionBars.lua
-- Service for locating action buttons by what they cast and annotating them.
-- Enumerates the standard action bars, resolves each button's effective spell
-- (a direct spell, an override, or the spell a macro casts) and returns the live
-- button FRAMES, so features can grey / highlight them. Consumers watch the bar
-- events themselves (ACTIONBAR_SLOT_CHANGED, etc.) and re-query on change.

local ActionBars = Class.new("ActionBars", ns.Service)

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

function ActionBars:OnInitialize() end

local function buttonSlot(btn)
    if not btn then return nil end
    if btn.action then return btn.action end
    return btn.GetAttribute and btn:GetAttribute("action")
end

-- Visit every known action button as fn(buttonFrame, slot).
function ActionBars:_Each(fn)
    for _, prefix in ipairs(BAR_PREFIXES) do
        for i = 1, SLOTS_PER_BAR do
            local btn = _G[prefix .. i]
            local slot = btn and buttonSlot(btn)
            if slot then fn(btn, slot) end
        end
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

-- Grey/un-grey a button with a reusable dark overlay (doesn't fight Blizzard's own
-- icon desaturation/range colouring, unlike SetDesaturated).
function ActionBars:SetGrey(button, on)
    if not button then return end
    local ov = button.__hagGrey
    if on then
        if not ov then
            ov = button:CreateTexture(nil, "OVERLAY", nil, 6)
            ov:SetAllPoints(button.icon or button)
            ov:SetColorTexture(0, 0, 0, 0.55)
            button.__hagGrey = ov
        end
        ov:Show()
    elseif ov then
        ov:Hide()
    end
end

ns.ServiceManager:Register(ActionBars:New("ActionBars"))
