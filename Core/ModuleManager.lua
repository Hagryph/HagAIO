local addonName, ns = ...
local Class = ns.Class

-- Core/ModuleManager.lua
-- Singleton registry that owns the lifecycle of every feature Module: it binds
-- their saved vars, runs OnInitialize, and enables them per the persisted /
-- default state on PLAYER_LOGIN. Modules registered after startup are started
-- immediately so load order is irrelevant.

local ModuleManager = Class.new("ModuleManager")

function ModuleManager:Initialize()
    local p = self:_p()
    p.modules = {}   -- name -> Module
    p.order = {}     -- ordered list of names (insertion order)
    p.started = false
end

function ModuleManager:Register(module)
    local p = self:_p()
    local name = module:GetName()
    assert(not p.modules[name], "duplicate module: " .. tostring(name))
    p.modules[name] = module
    p.order[#p.order + 1] = name
    if p.started then
        self:_Start(module)
    end
    return module
end

-- Look up a registered module instance by name.
function ModuleManager:GetModule(name)
    return self:_p().modules[name]
end

-- Stateless iterator over modules in registration order.
function ModuleManager:Iterate()
    local p = self:_p()
    local i = 0
    return function()
        i = i + 1
        local name = p.order[i]
        if name then return p.modules[name] end
    end
end

function ModuleManager:Count()
    return #self:_p().order
end

function ModuleManager:_Start(module)
    module:_AttachLogger()
    module:_BindDB()
    module:OnInitialize()
    local saved = ns.SavedVars:GetModuleState(module:GetName(), module:IsPerChar())
    local shouldEnable = saved
    if shouldEnable == nil then
        shouldEnable = module:IsDefaultEnabled()
    end
    if shouldEnable then
        module:Enable()
    end
end

-- Run once on PLAYER_LOGIN.
function ModuleManager:StartAll()
    local p = self:_p()
    if p.started then return end
    p.started = true
    for _, name in ipairs(p.order) do
        self:_Start(p.modules[name])
    end
end

-- Called on PLAYER_LOGOUT (reload OR exit). Runs each module's optional
-- OnShutdown cleanup so nothing leaks across a reload (e.g. a module playing a
-- sound). Does NOT change persisted enable state.
function ModuleManager:Shutdown()
    local p = self:_p()
    for _, name in ipairs(p.order) do
        local m = p.modules[name]
        if m.OnShutdown then pcall(function() m:OnShutdown() end) end
    end
end

-- Right-click context menu shared by the compartment + minimap buttons: a
-- checkbox per module (toggles enable) then a divider and "Open Menu".
function ModuleManager:OpenContextMenu(owner)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        ns.UI.SettingsWindow:Toggle()  -- no menu API; just open settings
        return
    end
    local mm = self
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle("HagAIO")
        for module in mm:Iterate() do
            root:CreateCheckbox(module:GetTitle(),
                function() return module:IsEnabled() end,
                function() module:Toggle() end)
        end
        root:CreateDivider()
        root:CreateButton("Open Menu", function() ns.UI.SettingsWindow:Show("modules") end)
    end)
end

ns.ModuleManager = ModuleManager
