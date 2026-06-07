local addonName, ns = ...
local Class = ns.Class

-- Core/SlashCommand.lua
-- Singleton slash-command router for /hagaio (alias /hag). Sub-commands are
-- registered as { fn, help } entries; an empty command opens the options panel.

local SlashCommand = Class.new("SlashCommand", ns.Service)

function SlashCommand:OnInitialize()
    local p = self:_p()
    p.handlers = {}      -- subcommand -> { fn = fn, help = string }
    p.registered = false
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
    elseif sub == "" then
        ns.UI.SettingsWindow:Toggle()
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

    self:Register("config", function() ns.UI.SettingsWindow:Toggle() end,
        "open the settings window")
    self:Register("log", function() ns.UI.SettingsWindow:Show("log") end,
        "open the activity log")
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
