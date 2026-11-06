local addonName, ns = ...
local TargetingMacros = ns.Class.new("TargetingMacros", ns.Submodule, {
    statics = { definitions = {
        { "WHMouseFocus", "/focus [@mouseover,exists,nodead]" },
        { "WHMouseTarget", "/target [@mouseover,exists,nodead]" },
        { "WHFocusTarget", "/target [@focus,exists,nodead]" },
    } },
})

-- Creation only: no bindings, globals, unit state, focus/mouseover observation,
-- timers or combat readback. The helper discovers macros and bindings natively.
function TargetingMacros:_Create()
    if InCombatLockdown() then return false end
    for _, definition in ipairs(self:_statics().definitions) do
        local name, body = definition[1], definition[2]
        local index = GetMacroIndexByName(name)
        if index == 0 then
            index = CreateMacro(name, 134400, body, true)
            if not index or index == 0 then
                print("HagAIO: no room to create " .. name .. ".")
                return false
            end
        else
            local _, _, existing = GetMacroInfo(index)
            if existing ~= body then
                print("HagAIO: " .. name .. " has a different body; left unchanged.")
                return false
            end
        end
    end
    return true
end

function TargetingMacros:_OnLoad()
    self:_Create()
    self:On("PLAYER_REGEN_ENABLED", function() self:_Create() end)
    self:On("PLAYER_ENTERING_WORLD", function() self:_Create() end)
    _G.SLASH_WHTARGETMACROS1 = "/whtargetmacros"
    SlashCmdList.WHTARGETMACROS = function() self:_Create() end
end

function TargetingMacros:_OnUnload()
    SlashCmdList.WHTARGETMACROS = nil
end

ns.SubmoduleManager:Register(TargetingMacros:New("TargetingMacros", {
    parent = { module = "Misc" }, host = ns.ModuleManager:GetModule("Misc"),
    title = "Helper targeting macros",
    onLoad = function(_, sub) sub:_OnLoad() end,
    onUnload = function(_, sub) sub:_OnUnload() end,
    settings = { { type = "note", text = "Creates WHMouseFocus, WHMouseTarget and WHFocusTarget out of combat. Never changes existing macros or bindings and never publishes live state. Run /whtargetmacros to retry." } },
}))
