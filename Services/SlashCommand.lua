local addonName, ns = ...
local Class = ns.Class

-- Services/SlashCommand.lua
-- Singleton slash-command router for /hagaio (alias /hag). It is a GENERIC router
-- with no dependencies: features register their own sub-commands as { fn, help }
-- entries, and one feature may claim the empty command via SetDefaultHandler. The
-- settings window, for example, registers "config"/"log" and the default handler
-- itself (it depends on this service) -- so this router never references any UI.

local SlashCommand = Class.new("SlashCommand", ns.Service)

function SlashCommand:OnInitialize()
    local p = self:_p()
    p.handlers = {}        -- subcommand -> { fn = fn, help = string }
    p.defaultHandler = nil -- run for an empty command (set by a feature); falls back to help
    p.registered = false
end

-- Claim the bare "/hag" (no sub-command) action. Last caller wins.
function SlashCommand:SetDefaultHandler(fn)
    self:_p().defaultHandler = fn
end

local function trim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function SlashCommand:Register(sub, fn, help)
    self:_p().handlers[sub:lower()] = { fn = fn, help = help }
end

function SlashCommand:_Dispatch(msg)
    local p = self:_p()
    local sub, rest = trim(msg):match("^(%S*)%s*(.*)$")
    sub = (sub or ""):lower()
    local entry = p.handlers[sub]
    if entry then
        entry.fn(rest)
    elseif sub == "" and p.defaultHandler then
        p.defaultHandler(rest)
    else
        self:_PrintHelp()
    end
end

function SlashCommand:_PrintHelp()
    ns.Log.Print("commands:")
    for sub, entry in pairs(self:_p().handlers) do
        ns.Log.Print(("  |cffffff00/hag %s|r %s"):format(
            sub, entry.help and ("- " .. entry.help) or ""))
    end
end

-- Wire up the slash globals and built-in sub-commands. Call once at load.
function SlashCommand:Activate()
    local p = self:_p()
    if p.registered then return end
    p.registered = true

    SLASH_HAGAIO1 = "/hagaio"
    SLASH_HAGAIO2 = "/hag"
    SlashCmdList["HAGAIO"] = function(msg) self:_Dispatch(msg) end

    -- "config"/"log" and the default (bare-command) action are contributed by the
    -- settings window itself (see SettingsWindow:OnInitialize) so this router stays
    -- UI-agnostic. Only generic, dependency-free built-ins live here.
    self:Register("help", function() self:_PrintHelp() end,
        "list commands")
    self:Register("modules", function()
        local mm = ns.ModuleManager
        if mm:Count() == 0 then
            ns.Log.Print("no feature modules registered yet.")
            return
        end
        ns.Log.Print("modules:")
        for m in mm:Iterate() do
            ns.Log.Print(("  %s - %s"):format(
                m:GetName(),
                m:IsEnabled() and "|cff44ff44on|r" or "|cffff4444off|r"))
        end
    end, "list feature modules and their state")
end

ns.ServiceManager:Register(SlashCommand:New("SlashCommand"))
