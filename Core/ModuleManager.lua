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
    p.depGraph = nil  -- structure changed; rebuild lazily
    if p.started then
        self:_Start(module)
    end
    return module
end

-- The shared dependency forest for modules. Three node kinds, all evaluated by
-- the core DependencyGraph (not by hand): addon:* (is the external addon loaded),
-- service:* (is the service loaded), module:* (is the module enabled, with its
-- module-deps as the node's condition). Cached; rebuilt when a module registers.
function ModuleManager:_DepGraph()
    local p = self:_p()
    if p.depGraph then return p.depGraph end
    local g = ns.DependencyGraph:New({ method = "IsEnabled" })  -- module subjects use :IsEnabled()

    local function ensure(id, predicate)
        if not g:Has(id) then g:Add(id, predicate) end
    end
    for _, name in ipairs(p.order) do
        local m = p.modules[name]
        for _, a in ipairs(m:GetAddonDeps()) do
            ensure("addon:" .. a, function() return C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(a) and true or false end)
        end
        for _, s in ipairs(m:GetServiceDeps()) do
            ensure("service:" .. s, function() return ns.ServiceManager and ns.ServiceManager:IsLoaded(s) and true or false end)
        end
    end
    for _, name in ipairs(p.order) do
        local m = p.modules[name]
        local refs = {}
        for _, d in ipairs(m:GetModuleDeps()) do refs[#refs + 1] = "module:" .. d end
        g:Add("module:" .. name, m, (#refs > 0) and { all = refs } or nil)
    end

    local ok, issues = g:Validate()
    if not ok then
        for _, msg in ipairs(issues) do ns.Logger:Core():Warn("module dependencies: " .. msg) end
    end
    p.depGraph = g
    return g
end

-- DISPLAY gate: every required external addon is loaded.
function ModuleManager:IsModuleAvailable(name)
    local m = self:GetModule(name); if not m then return false end
    local g = self:_DepGraph()
    for _, a in ipairs(m:GetAddonDeps()) do
        if not g:IsActive("addon:" .. a) then return false end
    end
    return true
end

-- GREY gate: required services loaded AND prerequisite modules enabled (the
-- latter via the node's condition, resolved transitively by the graph).
function ModuleManager:AreModuleDepsMet(name)
    local m = self:GetModule(name); if not m then return false end
    local g = self:_DepGraph()
    for _, s in ipairs(m:GetServiceDeps()) do
        if not g:IsActive("service:" .. s) then return false end
    end
    return g:IsSatisfied("module:" .. name)
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
    -- Initialise the module regardless; whether it actually ENABLES is gated by
    -- Module:Enable, which consults the dependency graph (addon + service + module
    -- deps). So a module with unmet deps simply stays disabled, not uninitialised.
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

-- Disable every enabled module that declares `name` as a module-dependency.
-- Called when a module is disabled so dependents can't keep running without it.
function ModuleManager:DisableDependents(name)
    local p = self:_p()
    for _, mname in ipairs(p.order) do
        local m = p.modules[mname]
        if m and m:IsEnabled() then
            for _, dep in ipairs(m:GetModuleDeps()) do
                if dep == name then m:Disable(); break end  -- Disable() cascades further
            end
        end
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

-- Self-instantiate the singleton at load so feature modules can register into it
-- as their files load (after the Core layer).
ns.ModuleManager = ModuleManager:New()
