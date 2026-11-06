local S = dofile("Test/support.lua")

local function setup(inCombat)
    local ns, ctx = S.newNs(), { combat = inCombat == true, handlers = {}, buttons = {}, bindings = {} }
    _G.UIParent = {}
    _G.InCombatLockdown = function() return ctx.combat end
    _G.ClearOverrideBindings = function(frame) assert.is_false(ctx.combat); ctx.bindings[frame] = nil end
    _G.SetOverrideBindingClick = function(frame, priority, key, name, button)
        assert.is_false(ctx.combat); ctx.bindings[frame] = { key, name, button, priority }
    end
    ns.EventBus = {
        On = function(_, event, fn) ctx.handlers[event] = ctx.handlers[event] or {}; ctx.handlers[event][fn] = fn; return fn end,
        Off = function(_, event, token) if ctx.handlers[event] then ctx.handlers[event][token] = nil end end,
        Emit = function() end,
    }
    ns.EditMode = { IsEditing = function() return ctx.editing == true end }
    function ctx.fire(event)
        local copy = {}; for _, fn in pairs(ctx.handlers[event] or {}) do copy[#copy + 1] = fn end
        for _, fn in ipairs(copy) do fn(event) end
    end
    local Base = ns.Class.new("TestKeyButtonBase")
    function Base:Initialize(_, text, opts)
        local p = self:_p(); p.text = text
        p.frame = { GetName = function() return opts.name end,
            RegisterForClicks = function(_, value) ctx.clickEvent = value end }
        ctx.buttons[#ctx.buttons + 1] = self
    end
    function Base:_Frame() return self:_p().frame end
    function Base:SetText(text) self:_p().text = text; return self end
    function Base:SetOnClick(fn) self:_p().click = fn; return self end
    function Base:SetTone(key) ctx.tone = key; return self end
    function Base:SetPoint() return self end
    function Base:Show() self:_p().shown = true; return self end
    function Base:Hide() self:_p().shown = false; return self end
    function Base:Dispose() self:Hide() end
    function Base:Click() if self:_p().click then self:_p().click() end end
    ns.UI._wb = { Registrable = ns.Mixin.new("TestRegistrable", {
        RegisterEditMode = function(self, opts) ctx.editRegistration = opts; return self end,
        UnregisterEditMode = function(self) ctx.editRegistration = nil; return self end,
    }) }; ns.UI.Widgets = { Button = Base }
    S.load(ns, "UI/Widgets/KeyboundButton.lua")
    S.load(ns, "Core/Submodule.lua")
    ns.ModuleManager = { GetModule = function() return nil end }
    ns.SubmoduleManager = { Register = function(_, sub) ctx.module = sub end }
    S.load(ns, "Modules/Misc/CombatControl.lua")
    ctx.module:Enable(); ctx.button = ctx.buttons[1]
    return ctx
end

describe("Combat control", function()
    it("starts off with its own F10 button and Edit Mode placement", function()
        local c = setup()
        assert.is_false(_G.HagAIOCombatEnabled); assert.are.equal("red", c.tone)
        assert.are.equal("combatControl", c.editRegistration.key)
        for _, binding in pairs(c.bindings) do
            assert.are.equal("F10", binding[1]); assert.are.equal("HagAIOCombatButton", binding[2])
            assert.are.equal("LeftButton", binding[3])
        end
        c.module:Disable()
    end)
    it("toggles immediately in combat and stays enabled between fights", function()
        local c = setup(); c.combat = true; c.button:Click()
        assert.is_true(_G.HagAIOCombatEnabled); assert.are.equal("green", c.tone)
        c.combat = false; c.fire("PLAYER_REGEN_ENABLED")
        assert.is_true(_G.HagAIOCombatEnabled)
        c.button:Click(); assert.is_false(_G.HagAIOCombatEnabled)
        c.module:Disable()
    end)
    it("cannot be toggled while arranging the button", function()
        local c = setup(); c.editing = true; c.button:Click()
        assert.is_false(_G.HagAIOCombatEnabled)
        c.editing = false; c.button:Click(); assert.is_true(_G.HagAIOCombatEnabled)
        c.module:Disable(); assert.is_false(_G.HagAIOCombatEnabled)
    end)
    it("revokes permission immediately on disable and defers protected binding cleanup", function()
        local c = setup(); c.button:Click(); c.combat = true; c.module:Disable()
        assert.is_false(_G.HagAIOCombatEnabled)
        c.button:Click(); assert.is_false(_G.HagAIOCombatEnabled)
        c.combat = false; c.fire("PLAYER_REGEN_ENABLED"); assert.is_nil(next(c.bindings))
        c.module:Enable(); assert.is_false(_G.HagAIOCombatEnabled); c.module:Disable()
    end)
end)
