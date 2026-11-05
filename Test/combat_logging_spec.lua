local S = dofile("Test/support.lua")

local function rig(initial)
    S.stubFrames()
    local clock = S.newClock()
    _G.GetTime, _G.C_Timer = clock.GetTime, clock.C_Timer
    local ns = S.newNs()
    S.load(ns, "Services/EventBus.lua")
    ns._captured.EventBus:OnInitialize()
    S.load(ns, "Services/Scheduler.lua")
    S.load(ns, "Core/Submodule.lua")
    local host = { GetName = function() return "Misc" end }
    ns.ModuleManager = { GetModule = function() return host end }
    ns.SubmoduleManager = { Register = function(_, sub) ns._captured.CombatLogging = sub end }
    local state = { logging = initial or false, instance = false, calls = 0, invalidated = 0 }
    ns.UI.SettingsWindow = { InvalidateModule = function() state.invalidated = state.invalidated + 1 end }
    _G.IsInInstance = function() return state.instance end
    _G.LoggingCombat = function(...)
        state.calls = state.calls + 1
        if state.reject then state.reject = false; return nil end
        if select("#", ...) ~= 0 then state.logging = (...) end
        return state.logging
    end
    S.load(ns, "Modules/Misc/CombatLogging.lua")
    local sub, settings = ns._captured.CombatLogging, {}
    function sub:GetSetting(key) return settings[key] or false end
    function sub:SetSetting(key, value) settings[key] = value; self:OnSettingChanged(key, value) end
    return sub, state, clock, ns
end

describe("Misc combat logging", function()
    it("leaves existing manual logging alone with both toggles off", function()
        local sub, state = rig(true)
        sub:Enable()
        assert.are.equal(0, state.calls)
        sub:Disable()
        assert.is_true(state.logging)
    end)
    it("switches mutually exclusive modes and updates the visible controls", function()
        local sub, state = rig()
        sub:Enable();sub:SetSetting("permanent", true)
        assert.is_true(state.logging)
        sub:SetSetting("instance", true)
        assert.is_false(sub:GetSetting("permanent"))
        assert.is_false(state.logging)
        state.instance = true;sub:_Apply()
        assert.is_true(state.logging)
        local calls = state.calls
        for _ = 1, 20 do sub:_Apply() end
        assert.are.equal(calls, state.calls)
        state.instance = false;sub:_Apply()
        assert.is_false(state.logging)
        sub:SetSetting("permanent", true)
        assert.is_false(sub:GetSetting("instance"))
        assert.is_true(state.logging)
        assert.is_true(state.invalidated >= 3)
        sub:Disable();assert.is_false(state.logging)
    end)
    it("restores the original state when both modes are off", function()
        local sub, state = rig(true)
        sub:Enable();sub:SetSetting("instance", true)
        assert.is_false(state.logging)
        sub:SetSetting("instance", false)
        assert.is_true(state.logging)
        sub:Disable()
    end)
    it("retries rate-limited calls without treating nil as disabled or dropping events", function()
        local sub, state, clock = rig()
        sub:Enable();state.reject = true;sub:SetSetting("permanent", true)
        assert.is_false(state.logging)
        clock.advance(10)
        assert.is_true(state.logging)
        sub:Disable()
    end)
    it("cancels a pending retry when disabled", function()
        local sub, state, clock = rig()
        sub:Enable();state.reject = true;sub:SetSetting("permanent", true);sub:Disable()
        local calls = state.calls
        clock.advance(15)
        assert.are.equal(calls, state.calls)
    end)
end)
