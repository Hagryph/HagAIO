local addonName, ns = ...
local Class = ns.Class

-- Core/Dev.lua
-- Developer-only service (not surfaced in normal use). Owns the FULL CVar dump: it
-- enumerates every console variable and shows them -- name, default, scope -- in the copy
-- window, ready to Ctrl+C, so we can capture the complete list each patch and keep the
-- addon's curated / bundled CVar data current. Nothing is persisted; it's copy-only.
--
-- Full enumeration needs WoW's developer console (the C_Console.* namespace only exists when
-- the client is launched with -console -- which requires a full restart, not a /reload).
-- C_CVar (used for the per-CVar metadata) is always available.
--
--   /hag dev cvars   -> open every CVar in the copy window.

local Dev = Class.new("Dev", ns.Service)

function Dev:OnInitialize()
    if ns.SlashCommand then
        ns.SlashCommand:Register("dev", function(rest) self:_Slash(rest) end, "developer tools")
    end
end

-- Sorted CVar names (optionally substring-filtered), or nil if the console API is absent.
-- Tries the modern C_Console namespace and the legacy global as a fallback.
function Dev:AllCVarNames(filter)
    local commands
    if C_Console and C_Console.GetAllCommands then
        commands = C_Console.GetAllCommands()
    elseif ConsoleGetAllCommands then
        commands = ConsoleGetAllCommands()
    end
    if type(commands) ~= "table" then return nil end
    local cvarType = (Enum and Enum.ConsoleCommandType and Enum.ConsoleCommandType.Cvar) or 0
    filter = (filter and filter ~= "") and filter:lower() or nil
    local t = {}
    for _, c in ipairs(commands) do
        if c.commandType == cvarType and (not filter or c.command:lower():find(filter, 1, true)) then
            t[#t + 1] = c.command
        end
    end
    table.sort(t, function(a, b) return a:lower() < b:lower() end)
    return t
end

-- A ready-to-paste Lua source string of every CVar (name -> default + scope), for the
-- copy window. Current values are character-specific, so we record the stable facts.
function Dev:_BuildCVarText(names)
    local version, build = GetBuildInfo()
    local lines = {
        ("-- HagAIO CVar dump: %s build %s -- %d CVars"):format(version, tostring(build), #names),
        "return {",
    }
    for _, name in ipairs(names) do
        local _, d, acct, char = C_CVar.GetCVarInfo(name)
        local scope = char and "character" or (acct and "account") or "global"
        lines[#lines + 1] = ("  [%q] = { default = %q, scope = %q },"):format(name, tostring(d), scope)
    end
    lines[#lines + 1] = "}"
    return table.concat(lines, "\n")
end

function Dev:_Slash(rest)
    local cmd = ((rest or ""):match("^(%S*)") or ""):lower()
    if cmd == "cvars" or cmd == "cvardump" then
        local names = self:AllCVarNames()
        if not names then
            ns.Log.Warn("the developer console isn't active. Make sure -console is in your launch args,")
            ns.Log.Warn("then FULLY QUIT and relaunch WoW -- a /reload doesn't pick up launch arguments.")
            return
        end
        local text = self:_BuildCVarText(names)
        if ns.UI and ns.UI.CopyWindow then
            ns.UI.CopyWindow:Show(("CVars (%d)"):format(#names), text)
        else
            ns.Log.Warn("copy window unavailable")
        end
    else
        ns.Log.Print("|cffffff00/hag dev cvars|r  -  open a copy window with every CVar (needs -console)")
    end
end

-- Dev registers a slash sub-command in OnInitialize, so it loads after SlashCommand.
ns.ServiceManager:Register(Dev:New("Dev", { deps = { "SlashCommand" } }))
