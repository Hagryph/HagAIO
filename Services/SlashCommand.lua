local addonName, ns = ...
local Class = ns.Class
local Theme = ns.Theme

-- Services/SlashCommand.lua
-- Singleton slash-command router for /hagaio (alias /hag). It is a GENERIC router
-- with no dependencies: features register their own sub-commands as { fn, help }
-- entries, and one feature may claim the empty command via SetDefaultHandler. The
-- settings window, for example, registers "config"/"log" and the default handler
-- itself (it depends on this service) -- so this router never references any UI.

local SlashCommand = Class.new("SlashCommand", ns.Service)

function SlashCommand:OnInitialize()
    local p = self:_p()
    p.handlers = {}        -- sub -> a LEAF { fn = fn, help = h } OR a GROUP { help = h, subs = {...} }
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

-- first whitespace-delimited word (lower-cased) + the trimmed remainder; ("", "") on empty input.
local function firstWord(s)
    local word, rest = trim(s):match("^(%S*)%s*(.*)$")
    return (word or ""):lower(), rest or ""
end

-- A developer character (whitelisted via ns.DevIdentity.IsDevChar). `dev`-flagged sub-commands of
-- a GROUP are hidden and refused off-whitelist, so the gate lives in ONE place rather than each
-- handler.
local function devOk()
    return not not (ns.DevIdentity and ns.DevIdentity.IsDevChar())
end

-- `help` is a string OR a function returning a string (evaluated when help is printed, so it can
-- reflect live state -- e.g. hiding a developer-only sub-command on a non-dev character).
function SlashCommand:Register(sub, fn, help)
    self:_p().handlers[sub:lower()] = { fn = fn, help = help }
end

-- Register a sub-command GROUP: `/hag <name> <sub> <rest>` auto-routes to subs[<sub>].fn(<rest>);
-- a bare or unknown `/hag <name>` lists the available sub-commands. `subs` is keyed by sub-command
-- name -> { fn = fn, help = string, dev = bool } (a `dev` sub is hidden + refused off a developer
-- character). Built by Contributions.Wire from a command spec's declarative `subcommands` table, so
-- the second level is first-class (routed + documented here, not hand-parsed inside the handler).
function SlashCommand:RegisterGroup(name, help, subs)
    self:_p().handlers[name:lower()] = { help = help, subs = subs }
end

-- Drop a sub-command. Used by the declarative-command auto-teardown when a module that
-- contributed it is disabled (see ns.Component). No-op if it isn't registered.
function SlashCommand:Unregister(sub)
    if not sub then return end
    self:_p().handlers[sub:lower()] = nil
end

function SlashCommand:_Dispatch(msg)
    local p = self:_p()
    local sub, rest = firstWord(msg)
    local entry = p.handlers[sub]
    if entry then
        if entry.subs then self:_DispatchSub(sub, entry, rest)
        else entry.fn(rest) end
    elseif sub == "" and p.defaultHandler then
        p.defaultHandler(rest)
    else
        self:_PrintHelp()
    end
end

-- Route the second word of a GROUP command to its sub-handler. A dev-only sub on a non-dev
-- character, or an unknown/empty sub, falls through to the group's usage list.
function SlashCommand:_DispatchSub(name, entry, rest)
    local sub, rest2 = firstWord(rest)
    local s = entry.subs[sub]
    if s and (not s.dev or devOk()) then
        s.fn(rest2)
    else
        self:_PrintGroupHelp(name, entry)
    end
end

function SlashCommand:_PrintHelp()
    self:LogEchoInfo("commands:")
    local handlers = self:_p().handlers
    local subs = {}
    for sub in pairs(handlers) do subs[#subs + 1] = sub end
    table.sort(subs)   -- stable, alphabetical order (pairs() order is undefined)
    for _, sub in ipairs(subs) do
        local help = handlers[sub].help
        if type(help) == "function" then help = help() end   -- live help (e.g. dev-gated hints)
        self:LogEchoInfo(("  |cffffff00/hag %s|r %s"):format(
            sub, help and ("- " .. help) or ""))
    end
end

-- Usage for a GROUP: each available sub-command + its help, alphabetically (dev subs only on a
-- developer character). Printed for a bare or unrecognised `/hag <name>`.
function SlashCommand:_PrintGroupHelp(name, entry)
    local subs = {}
    for sub, s in pairs(entry.subs) do
        if not s.dev or devOk() then subs[#subs + 1] = sub end
    end
    table.sort(subs)
    for _, sub in ipairs(subs) do
        local help = entry.subs[sub].help
        self:LogEchoInfo(("  |cffffff00/hag %s %s|r %s"):format(name, sub, help and ("- " .. help) or ""))
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
            self:LogEchoInfo("no feature modules registered yet.")
            return
        end
        self:LogEchoInfo("modules:")
        for m in mm:Iterate() do
            self:LogEchoInfo(("  %s - %s"):format(
                m:GetName(),
                m:IsEnabled() and Theme.Colorize("green", "on") or Theme.Colorize("red", "off")))
        end
    end, "list feature modules and their state")
end

ns.ServiceManager:Register(SlashCommand:New("SlashCommand"))
