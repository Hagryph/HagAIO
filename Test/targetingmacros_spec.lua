local S = dofile("Test/support.lua")
local function setup(combat)
    local ns, c = S.newNs(), { combat = combat, macros = {}, handlers = {} }
    _G.InCombatLockdown = function() return c.combat end
    _G.GetMacroIndexByName = function(name) for i, m in ipairs(c.macros) do if m.name == name then return i end end; return 0 end
    _G.GetMacroInfo = function(i) return c.macros[i].name, 1, c.macros[i].body end
    _G.CreateMacro = function(name, _, body) c.macros[#c.macros + 1] = { name = name, body = body }; return #c.macros end
    _G.SlashCmdList = {}
    -- These interfaces must never be consulted by this component.
    for _, api in ipairs({ "UnitGUID", "UnitExists", "GetBindingKey", "GetBindingAction", "SetBinding", "SetBindingMacro" }) do
        _G[api] = function() error("Unexpected live-state/binding access: " .. api) end
    end
    ns.EventBus = { On = function(_, event, fn) c.handlers[event] = fn; return fn end, Off = function(_, event) c.handlers[event] = nil end, Emit = function() end }
    S.load(ns, "Core/Submodule.lua")
    ns.ModuleManager = { GetModule = function() return nil end }
    ns.SubmoduleManager = { Register = function(_, sub) c.module = sub end }
    S.load(ns, "Modules/Misc/TargetingMacros.lua")
    return c
end

describe("Targeting macro creation", function()
    it("creates the three macros once without consulting bindings or live unit state", function()
        local c = setup(false); c.module:Enable()
        assert.are.equal(3, #c.macros); assert.are.equal("WHMouseFocus", c.macros[1].name)
        assert.are.equal("/focus [@mouseover,exists,nodead]", c.macros[1].body)
        SlashCmdList.WHTARGETMACROS(); assert.are.equal(3, #c.macros)
        assert.is_nil(c.handlers.UPDATE_MOUSEOVER_UNIT); assert.is_nil(c.handlers.PLAYER_FOCUS_CHANGED)
        c.module:Disable(); assert.is_nil(SlashCmdList.WHTARGETMACROS)
    end)
    it("waits for combat end and preserves existing macro bodies", function()
        local c = setup(true); c.module:Enable(); assert.are.equal(0, #c.macros)
        c.combat = false; c.handlers.PLAYER_REGEN_ENABLED(); assert.are.equal(3, #c.macros)
        c.macros[1].body = "/say User macro"
        SlashCmdList.WHTARGETMACROS(); assert.are.equal("/say User macro", c.macros[1].body)
        c.module:Disable()
    end)
end)

