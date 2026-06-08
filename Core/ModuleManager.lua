local addonName, ns = ...
local Class = ns.Class

-- Core/ModuleManager.lua
-- Registry that owns the lifecycle of every feature Module: it initialises them
-- (logger + saved vars bound, then OnInitialize -- see Module:_Init) and enables
-- them per the persisted / default state on PLAYER_LOGIN. Modules registered after
-- startup are started immediately so load order is irrelevant.
--
-- The generic registry plumbing (name map, ordered Register, Iterate/Count/Get,
-- start latch, cached dependency graph) lives in ns.Registry; this class adds only
-- the module-specific gating.

local ModuleManager = Class.new("ModuleManager", ns.Registry)

function ModuleManager:Initialize()
    ns.Registry.Initialize(self, "module")
end

-- A module registered after StartAll starts at once (load order is irrelevant).
function ModuleManager:_OnLateRegister(module)
    self:_Start(module)
end

-- Backwards-compatible alias for the generic Registry:Get (call sites + depcheck
-- reference ModuleManager:GetModule).
function ModuleManager:GetModule(name)
    return self:Get(name)
end

-- The shared dependency forest for modules. Three node kinds, all evaluated by the
-- core DependencyGraph (not by hand): addon:* (is the external addon loaded),
-- service:* (is the service loaded), module:* (is the module enabled, with its
-- module-deps as the node's condition). Built lazily + cached by ns.Registry.
function ModuleManager:_DepGraph()
    return self:_GetGraph(function(mm, g)
        local function ensure(id, predicate)
            if not g:Has(id) then g:Add(id, predicate) end
        end
        for m in mm:Iterate() do
            for _, a in ipairs(m:GetAddonDeps()) do
                ensure("addon:" .. a, function() return C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(a) and true or false end)
            end
            for _, s in ipairs(m:GetServiceDeps()) do
                ensure("service:" .. s, function() return ns.ServiceManager and ns.ServiceManager:IsLoaded(s) and true or false end)
            end
        end
        for m in mm:Iterate() do
            local refs = {}
            for _, d in ipairs(m:GetModuleDeps()) do refs[#refs + 1] = "module:" .. d end
            g:Add("module:" .. m:GetName(), m, (#refs > 0) and { all = refs } or nil)
        end
    end, { method = "IsEnabled" })  -- module subjects use :IsEnabled()
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

function ModuleManager:_Start(module)
    -- One call runs the fixed init sequence (logger -> db -> OnInitialize); the
    -- ordering lives in Module:_Init, not here. Whether the module actually ENABLES
    -- is gated by Module:Enable (addon + service + module deps), so a module with
    -- unmet deps simply stays disabled, not uninitialised.
    module:_Init()
    local shouldEnable
    if module:IsAlwaysOn() then
        shouldEnable = true   -- mandatory module: always enabled, persisted state ignored
    else
        shouldEnable = ns.SavedVars:GetModuleState(module:GetName(), true)  -- per-character enable state
        if shouldEnable == nil then shouldEnable = module:IsDefaultEnabled() end
    end
    if shouldEnable then
        module:Enable()
    end
end

-- Disable every enabled module that declares `name` as a module-dependency.
-- Called when a module is disabled so dependents can't keep running without it.
function ModuleManager:DisableDependents(name)
    for m in self:Iterate() do
        if m:IsEnabled() then
            for _, dep in ipairs(m:GetModuleDeps()) do
                if dep == name then m:Disable(); break end  -- Disable() cascades further
            end
        end
    end
end

-- Run once on PLAYER_LOGIN.
function ModuleManager:StartAll()
    if not self:_BeginStart() then return end
    self:_StartEach(function(m) self:_Start(m) end)  -- registration order (deps gate enable)
end

-- Called on PLAYER_LOGOUT (reload OR exit). Runs each module's OnShutdown cleanup so
-- nothing leaks across a reload (e.g. a module playing a sound). Does NOT change
-- persisted enable state. The iteration + per-item guard live in ns.Registry.
function ModuleManager:Shutdown()
    self:_ShutdownEach("OnShutdown")
end

-- Right-click context menu shared by the compartment + minimap buttons: a checkbox
-- per module (toggles enable) then a divider and "Open Menu".
function ModuleManager:OpenContextMenu(owner)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        ns.UI.SettingsWindow:Toggle()  -- no menu API; just open settings
        return
    end
    local mm = self
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle("HagAIO")
        for module in mm:Iterate() do
            if not module:IsAlwaysOn() then   -- mandatory modules have no toggle
                root:CreateCheckbox(module:GetTitle(),
                    function() return module:IsEnabled() end,
                    function() module:Toggle() end)
            end
        end
        root:CreateDivider()
        root:CreateButton("Open Menu", function() ns.UI.SettingsWindow:Show("modules") end)
    end)
end

-- Self-instantiate the singleton at load so feature modules can register into it as
-- their files load (after the Core layer).
ns.ModuleManager = ModuleManager:New()
